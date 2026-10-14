import XCTest
import FormatoCore
import FormatoEMD
import FormatoHDF5

/// SpectroKit S0 (ADR 064, amendment (2)): the HDF5 lock is taken per call inside `VeloxFile`, so a long Velox read holds
/// it for one block at most; the long calls take `cancelled:` / `progress:`; the library lookup is injectable. All on
/// `Fixtures/velox-tiny.emd` (two streams of a few dozen values) read with a 4-value block, so it spans several blocks.
final class VeloxLockAndCancelTests: XCTestCase {
    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/velox-tiny.emd").path
    }

    private func reader(blockValues: Int = 4) -> VeloxEMDReader {
        var r = VeloxEMDReader(path: fixture)
        r.blockValues = blockValues
        return r
    }

    private nonisolated final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
    }

    // MARK: The lock

    /// Between two blocks of a running decode another thread can take `HDF5Serial` at once: the wait is bounded by one block,
    /// not by the whole read. Deterministic: the hook (called after each block's read, outside the lock) starts the second thread
    /// and waits for it; with the lock held across the whole operation the thread cannot get in and the wait times out.
    /// Mutation: `readSpectrumImage` wrapped back in one `HDF5Serial.run` (the pre-S0 shape) -> every probe fails.
    func testAnotherThreadGetsTheHDF5LockBetweenBlocksOfADecode() throws {
        let probes = Box<[Bool]>([])
        var r = reader()
        r.betweenBlocks = { _ in
            let got = DispatchSemaphore(value: 0)
            Thread.detachNewThread { HDF5Serial.run { _ = got.signal() } }
            probes.mutate { $0.append(got.wait(timeout: .now() + 3) == .success) }
        }
        let result = try r.readSpectrumImage()
        XCTAssertEqual(result.eventStore.totalCounts, 11)
        XCTAssertGreaterThanOrEqual(probes.value.count, 4, "the fixture must span several blocks, or the test proves nothing")
        XCTAssertEqual(probes.value.filter { !$0 }.count, 0, "the lock was held between blocks")
    }

    /// The other two whole-stream readers release the lock between blocks as well.
    func testMarkerScansAlsoReleaseTheLockBetweenBlocks() throws {
        for run in 0..<2 {
            let probes = Box<[Bool]>([])
            var r = reader()
            r.betweenBlocks = { _ in
                let got = DispatchSemaphore(value: 0)
                Thread.detachNewThread { HDF5Serial.run { _ = got.signal() } }
                probes.mutate { $0.append(got.wait(timeout: .now() + 3) == .success) }
            }
            if run == 0 { _ = try r.streamLengthAndMarkers() } else { _ = try r.markersPerFrame() }
            XCTAssertGreaterThanOrEqual(probes.value.count, 2, "run \(run)")
            XCTAssertEqual(probes.value.filter { !$0 }.count, 0, "run \(run): the lock was held between blocks")
        }
    }

    /// Blocking changes nothing: the store read in 4-value blocks equals the one read in the default block.
    func testSmallBlocksGiveTheSameStoreAsTheDefaultBlock() throws {
        let small = try reader().readSpectrumImage()
        let whole = try reader(blockValues: VeloxEMDReader.defaultBlockValues).readSpectrumImage()
        XCTAssertEqual(small.eventStore.totalCounts, whole.eventStore.totalCounts)
        XCTAssertEqual(small.eventStore.distinctEntries, whole.eventStore.distinctEntries)
        for p in 0..<small.eventStore.geometry.pixelsPerFrame {
            XCTAssertEqual(small.eventStore.spectrum(pixel: p), whole.eventStore.spectrum(pixel: p), "pixel \(p)")
        }
        XCTAssertEqual(small.scanImage?.sum, whole.scanImage?.sum)
        XCTAssertEqual(try reader().markersPerFrame(), [6, 6])
    }

    // MARK: Cancel

    /// Cancelled after the first block: the call throws `FormatoCancelled` and has read that one block only (promptly, not at
    /// the end). Mutation: `blockSource` ignores `cancelled` -> the call returns a store and reads every block.
    func testCancelAfterTheFirstBlockThrowsAndStopsReading() throws {
        let blocks = Box(0)
        let flag = Box(false)
        var r = reader()
        r.betweenBlocks = { _ in blocks.mutate { $0 += 1 }; flag.value = true }
        XCTAssertThrowsError(try r.readSpectrumImage(cancelled: { flag.value })) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
        XCTAssertEqual(blocks.value, 1, "no further block was read after the flag")
    }

    /// Every long call refuses to start when already cancelled, and throws `FormatoCancelled` (never a partial answer).
    func testEveryLongCallThrowsSpectroCancelled() throws {
        let r = reader()
        let yes: @Sendable () -> Bool = { true }
        XCTAssertThrowsError(try r.readSpectrumImage(cancelled: yes)) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
        XCTAssertThrowsError(try r.markersPerFrame(cancelled: yes)) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
        XCTAssertThrowsError(try r.streamLengthAndMarkers(cancelled: yes)) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
        XCTAssertThrowsError(try r.images(cancelled: yes)) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
        XCTAssertThrowsError(try r.readImageFrame(id: "x", frame: 0, cancelled: yes)) { XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled()) }
        let source: VeloxStreamDecoder.BlockSource = { visit in _ = try [UInt16(1), 65535].withUnsafeBufferPointer { try visit($0) } }
        XCTAssertThrowsError(try VeloxStreamDecoder.buildEventStore(
            streams: [source], geometry: VeloxStreamGeometry(ny: 1, nx: 1, channels: 4), frames: 0..<1, cancelled: yes)) {
            XCTAssertEqual($0 as? FormatoCancelled, FormatoCancelled())
        }
        // The default (task cancellation) leaves an uncancelled caller alone.
        XCTAssertNoThrow(try r.readSpectrumImage())
    }

    // MARK: Progress

    /// Monotone, strictly increasing, many steps (block resolution), ending at exactly 1.
    func testProgressIsMonotoneAndEndsAtOne() throws {
        func check(_ name: String, _ run: (@escaping @Sendable (Double) -> Void) throws -> Void) rethrows {
            let seen = Box<[Double]>([])
            try run { f in seen.mutate { $0.append(f) } }
            let v = seen.value
            XCTAssertGreaterThanOrEqual(v.count, 3, name)
            XCTAssertEqual(v.last, 1, name)
            XCTAssertTrue(v.allSatisfy { $0 > 0 && $0 <= 1 }, name)
            XCTAssertEqual(v, v.sorted(), "\(name): not monotone")
            XCTAssertEqual(Set(v).count, v.count, "\(name): repeated value")
        }
        let r = reader()
        try check("readSpectrumImage") { p in _ = try r.readSpectrumImage(progress: p) }
        try check("streamLengthAndMarkers") { p in _ = try r.streamLengthAndMarkers(progress: p) }
        try check("markersPerFrame") { p in _ = try r.markersPerFrame(progress: p) }
        let source: VeloxStreamDecoder.BlockSource = { visit in _ = try [UInt16(1), 65535].withUnsafeBufferPointer { try visit($0) } }
        try check("buildEventStore") { p in
            _ = try VeloxStreamDecoder.buildEventStore(
                streams: [source, source], geometry: VeloxStreamGeometry(ny: 1, nx: 1, channels: 4), frames: 0..<1, progress: p)
        }
    }

    // MARK: Library lookup (E6)

    /// The default list is the app's (env override, bundled Frameworks, loader path); a host can replace it, and the
    /// reader then looks only there.
    func testLibraryCandidatesDefaultAndOverride() throws {
        let original = VeloxHDF5Library.libraryCandidates
        defer { VeloxHDF5Library.libraryCandidates = original }
        XCTAssertEqual(VeloxHDF5Library.libraryCandidates(), VeloxHDF5Library.defaultCandidates())
        XCTAssertEqual(VeloxHDF5Library.defaultCandidates().last, "libhdf5.dylib")
        VeloxHDF5Library.libraryCandidates = { ["/nonexistent/libhdf5-not-here.dylib"] }
        XCTAssertThrowsError(try reader().readSpectrumImage()) { error in
            guard case VeloxEMDError.libraryUnavailable(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("libhdf5-not-here"), why)
        }
        VeloxHDF5Library.libraryCandidates = original
        XCTAssertNoThrow(try reader().readSpectrumImage())
    }
}
