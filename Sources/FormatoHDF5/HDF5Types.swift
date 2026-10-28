import Foundation
import Synchronization

/// HDF5 C ABI scalar aliases shared by the dynamic reader and writer.
public typealias hid_t = Int64
public typealias herr_t = Int32
public typealias hsize_t = UInt64

/// EVERY HDF5 CALL IN THE PROCESS RUNS UNDER THIS LOCK (2026-09-15 night).
///
/// The bundled libhdf5 is built `Threadsafety: OFF`, and it was entered from
/// two unserialised paths — `H5Reader`, an actor per instance, and
/// `BraggVectorEMDWriter`, a nonisolated enum with its own `dlopen`.
/// A race probe in a host application's tools reproduces the crash: serial completes, concurrent
/// dies with SIGBUS inside the first twenty iterations. This is HDF5's own
/// thread-safe build done from outside — its `H5_API_LOCK` is a global mutex
/// around every API call; this one is around every logical operation (an
/// open, a tile read, a sidecar write), recursive so nested entries (write →
/// publish → …) do not deadlock, and NEVER held across an `await`: the
/// tile-streaming export releases it before it reads the next tile from the
/// source actor, and re-takes it to write. A caller that blocks on it blocks
/// its thread for the length of one operation, which is the cost of a
/// library that cannot be entered twice. A review (2026-09-15)
/// found two entry points that opened the file themselves and took nothing
/// — `loadResultMap(id:)` and `loadRGBAResultMap(id:)`, reached by clicking
/// a saved result — and crashed the probe's variant on the first attempt;
/// the audit is by grep for `HDF5WriteLibrary.load()` and `HDF5Library.load()`:
/// every one must sit under this lock, because `H5open` is an API call too.
public nonisolated enum HDF5Serial {
    private static let lock = NSRecursiveLock()
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    /// For the one synchronous stretch that must outlive a closure's scope
    /// (the export's dataset setup, whose handles the loop below it uses).
    /// Pair on the same thread, and never span an `await`.
    public static func acquire() { lock.lock() }
    public static func release() { lock.unlock() }

    /// THE QUIT BARRIER (Slot 4¾ review, 2026-10-02). `exit()`, where every
    /// Quit ends, runs HDF5's own atexit handler `H5_term_library`, which takes
    /// no lock of ours: a Task still inside `H5Dread` raced the teardown and
    /// the process crashed at quit (reproduced by a host application's exit-race test). This handler
    /// takes the lock and never gives it back. HDF5 registers its handler once
    /// per process, inside the first `H5open`, and atexit runs last-registered
    /// first — so every loader calls this right after a successful `H5open`
    /// (here `VeloxEMDReader`; in a host, its own HDF5 readers and
    /// writers):
    /// exit waits for the one call in flight, then HDF5 tears down with no
    /// other thread able to enter. The lock is recursive, so an exit on a
    /// thread that holds it goes straight through; nothing that holds it waits
    /// on the main thread. Cost: a quit waits for at most one locked operation,
    /// and never longer than `exitBarrierBound` (below).
    ///
    /// BOUNDED (the inherited 0.2.0, at a host's request of 2026-10-14). A thread stuck INSIDE HDF5 holds the lock
    /// forever (a damaged global heap makes `H5Aread` spin in `H5HG__cache_heap_deserialize`; the heap has no checksum),
    /// and the unbounded wait made Quit wait for Force Quit. The handler now waits `exitBarrierBound` for the lock
    /// (`lock(before:)`). Past it, it writes one line to stderr and calls `_exit(70)` (EX_SOFTWARE; the status `exit`
    /// was given is not visible to an atexit handler): no handler registered before this one runs, HDF5's
    /// `H5_term_library` included, and stdio buffers are not flushed. That is the lesser harm: the stuck thread never
    /// releases. A file a stuck thread was writing is not closed (HDF5's cached metadata is not flushed); the unbounded
    /// wait never improved on that, Quit waited for Force Quit. A healthy operation longer than the bound is cut too,
    /// where 0.1.0 would have finished it. A write that publishes by temporary file and rename keeps its destination
    /// unchanged but leaves the unfinished temporary file, since `_exit` runs no cleanup.
    ///
    /// Call it right after the first successful `H5open`, never earlier: called earlier, the barrier is registered
    /// before HDF5's handler, so it runs after `H5_term_library` and the teardown runs unguarded (a review measured
    /// SIGSEGV with a thread inside `H5Aread`). Two threads calling `exit()` at once bypass the barrier in progress:
    /// libc runs the remaining handlers on the second `exit` (also true of 0.1.0). `fork` without `exec` is
    /// unsupported.
    public static func installExitBarrier() {
        lock.lock(); defer { lock.unlock() }
        guard !exitBarrierInstalled else { return }
        exitBarrierInstalled = atexit { HDF5Serial.exitBarrier() } == 0
    }
    /// Owned by `HDF5Serial`; read and written only under `lock`.
    nonisolated(unsafe) private static var exitBarrierInstalled = false

    /// How long a quit waits for the HDF5 operation in flight: 10 s, shorter than a user reaches for Force Quit. Inside
    /// this package every locked operation is one call or one block (a Velox slab of at most 32 Mi values; the whole
    /// 1745 MB Velox read took 3.8 s in Release, S3). A host's locked operations are its own and can be longer:
    /// a host may hold the lock for a whole sidecar rebuild, or a tile read of up to physicalMemory/24 bytes, which a
    /// slow volume can stretch past 10 s. So the bound limits the quit; it does not promise that no operation outlasts
    /// it. A host write that publishes by temporary file and rename leaves its destination unchanged when the quit cuts
    /// it.
    public static var exitBarrierBound: TimeInterval {
        Double(exitBarrierBoundMilliseconds.load(ordering: .acquiring)) / 1000
    }
    /// The bound for this process. For the barrier's own tests (`FormatoHDF5ExitProbe`); a host does not set it.
    package static func setExitBarrierBound(_ seconds: TimeInterval) {
        let milliseconds = (seconds * 1000).rounded()
        // False for NaN, infinity, a negative value, or milliseconds that do not fit an Int (`Int(...)` would trap).
        precondition(
            milliseconds >= 0 && milliseconds < 0x1p62,
            "HDF5Serial.setExitBarrierBound: \(seconds) s is not a finite, non-negative number of seconds that fits")
        exitBarrierBoundMilliseconds.store(Int(milliseconds), ordering: .releasing)
    }
    /// Atomic, not under `lock`: the handler reads it while another thread may hold `lock` for good.
    private static let exitBarrierBoundMilliseconds = Atomic<Int>(10_000)

    /// The atexit handler: take the lock and never give it back, or leave without HDF5's shutdown once the bound passes.
    /// Past the bound it calls only `write` and `_exit` (no allocation, no lock): the stuck thread may hold anything.
    private static func exitBarrier() {
        if lock.lock(before: Date(timeIntervalSinceNow: exitBarrierBound)) { return }
        let line: StaticString = """
            FormatoKit: HDF5Serial's quit barrier passed its bound with the HDF5 lock still held; \
            _exit(70) without HDF5's shutdown\n
            """
        _ = write(STDERR_FILENO, line.utf8Start, line.utf8CodeUnitCount)
        _exit(70)
    }
}
