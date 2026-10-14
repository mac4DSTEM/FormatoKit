//
//  HDF5ExitBarrierTests.swift
//  Role: Gate for the bounded quit barrier (SpectroKit 0.2.0; macTEM ADR 021). `exit()` runs the atexit handlers,
//        which a test cannot watch from inside its own process, so each scenario runs in `FormatoHDF5ExitProbe` (a
//        child process; Tests/FormatoHDF5ExitProbe/main.swift) and the test reads what it wrote and how it ended.
//
//  The probe registers a stand-in for HDF5's `H5_term_library` BEFORE it installs the barrier, as HDF5 registers its
//  own inside the first `H5open`, before the loaders install the barrier. atexit is last in, first out: the barrier
//  runs first, the stand-in ("teardown-ran") after it, and `_exit(70)` must skip it. The barrier's promise is that the
//  HDF5 lock is still HELD when the teardown starts, so the stand-in has a second thread try `HDF5Serial.run {}` for
//  0.3 s and writes "teardown-ran lock-held" if it did not get in, "teardown-ran lock-free" if it did. Every test that
//  expects the teardown expects "lock-held": a stand-in that only said it ran would pass a barrier that took the lock
//  and gave it back.
//
//  The sixth test has no stand-in, because it asks what the five cannot: whether the REAL loader installs the barrier
//  after HDF5's own handler. The probe's `velox-order` mode opens velox-tiny.emd through the public
//  `SpectrumImageOpener.open` and installs nothing itself; it asks the libhdf5 the loader loaded for `H5atclose`,
//  HDF5's hook that calls back as the real `H5_term_library` starts, and the callback reports whether the lock is
//  held. The mode also checks the lock is free just before `exit`, so a "lock-held" cannot come from a hold the open
//  leaked. `MAC4DSTEM_HDF5_PATH` (tools/test.sh sets it) reaches the child through the inherited environment.
//
//  Every probe runs under a hard deadline: a barrier that waits for ever (the 0.1.0 shape) goes red with "did not exit
//  within N s" after the child is killed, and never hangs the suite.
//
//  The one timing assertion (a stuck holder is waited for the bound, not less) measures from the child's own clock,
//  not from when the test's pipe handler ran. The probe writes `calling-exit <ns>` (CLOCK_UPTIME_RAW, system-wide)
//  just before `exit`; the test reads the same clock in the termination handler. A handler that runs late can only
//  make the measured wait longer than the real one, so the lower bound cannot fail on scheduler latency; the upper
//  bound has 5 s of room for it. Checked: a `usleep(300_000)` at the top of the pipe handlers fails a measurement that
//  starts when the handler sees the marker (0.199 s < 0.45 s) and leaves this one green.
//
//  Mutations (each applied alone in a scratch clone, this suite run, the file restored; red tests named; edits are to
//  HDF5Types.swift unless the line says otherwise; "velox" is the sixth test):
//    handler `lock.lock(); return` (0.1.0: unbounded)       -> stuck: "did not exit within 10.5 s", child killed
//    `_exit(70)` -> `return`                                -> stuck: status 0, teardown ran
//    `_exit(70)` -> `_exit(0)`                              -> stuck: status 0
//    `Date(timeIntervalSinceNow: exitBarrierBound)` -> `Date()`
//                                                           -> held-briefly: status 70, no "released";
//                                                              stuck: left after 0.0007 s, not 0.45 s or more
//    handler body just `return` (no barrier)                -> held-briefly: no "released"; stuck: status 0, teardown
//                                                              ran, left after 0.31 s; free, default bound and velox:
//                                                              "lock-free"
//    `installExitBarrier` registers nothing (`exitBarrierInstalled = true`)
//                                                           -> the same five tests as the line above
//    wait of `exitBarrierBound + 8`                         -> stuck: 8.5 s, not under 5.5 s
//    `Atomic<Int>(10_000)` -> `Atomic<Int>(5_000)`          -> default bound: "5.0", not "10.0"
//    `if lock.lock(before:)` -> `if !lock.lock(before:)`    -> all six: free, held-by-caller, held-briefly, default
//                                                              bound and velox exit with 70 and the barrier line;
//                                                              stuck leaves with status 0, teardown ran
//    `NSRecursiveLock()` -> `NSLock()`                      -> held-by-caller: status 70 after waiting the 2 s bound;
//                                                              velox: "did not exit within 30.0 s", child killed
//    `write(STDERR_FILENO` -> `write(STDOUT_FILENO`         -> stuck: stderr empty, the line in stdout
//    `setExitBarrierBound` stores `Int(seconds)`            -> held-briefly: status 70; stuck: left after 0.0006 s
//    `{ return }` -> `{ lock.unlock(); return }` after the lock is taken (the barrier gives the lock back)
//                                                           -> free, held-briefly, default bound and velox:
//                                                              "lock-free"; held-by-caller stays green, its own
//                                                              thread holds the lock
//    VeloxEMDReader.swift: `installExitBarrier()` before `open()` instead of after a successful one
//                                                           -> velox: "h5-teardown lock-free"
//    VeloxEMDReader.swift: `HDF5Serial.acquire()` after the install (a hold leaked by the open)
//                                                           -> velox: "lock-held-before-exit"
//    probe: the `H5atclose` call replaced by `0` (no callback)
//                                                           -> velox: no "h5-teardown" line
//  Each of the six tests is red under two or more of these.
//

import Testing
import FormatoHDF5
import Foundation

@Suite(.serialized) final class HDF5ExitBarrierTests {
    /// The one stderr line the barrier writes before `_exit(70)` (HDF5Types.swift, `exitBarrier()`), newline included.
    private static let barrierLine =
        "FormatoKit: HDF5Serial's quit barrier passed its bound with the HDF5 lock still held; "
        + "_exit(70) without HDF5's shutdown\n"
    private static let teardown = "teardown-ran lock-held\n"
    private static let calling = "calling-exit\n"

    // MARK: The child process

    /// What the pipes' handlers (their own threads) and the termination handler hand to the test thread.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var endedAt: UInt64?

        func appendStdout(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
        func appendStderr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }
        /// Read in the termination handler, which runs after the child is gone: never earlier than the child's end.
        func markEnded() { lock.lock(); endedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); lock.unlock() }
        func snapshot() -> (out: String, err: String, endedAt: UInt64?) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), endedAt)
        }
    }

    private struct Outcome {
        var status: Int32
        var reason: Process.TerminationReason
        /// Exactly what the probe wrote to stdout, `calling-exit <ns>` stamp included.
        var stdout: String
        var stderr: String
        /// `stdout` with the stamp line reduced to `calling-exit`, so the markers compare as plain text.
        var markers: String
        /// The probe's clock (CLOCK_UPTIME_RAW, ns) just before it called `exit`; nil if the stamp is missing.
        var calledExitAt: UInt64?
        /// The same clock in the test, read after the child was gone.
        var endedAt: UInt64?
        var timedOut: Bool

        /// Seconds from the child's `exit` call to the test seeing the child gone: at least the barrier's real wait.
        var secondsInExit: Double? {
            guard let calledExitAt, let endedAt else { return nil }
            return Double(Int64(bitPattern: endedAt &- calledExitAt)) / 1e9
        }
    }

    /// Splits the `calling-exit <ns>` line off the probe's stdout: the markers as plain text, and the stamp.
    private static func splitStamp(_ stdout: String) -> (markers: String, calledExitAt: UInt64?) {
        var stamp: UInt64?
        let prefix = "calling-exit "
        let lines = stdout.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix(prefix), let ns = UInt64(line.dropFirst(prefix.count)) else { return line }
            stamp = ns
            return "calling-exit"
        }
        return (lines.joined(separator: "\n"), stamp)
    }

    /// `swift test` puts the probe (an executable the test target depends on) next to the .xctest bundle.
    private func probeURL() throws -> URL {
        let url = Bundle(for: HDF5ExitBarrierTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("FormatoHDF5ExitProbe")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let message = "FormatoHDF5ExitProbe is not next to the test bundle (looked at \(url.path)). "
                + "FormatoHDF5Tests depends on that executable target (Package.swift): run through "
                + "tools/test.sh / `swift test`, which builds it."
            Issue.record(Comment(rawValue: message))
            throw NSError(domain: "HDF5ExitBarrierTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return url
    }

    /// Runs the probe in `mode`, reading both pipes to EOF concurrently (no pipe-buffer deadlock). The child inherits
    /// this process's environment, `MAC4DSTEM_HDF5_PATH` among it. If the child is still there after `deadline`
    /// seconds it is terminated (then killed), the test fails with "did not exit within", and `timedOut` is set so
    /// the caller stops asserting on a half-run.
    private func runProbe(
        _ mode: String, bound: Double? = nil, arguments: [String] = [], deadline: TimeInterval
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = try probeURL()
        process.arguments = [mode] + (bound.map { [String($0)] } ?? []) + arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let capture = Capture()
        let drained = DispatchGroup()
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; drained.leave(); return }
                if isStdout { capture.appendStdout(data) } else { capture.appendStderr(data) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in capture.markEnded(); exited.signal() }
        try process.run()

        var timedOut = false
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            Issue.record("FormatoHDF5ExitProbe \(mode) did not exit within \(deadline) s (terminated by the test)")
        }
        if drained.wait(timeout: .now() + 5) == .timedOut {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            Issue.record("FormatoHDF5ExitProbe \(mode): its pipes did not reach EOF")
        }
        let seen = capture.snapshot()
        let (markers, calledExitAt) = Self.splitStamp(seen.out)
        return Outcome(
            status: process.terminationStatus, reason: process.terminationReason, stdout: seen.out, stderr: seen.err,
            markers: markers, calledExitAt: calledExitAt, endedAt: seen.endedAt, timedOut: timedOut)
    }

    /// Index of `needle` in `haystack`, as an offset, or nil.
    private func offset(of needle: String, in haystack: String) -> Int? {
        haystack.range(of: needle).map { haystack.distance(from: haystack.startIndex, to: $0.lowerBound) }
    }

    private func assertNoBarrierLine(
        _ outcome: Outcome, _ mode: String, fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column
    ) {
        #expect(!outcome.stderr.contains("quit barrier"), "\(mode): the barrier fired when it should not have: \(outcome.stderr)", sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
        #expect(outcome.stderr == "", "\(mode): nothing is written to stderr on a clean exit", sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
    }

    // MARK: The five scenarios

    /// Nobody holds the lock: the barrier takes it at once, and `exit(0)` goes on to the handlers registered before it.
    @Test func testExitWithTheLockFreeEndsCleanlyAndHDF5TeardownRuns() throws {
        let run = try runProbe("free", deadline: 20)
        guard !run.timedOut else { return }
        #expect(run.reason == .exit, "ended by exit(), not a signal")
        #expect(run.status == 0)
        #expect(run.markers == Self.calling + Self.teardown, "the teardown handler ran after exit() was called")
        assertNoBarrierLine(run, "free")
    }

    /// The thread that calls `exit` already holds the lock: the lock is recursive, so the barrier goes straight
    /// through. The bound is 2 s here (the default 10 s would make a failure slow): a non-recursive lock waits it out
    /// and leaves with status 70.
    @Test func testExitOnTheThreadThatHoldsTheLockGoesStraightThrough() throws {
        let run = try runProbe("held-by-caller", bound: 2, deadline: 20)
        guard !run.timedOut else { return }
        #expect(run.reason == .exit)
        #expect(run.status == 0)
        #expect(run.markers == Self.calling + Self.teardown)
        assertNoBarrierLine(run, "held-by-caller")
    }

    /// Another thread is inside a locked operation (0.4 s) when `exit` is called: the barrier waits for it, and only
    /// then does the teardown run. This is what the barrier is for; "released" must come first in the child's stdout.
    @Test func testExitWaitsForTheOperationInFlightBeforeTheTeardown() throws {
        let run = try runProbe("held-briefly", bound: 5, deadline: 20)
        guard !run.timedOut else { return }
        #expect(run.reason == .exit)
        #expect(run.status == 0, "the lock came back inside the bound: a normal exit, not _exit(70)")
        let released = offset(of: "released\n", in: run.markers)
        let teardown = offset(of: Self.teardown, in: run.markers)
        #expect(released != nil, "the holder finished and wrote \"released\": \(run.stdout.debugDescription)")
        #expect(teardown != nil, "the teardown ran: \(run.stdout.debugDescription)")
        if let released, let teardown {
            #expect(released < teardown, "the barrier waited for the operation in flight: \(run.stdout.debugDescription)")
        }
        assertNoBarrierLine(run, "held-briefly")
    }

    /// A thread that never lets go: the barrier gives up at the bound, writes its one line and `_exit(70)`s, so the
    /// handlers registered before it (HDF5's shutdown) do not run. The wait is the bound, neither shorter nor
    /// open-ended.
    @Test func testExitWithAStuckHolderLeavesAtTheBoundWithStatus70AndSkipsTheTeardown() throws {
        let bound = 0.5
        let run = try runProbe("stuck", bound: bound, deadline: bound + 10)
        guard !run.timedOut else { return }
        #expect(run.reason == .exit, "_exit(70) is an exit, not a signal")
        #expect(run.status == 70, "EX_SOFTWARE")
        #expect(run.stderr == Self.barrierLine, "exactly the barrier's one line")
        #expect(!run.stdout.contains("teardown-ran"), Comment(rawValue: "_exit skipped the handlers registered before the barrier (HDF5's shutdown): "
                + "\(run.stdout.debugDescription)"))
        #expect(run.markers == Self.calling)
        guard let seconds = run.secondsInExit else {
            Issue.record("the child's calling-exit stamp or its end was not seen: \(run.stdout.debugDescription)")
            return
        }
        // 0.05 s: the barrier's Date is on the wall clock, the stamps are on the uptime clock.
        #expect(seconds >= bound - 0.05, "the barrier waited the bound (\(bound) s) before giving up")
        #expect(seconds < bound + 5, "and did not wait much longer than the bound")
    }

    // MARK: The real loader

    /// The small Velox spectrum image of FormatoEMDTests' fixtures, by this file's path.
    private static let veloxTiny = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FormatoEMDTests/Fixtures/velox-tiny.emd")

    /// What the other five scenarios cannot show: that the REAL loader puts the barrier behind HDF5's own handler. The
    /// probe opens velox-tiny.emd through the public API and installs nothing itself; HDF5 calls a callback of the
    /// probe's as its `H5_term_library` starts, and the lock must be held then. A loader that installed the barrier
    /// before `H5open` would register it before HDF5's handler, so it would run after the teardown: "lock-free".
    @Test func testTheVeloxLoaderInstallsTheBarrierAfterHDF5sOwnTeardownHandler() throws {
        guard ProcessInfo.processInfo.environment["MAC4DSTEM_HDF5_PATH"] != nil else {
            Issue.record("MAC4DSTEM_HDF5_PATH is not set: run through tools/test.sh, which sets it for the probe too")
            return
        }
        let run = try runProbe("velox-order", arguments: [Self.veloxTiny.path], deadline: 30)
        guard !run.timedOut else { return }
        #expect(run.reason == .exit)
        #expect(run.status == 0, "stdout \(run.stdout.debugDescription), stderr \(run.stderr.debugDescription)")
        #expect(run.markers == "opened\nlock-free-before-exit\n" + Self.calling + "h5-teardown lock-held\n", "the file opened, the lock was free before exit, and HDF5's teardown found it held")
        assertNoBarrierLine(run, "velox-order")
    }

    /// Without `setExitBarrierBound` the bound a host gets is 10 s.
    @Test func testTheDefaultBoundIsTenSeconds() throws {
        let run = try runProbe("print-bound", deadline: 20)
        guard !run.timedOut else { return }
        #expect(run.status == 0)
        #expect(run.stdout == "10.0\n" + Self.teardown, "the bound, then the ordinary exit")
        assertNoBarrierLine(run, "print-bound")
    }
}
