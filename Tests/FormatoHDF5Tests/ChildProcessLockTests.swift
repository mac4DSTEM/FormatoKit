//
//  ChildProcessLockTests.swift
//  FormatoKit#49: "unable to lock file, errno = 35" in a write-then-read test, about one run in five when every suite runs in one
//  process (the combined test bundle the CI toolchain builds).
//
//  Cause: libhdf5 `flock`s every file it opens (LOCK_EX for a write, LOCK_SH for a read). A child process started while a file
//  is open for writing gets a copy of that descriptor and holds it until its `exec`, even with POSIX_SPAWN_CLOEXEC_DEFAULT. When
//  the writer's `H5Fclose` falls in that window the LOCK_EX lives on in the child, and the read-only `H5Fopen` that follows
//  fails with EWOULDBLOCK (35). MIBTests and EMPADTests ran `/usr/bin/gzip` that way, the quit-barrier tests run their probe.
//  Measured: 5 of 21 runs failed with the gzip children, 0 of 20 with MIBTests, EMPADTests and HDF5ExitBarrierTests skipped.
//
//  The fix is in the tests: the gzip fixtures are inflated in process (FormatoKitTestSupport.Gunzip), and the one child left (the
//  quit-barrier probe) is started by `startUnderHDF5Lock`, inside `HDF5Serial`. Every HDF5 write holds that lock from its open to
//  its close, and `Process.run()` returns after the child's `exec`, so no child can copy a descriptor that holds a write lock.
//
//  This test is the race on purpose: one thread starts children, the other writes and reads back small HDF5 files. With
//  `startUnderHDF5Lock` changed to call `process.run()` alone it fails with the lock error (checked: 78 of 2216 cycles failed).
//

import Foundation
import Synchronization
import Testing
import FormatoHDF5

/// Starts `process` inside `HDF5Serial`: the child cannot copy a descriptor of a file an HDF5 call has open for writing.
func startUnderHDF5Lock(_ process: Process) throws {
    try HDF5Serial.run { try process.run() }
}

@Suite struct ChildProcessLockTests {
    @Test func aChildStartedDuringWritesLeavesNoLockOnTheReadThatFollows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-child-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let done = DispatchSemaphore(value: 0)
        let spawnFailures = Mutex<[String]>([])
        let children = 300
        Thread.detachNewThread {
            for _ in 0..<children {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                do { try startUnderHDF5Lock(child); child.waitUntilExit() } catch {
                    spawnFailures.withLock { $0.append("\(error)") }
                }
            }
            done.signal()
        }

        var cycles = 0
        var lockFailures: [String] = []
        while done.wait(timeout: .now()) == .timedOut {
            let file = dir.appendingPathComponent("f\(cycles).h5")
            do {
                try HDF5RootAttributes.write([("n", String(cycles))], to: file)
                #expect(try HDF5RootAttributes.read(["n"], from: file)["n"] == String(cycles))
            } catch {
                lockFailures.append("\(error)")
            }
            try? FileManager.default.removeItem(at: file)
            cycles += 1
        }
        #expect(spawnFailures.withLock { $0 }.isEmpty)
        #expect(cycles >= 50, "only \(cycles) write-read cycles overlapped the \(children) children")
        let failed = lockFailures.count
        #expect(failed == 0, "\(failed) of \(cycles) cycles failed: \(lockFailures.first ?? "")")
    }
}
