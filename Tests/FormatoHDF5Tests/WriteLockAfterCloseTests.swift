//
//  WriteLockAfterCloseTests.swift
//  FormatoKit#53: a read-only open right after a FormatoHDF5 write failed with "unable to lock file, errno = 35" when the consumer
//  started a child process during the write.
//
//  Cause: libhdf5 `flock`s each file it opens, LOCK_EX for a write. The lock belongs to the open file description, not the
//  descriptor, so it lasts while any copy of the descriptor lives. A child process started while the file is open for writing
//  holds such a copy until its `exec` (FormatoKit#49), and when `H5Fclose` falls in that window the LOCK_EX outlives the close: the
//  shared lock of the read that follows is refused (EWOULDBLOCK).
//
//  The fix: the kit's writers build every file at a private scratch path and publish it by atomic rename, so the lock protects
//  nothing there; they now open those scratch files with file locking off (`H5Pset_file_locking(fapl, false, true)`), and no
//  LOCK_EX exists for a copied descriptor to keep. Reads keep their shared lock (a writer in another program is still seen).
//
//  `testACopiedWriteDescriptorLeavesNoLock` makes the window certain: it copies the scratch file's descriptor inside the append
//  body, as a child would, and keeps it past the close: the gate. `testChildrenStartedDuringWritesLeaveNoLock` is the race
//  itself, with children started outside `HDF5Serial` (before the fix: 61 of 1103 cycles failed). It runs only with
//  FORMATO_CHILD_RACE set: its children copy the descriptors of whatever other suite runs in the process at that moment, the
//  flake of FormatoKit#49 (a read lock copied that way can still refuse another test's in-place append).
//

import Darwin
import Foundation
import Synchronization
import Testing
import FormatoCore
import FormatoHDF5

@Suite struct WriteLockAfterCloseTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-write-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The descriptors of this process whose path names a file starting with `prefix`.
    private func descriptors(namedWith prefix: String) -> [Int32] {
        var out: [Int32] = []
        for fd in Int32(0)..<Int32(getdtablesize()) {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if (path as NSString).lastPathComponent.hasPrefix(prefix) { out.append(fd) }
        }
        return out
    }

    @Test(arguments: [false, true])
    func testACopiedWriteDescriptorLeavesNoLock(existing: Bool) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.h5")
        if existing { try HDF5RootAttributes.write([("n", "0")], to: file) }
        var copies: [Int32] = []
        defer { for fd in copies { close(fd) } }
        try HDF5AppendWriter.append(to: file, mode: .atomicCopy) { session in
            try session.createGroup("/g")
            // What a child started now would hold until its exec: a copy of the scratch file's descriptor.
            copies = descriptors(namedWith: ".formato-append-").map { dup($0) }.filter { $0 >= 0 }
        }
        #expect(!copies.isEmpty, "the scratch file's descriptor was found")
        // The copy is still open; before the fix its LOCK_EX refused this read with errno 35.
        #expect(throws: Never.self) { _ = try HDF5RootAttributes.read([], from: file) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORMATO_CHILD_RACE"] != nil,
                   "starts 300 children outside HDF5Serial; set FORMATO_CHILD_RACE to run it alone"))
    func testChildrenStartedDuringWritesLeaveNoLock() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let done = DispatchSemaphore(value: 0)
        let spawnFailures = Mutex<[String]>([])
        let children = 300
        Thread.detachNewThread {
            for _ in 0..<children {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                // Started as a consumer would, outside HDF5Serial.
                do { try child.run(); child.waitUntilExit() } catch { spawnFailures.withLock { $0.append("\(error)") } }
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
