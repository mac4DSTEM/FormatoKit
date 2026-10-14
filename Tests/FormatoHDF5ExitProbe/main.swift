//
//  FormatoHDF5ExitProbe — main.swift
//  Role: The child process of `HDF5ExitBarrierTests` (SpectroKitTests). `exit()` runs the atexit handlers, which a
//        test cannot watch from inside its own process, so each scenario of the quit barrier
//        (`HDF5Serial.installExitBarrier`, macTEM ADR 021) runs here and the test reads what the process wrote and
//        how it ended.
//
//  Usage: FormatoHDF5ExitProbe <mode> [bound-seconds]
//         FormatoHDF5ExitProbe velox-order <emd-path>
//    free           nobody holds the HDF5 lock; the main thread calls exit(0).
//    held-by-caller the main thread holds the lock (recursive) and calls exit(0): straight through.
//    held-briefly   a second thread holds the lock for ~0.4 s, writes "released", lets go; the main thread calls
//                   exit(0).
//    stuck          a second thread takes the lock and never lets go; the main thread calls exit(0).
//    print-bound    writes HDF5Serial.exitBarrierBound (the default, as setExitBarrierBound is not called) and
//                   exits 0.
//    velox-order    the REAL loader, with the real libhdf5 (see below); takes a path, not a bound.
//
//  Markers go through write(2) only: `_exit` (the barrier's way out) does not flush stdio, so a `print` would be lost
//  exactly when the test needs it. stdout: "calling-exit <ns>", "released", "teardown-ran lock-held|lock-free",
//  and for velox-order "opened", "lock-free-before-exit", "h5-teardown lock-held|lock-free". stderr: the barrier's
//  own line.
//
//  "calling-exit <ns>" carries the system-wide monotonic time (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, the clock
//  the test reads too) taken just before `exit`. The test measures the barrier's wait from it, not from the moment
//  its own pipe handler happened to run: a late handler under CPU load would shorten the measured wait and fail the
//  lower bound.
//
//  "teardown-ran" stands in for HDF5's `H5_term_library`. HDF5 registers that handler inside the first `H5open`, and
//  the loaders install the barrier right after it, so atexit's last-in-first-out order runs the barrier first and
//  HDF5's teardown after it. Registered here BEFORE the barrier, the stand-in runs after it, and `_exit(70)` skips it.
//  H5_term_library takes no lock of ours, so the barrier's promise is that the HDF5 lock is STILL HELD when it starts:
//  the stand-in has a second thread try `HDF5Serial.run {}` for 0.3 s and writes "lock-held" if that thread did not get
//  in, "lock-free" if it did (a barrier that took the lock and gave it back before the teardown).
//
//  velox-order does not call `installExitBarrier` and registers no stand-in: the Velox loader does the first, and
//  HDF5 itself is the second. It opens a Velox file through `VeloxEMDReader.readSpectrumImage` (SpectroKit 0.3.0 went through
//  `SpectrumImageOpener.open`, which stays in SpectroKit and makes the same call), which makes the loader run `H5open` and then install the barrier. It then asks the libhdf5 that the loader loaded
//  (`MAC4DSTEM_HDF5_PATH`, `RTLD_NOLOAD`: the same image, never a second copy) for `H5atclose`, HDF5's own hook that
//  calls a callback as `H5_term_library` starts, and registers one that writes whether the lock is held at that
//  moment. If the loader had installed the barrier before `H5open`, the barrier would run after HDF5's handler and
//  the callback would find the lock free. "lock-free-before-exit" is checked just before `exit`, so a "lock-held"
//  at the teardown cannot come from a hold the open leaked.
//

import Foundation
import FormatoEMD
import FormatoHDF5

/// One unbuffered write; nothing else is allowed to carry a marker.
func mark(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

/// Writes `text` with write(2), for the markers that are not literals.
func markDynamic(_ text: String, to fd: Int32 = STDOUT_FILENO) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
}

/// "calling-exit <ns>\n": the stamp is read first, so it is never later than the `exit` call that follows.
func markCallingExit() {
    let stamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    markDynamic("calling-exit \(stamp)\n")
}

func usage() -> Never {
    mark(STDERR_FILENO, "usage: FormatoHDF5ExitProbe free|held-by-caller|held-briefly|stuck|print-bound [seconds]\n")
    mark(STDERR_FILENO, "       FormatoHDF5ExitProbe velox-order <emd-path>\n")
    exit(64)
}

/// True if another thread gets into `HDF5Serial.run {}` within 0.3 s. A thread that does not get in stays blocked for
/// good (the process is about to end), which is the point: it is the barrier's lock that is holding it.
func hdf5LockIsFree() -> Bool {
    let entered = DispatchSemaphore(value: 0)
    Thread.detachNewThread { HDF5Serial.run {}; entered.signal() }
    return entered.wait(timeout: .now() + .milliseconds(300)) == .success
}

/// The stand-in teardown: HDF5's H5_term_library takes no lock of ours, so the barrier's promise is that the lock is
/// STILL HELD when it starts.
func teardownStandIn() {
    if hdf5LockIsFree() {
        mark(STDOUT_FILENO, "teardown-ran lock-free\n")
    } else {
        mark(STDOUT_FILENO, "teardown-ran lock-held\n")
    }
}

/// HDF5's own teardown hook (`H5atclose`): called on the exiting thread as `H5_term_library` starts.
func reportLockAtHDF5Teardown(_ context: UnsafeMutableRawPointer?) {
    if hdf5LockIsFree() {
        mark(STDOUT_FILENO, "h5-teardown lock-free\n")
    } else {
        mark(STDOUT_FILENO, "h5-teardown lock-held\n")
    }
}

/// A scenario that cannot even be set up is the probe's failure, not the barrier's: stderr, status 3.
func setupFailed(_ message: String) -> Never {
    markDynamic("velox-order: \(message)\n", to: STDERR_FILENO)
    exit(3)
}

/// The real loader, HDF5's real teardown (see the header). Installs nothing itself.
func runVeloxOrder(path: String) -> Never {
    do { _ = try VeloxEMDReader(path: path).readSpectrumImage() } catch {
        setupFailed("cannot open \(path): \(error)")
    }
    mark(STDOUT_FILENO, "opened\n")

    typealias AtClose = @convention(c) (
        @convention(c) (UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?
    ) -> Int32
    guard let library = ProcessInfo.processInfo.environment["MAC4DSTEM_HDF5_PATH"] else {
        setupFailed("MAC4DSTEM_HDF5_PATH is not set (tools/test.sh sets it): which libhdf5 did the loader load?")
    }
    guard let handle = dlopen(library, RTLD_NOW | RTLD_NOLOAD), let symbol = dlsym(handle, "H5atclose") else {
        setupFailed("H5atclose not found in the already loaded \(library)")
    }
    let atclose = unsafeBitCast(symbol, to: AtClose.self)
    guard HDF5Serial.run({ atclose(reportLockAtHDF5Teardown, nil) }) >= 0 else {
        setupFailed("H5atclose refused the callback")
    }

    if hdf5LockIsFree() {
        mark(STDOUT_FILENO, "lock-free-before-exit\n")
    } else {
        mark(STDOUT_FILENO, "lock-held-before-exit\n")
    }
    markCallingExit()
    exit(0)
}

func run(mode: String, bound: Double?) -> Never {
    // Before the barrier, so it runs after it (last in, first out), as HDF5's teardown does.
    guard atexit({ teardownStandIn() }) == 0 else { exit(71) }
    if mode != "print-bound", let bound { HDF5Serial.setExitBarrierBound(bound) }
    HDF5Serial.installExitBarrier()

    switch mode {
    case "free":
        markCallingExit()
        exit(0)

    case "held-by-caller":
        HDF5Serial.acquire()
        markCallingExit()
        exit(0)

    case "held-briefly":
        let holding = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            HDF5Serial.acquire()
            holding.signal()
            usleep(400_000)
            mark(STDOUT_FILENO, "released\n")       // before release(): the barrier cannot pass until it is written
            HDF5Serial.release()
        }
        holding.wait()
        markCallingExit()
        exit(0)

    case "stuck":
        let holding = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            HDF5Serial.acquire()
            holding.signal()
            DispatchSemaphore(value: 0).wait()      // never signalled: a thread stuck in HDF5 holds the lock for good
        }
        holding.wait()
        markCallingExit()
        exit(0)

    case "print-bound":
        markDynamic("\(HDF5Serial.exitBarrierBound)\n")
        exit(0)

    default:
        usage()
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }
if arguments[1] == "velox-order" {
    guard arguments.count == 3 else { usage() }
    runVeloxOrder(path: arguments[2])
}
let boundSeconds: Double? = arguments.count >= 3 ? Double(arguments[2]) : nil
if arguments.count >= 3, boundSeconds == nil { usage() }
run(mode: arguments[1], bound: boundSeconds)
