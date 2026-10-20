//
//  HDF5NewFile.swift
//  Role: build a NEW HDF5 file beside its destination and publish it by atomic rename, replacing what is at the destination
//        (unlike `HDF5AppendWriter`, which adds to what is there). Two shapes over one mechanism: `HDF5NewFile.write` runs one
//        body, and `HDF5PendingFile` is kept open across calls (a file filled a tile at a time, with awaits in between;
//        no HDF5 handle and no lock outlives a call).
//
//  The file is built under a scratch name (`HDF5RootAttributes.temporaryURL`, the system's item-replacement folder where the
//  sandbox allows it, so the rename stays on the destination's volume), published only over the item that was there when the
//  build began (`HDF5RootAttributes.publish`), and a failure or a cancel leaves the destination as it was and removes the
//  scratch. A destination that is the source file the content came from is refused before anything is written.
//

import Foundation
import Darwin

/// A new HDF5 file under construction. Not thread-safe: one caller at a time (the typical caller awaits between calls).
public nonisolated final class HDF5PendingFile: @unchecked Sendable {
    public let destination: URL
    /// The scratch file's URL (the tests check it is gone after a publish, a discard or a failure).
    package let scratch: URL
    private let scratchDirectory: URL?
    private let checked: HDF5FileIdentity?
    private var finished = false

    /// Starts a new file for `destination`. Throws `destinationIsSource` when `sourcePath` is the same file (by identity).
    /// The scratch file itself is created by the first `append`.
    public init(destination: URL, sourcePath: String? = nil) throws {
        guard destination.isFileURL else { throw HDF5FileError.cannotOpen("not a file URL") }
        if let sourcePath, Self.sameFile(destination.path, sourcePath) {
            throw HDF5FileError.destinationIsSource(destination.path)
        }
        self.destination = destination
        (scratch, scratchDirectory) = HDF5RootAttributes.temporaryURL(for: destination, namePrefix: ".formato-new-")
        checked = HDF5FileIdentity(ofItemAt: destination.path)
    }

    deinit { if !finished { removeScratch() } }

    /// Runs `body` on the scratch file (created by the first call), in place; the session is valid only inside the call.
    /// A throwing body ends the file: the pending file is abandoned (scratch removed) and every later call throws, because a
    /// failed first body leaves no file and a failed later one leaves a half-written one.
    public func append(_ body: (HDF5WriteSession) throws -> Void) throws {
        guard !finished else { throw HDF5FileError.invalidArgument("the pending file was already published or discarded") }
        do { try HDF5AppendWriter.append(to: scratch, mode: .inPlace, body: body) } catch {
            discard()
            throw error
        }
    }

    /// Moves the finished file onto the destination, replacing the item that was there when this object was made (and only
    /// that one: another file that has appeared since is left alone and the call throws `cannotWrite`). The scratch goes either way. The new file does not inherit the destination's extended attributes, permissions or ACLs.
    public func publish() throws {
        guard !finished else { throw HDF5FileError.invalidArgument("the pending file was already published or discarded") }
        finished = true
        defer { removeScratch() }
        guard FileManager.default.fileExists(atPath: scratch.path) else {
            throw HDF5FileError.invalidArgument("nothing was written to the pending file")
        }
        let descriptor = scratch.path.withCString { Darwin.open($0, O_RDONLY) }
        if descriptor >= 0 { _ = fcntl(descriptor, F_FULLFSYNC); _ = Darwin.close(descriptor) }
        try HDF5RootAttributes.publish(scratch, onto: destination, replacing: checked)
    }

    /// Abandons the file: the scratch is removed and the destination is untouched. Safe to call more than once.
    public func discard() {
        finished = true
        removeScratch()
    }

    private func removeScratch() {
        try? FileManager.default.removeItem(at: scratch)
        if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
    }

    /// One file under two spellings (a symbolic link, a different path): by path after resolving links, then by device and inode.
    static func sameFile(_ a: String, _ b: String) -> Bool {
        let ra = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath()
        let rb = URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath()
        if ra == rb { return true }
        var sa = stat(), sb = stat()
        guard stat(ra.path, &sa) == 0, stat(rb.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}

public nonisolated enum HDF5NewFile {
    /// Builds a new HDF5 file with `body` and publishes it onto `destination` atomically (see `HDF5PendingFile`). Whatever
    /// `body` throws, unchanged; the destination is then as it was and no scratch file is left.
    public static func write(to destination: URL, sourcePath: String? = nil,
                             body: (HDF5WriteSession) throws -> Void) throws {
        let pending = try HDF5PendingFile(destination: destination, sourcePath: sourcePath)
        do {
            try pending.append(body)
            try pending.publish()
        } catch {
            pending.discard()
            throw error
        }
    }
}
