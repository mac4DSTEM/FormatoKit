//
//  HDF5RootAttributes.swift
//  A small HDF5 file whose content is string attributes on the root group (a session sidecar), written, read and published
//  safely through the one shared HDF5 loader (`SharedHDF5`, under `HDF5Serial`). The data model of such a file (which
//  attributes, schema markers, lineage) belongs to the caller; this is the file layer:
//
//  - WRITE: one scalar fixed-length UTF-8 null-padded string attribute per entry, exactly as long as the text's UTF-8 bytes
//    (an empty text is one NUL: HDF5 has no string type of size 0), in a file created with library-version bounds
//    (V18, LATEST) so the attributes stay in the checksummed object header. The close is checked: a close that fails to
//    flush is a failed write.
//  - READ: a scalar fixed-length string only (a variable-length string is refused by name from its type, before it is
//    read), at most `maximumStringBytes` of storage, valid UTF-8 followed by nothing but NUL padding. Before any attribute is
//    opened the root object header alone is read and a root that keeps its attributes in dense storage is refused (a crafted
//    dense file can crash libhdf5 or spin it); a denied read is told from a file that is not HDF5.
//  - PUBLISH: the finished file is renamed onto the destination only over the very file that was checked (device and inode
//    taken before it was opened); nothing there before means an exclusive rename. The scratch file is built in the system's
//    item-replacement directory, not beside the destination, because under the app sandbox a save panel grants the chosen
//    file and not new files next to it; the rename stays atomic because that directory is on the destination's volume.
//
//  Moved from the first consumer's session sidecar writer (macTEM cb6e164 SidecarHDF5.swift, SessionSidecarFile.swift); the
//  consumer's second binding to libhdf5 is dropped for `SharedHDF5`.
//

import Darwin
import Foundation

/// Why an HDF5 root-attribute file could not be read, written or published.
public nonisolated enum HDF5FileError: Error, Sendable, Equatable, LocalizedError {
    /// libhdf5 could not be loaded.
    case library(String)
    /// The URL is not a file URL, or the file cannot be opened as HDF5 (not HDF5, truncated, missing).
    case cannotOpen(String)
    /// The file is there and the system does not let this process read it.
    case notPermitted(String)
    /// An HDF5 call failed after the file opened: the operation, and why.
    case hdf5(operation: String, detail: String)
    /// An attribute that is not a scalar fixed-length string, or is text followed by anything but NUL padding.
    case malformedAttribute(String)
    /// A variable-length string attribute, which is never read.
    case variableLengthString(String)
    /// A string attribute whose storage is over the cap.
    case stringTooLong(attribute: String, bytes: Int)
    /// A string attribute that is not valid UTF-8.
    case invalidUTF8(String)
    /// The root keeps its attributes in dense storage, which is not read.
    case denseAttributeStorage
    /// A text to write that holds a NUL byte, which a stored string cannot.
    case embeddedNUL(String)
    /// A write failed while `operation`; nothing was changed.
    case cannotWrite(operation: String, detail: String)
    /// A path that names no object (or whose parent does not exist) in the file.
    case notFound(String)
    /// A path that names an object of another kind than the call needs (`expected`: "group" or "dataset").
    case wrongKind(path: String, expected: String)
    /// A path that already names something, and the call was not asked to replace it.
    case alreadyExists(String)
    /// A path that is empty, holds a NUL byte, or has a `.` or `..` component.
    case invalidPath(String)
    /// A dataset or attribute whose stored type this layer does not take, named (for example `compound`, `enum`, `float16`).
    case unsupportedType(path: String, type: String)
    /// A rank, size or count over the limit for one read, or an element count that overflows.
    case limitExceeded(String)
    /// An argument the call refuses (a slab outside the dataset, a chunk that does not fit, a type that cannot be written).
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .library(let detail): "the HDF5 library could not be loaded (\(detail))."
        case .cannotOpen(let detail): "the file cannot be opened as HDF5 (\(detail))."
        case .notPermitted(let detail): "the system does not let this process read the file (\(detail))."
        case .hdf5(let operation, let detail): "HDF5 failed while \(operation) (\(detail))."
        case .malformedAttribute(let name): "its \(name) attribute is not a scalar fixed-length string of text and NUL padding."
        case .variableLengthString(let name): "its \(name) attribute is a variable-length string, which is not read."
        case .stringTooLong(let attribute, let bytes): "its \(attribute) attribute is \(bytes) bytes, over the limit."
        case .invalidUTF8(let name): "its \(name) attribute is not valid UTF-8."
        case .denseAttributeStorage: "its attributes are stored in HDF5 dense attribute storage, which is not read."
        case .embeddedNUL(let name): "the \(name) text holds a NUL byte, which a stored string cannot."
        case .cannotWrite(let operation, let detail): "the write failed while \(operation) (\(detail)); nothing was changed."
        case .notFound(let path): "there is nothing at \(path)."
        case .wrongKind(let path, let expected): "\(path) is not a \(expected)."
        case .alreadyExists(let path): "\(path) already exists."
        case .invalidPath(let path): "\(path) is not a valid HDF5 path."
        case .unsupportedType(let path, let type): "\(path) has the stored type \(type), which is not taken."
        case .limitExceeded(let detail): "over a limit (\(detail))."
        case .invalidArgument(let detail): "invalid argument (\(detail))."
        }
    }
}

/// The device and inode of an item at a path (a link itself, not its target): what `HDF5RootAttributes.publish` checks.
public nonisolated struct HDF5FileIdentity: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64

    /// The identity of the item AT `path`, or nil when nothing is there (a dangling link is something).
    public init?(ofItemAt path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

public nonisolated enum HDF5RootAttributes {
    /// The default cap on the storage of one string attribute read: 4 MiB.
    public static let defaultMaximumStringBytes = 4 << 20

    // MARK: Reading

    /// The root-group string attributes `names` of the HDF5 file at `url`: nil for an absent one.
    /// - Parameter refuseDenseStorage: refuse (by name) a root whose attributes are in dense storage before any is opened.
    public static func read(_ names: [String], from url: URL, maximumStringBytes: Int = defaultMaximumStringBytes,
                            refuseDenseStorage: Bool = true) throws -> [String: String] {
        try withLibrary { h5 in
            let file = try openForReading(url, h5)
            defer { _ = h5.h5fclose(file) }
            if refuseDenseStorage { try requireCompactAttributes(of: file, h5) }
            var out: [String: String] = [:]
            for name in names {
                if let text = try readString(name, of: file, maximumStringBytes: maximumStringBytes, h5) { out[name] = text }
            }
            return out
        }
    }

    // MARK: Writing

    /// Builds the whole file at `temporary` (created new, truncating): one string attribute per entry on the root group.
    /// Throws `embeddedNUL` before touching the disk for a text with a NUL byte.
    public static func write(_ attributes: [(name: String, value: String)], to temporary: URL) throws {
        for (name, value) in attributes where value.utf8.contains(0) { throw HDF5FileError.embeddedNUL(name) }
        guard temporary.isFileURL else { throw HDF5FileError.cannotWrite(operation: "locating the file", detail: "not a file URL") }
        try withLibrary { h5 in
            let access = h5.h5pcreate(h5.fileAccessClass)
            guard access >= 0 else { throw failure("making the file-access properties", h5) }
            defer { _ = h5.h5pclose(access) }
            // H5F_LIBVER_V18 = 1 and H5F_LIBVER_LATEST = 5 (V200) in the shipped libhdf5 2.1.1; the library refuses a value it
            // does not know, so a different library fails the write by name rather than writing another format.
            guard h5.h5psetLibverBounds(access, 1, 5) >= 0 else { throw failure("setting the library-version bounds", h5) }
            let file = temporary.path.withCString { h5.h5fcreate($0, 0x0002, 0, access) }   // H5F_ACC_TRUNC
            guard file >= 0 else { throw failure("creating the file", h5) }
            var closed = false
            defer { if !closed { _ = h5.h5fclose(file) } }
            for (name, value) in attributes { try writeString(name, value, on: file, h5) }
            closed = true
            guard h5.h5fclose(file) >= 0 else { throw failure("closing the file", h5) }
        }
    }

    // MARK: Publishing

    /// A scratch URL to build the file at before it is published onto `destination`: in the system's item-replacement
    /// directory (writable under the sandbox, on `destination`'s volume), else beside `destination`. The name is short and
    /// fixed-length, because a destination's own name may already be 255 UTF-16 units. `scratchDirectory` is the directory the
    /// system made, to remove afterwards, or nil for the sibling fallback.
    public static func temporaryURL(for destination: URL, namePrefix: String = ".formato-")
        -> (url: URL, scratchDirectory: URL?) {
        let name = "\(namePrefix)\(UUID().uuidString).tmp"
        if let directory = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true) {
            return (directory.appendingPathComponent(name, isDirectory: false), directory)
        }
        return (destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false), nil)
    }

    /// Moves the finished file onto `url` without destroying anything but the very file that was checked: `checked` is the
    /// identity taken before that file was opened, nil when nothing was there (then an exclusive rename refuses to replace
    /// what has appeared since). `exclusiveRenameUnavailable` makes a nil `checked` take the look-then-rename path of a
    /// volume without `RENAME_EXCL` (exFAT); a test hook, false in production.
    public static func publish(_ temporary: URL, onto url: URL, replacing checked: HDF5FileIdentity?,
                               exclusiveRenameUnavailable: Bool = false) throws {
        let changed: Int32 = -1       // not an errno: the target is no longer what was checked
        func attempt(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>) -> Int32 {
            if let checked {
                guard HDF5FileIdentity(ofItemAt: url.path) == checked else { return changed }
                return Darwin.rename(from, to) == 0 ? 0 : errno
            }
            let exclusive = exclusiveRenameUnavailable ? ENOTSUP : (renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno)
            guard exclusive == ENOTSUP else { return exclusive }
            guard HDF5FileIdentity(ofItemAt: url.path) == nil else { return EEXIST }
            return Darwin.rename(from, to) == 0 ? 0 : errno
        }
        let code = temporary.path.withCString { from in url.path.withCString { to in attempt(from, to) } }
        switch code {
        case 0: return
        case changed:
            throw HDF5FileError.cannotWrite(operation: "publishing the file",
                                            detail: "the file was replaced or removed after it was checked; it was left as it is")
        case EEXIST where checked == nil:
            throw HDF5FileError.cannotWrite(operation: "publishing the file",
                                            detail: "a file appeared at the path after it was checked; it was left as it is")
        default:
            throw HDF5FileError.cannotWrite(operation: "publishing the file", detail: String(cString: strerror(code)))
        }
    }

    // MARK: Internals

    static func withLibrary<T>(_ body: (SharedHDF5) throws -> T) throws -> T {
        try HDF5Serial.run {
            let h5: SharedHDF5
            do { h5 = try SharedHDF5.loadStandard() } catch HDF5DatacubeError.libraryUnavailable(let detail) {
                throw HDF5FileError.library(detail)
            }
            return try body(h5)
        }
    }

    static func openForReading(_ url: URL, _ h5: SharedHDF5) throws -> hid_t {
        guard url.isFileURL else { throw HDF5FileError.cannotOpen("not a file URL") }
        // The open HDF5 would make, made first, only to tell a denied read from a file that is not HDF5: HDF5's error stack does
        // not keep errno. A missing file is left to HDF5 (`cannotOpen`).
        let probe = url.path.withCString { Darwin.open($0, O_RDONLY) }
        let code = probe >= 0 ? 0 : errno
        if probe >= 0 { _ = Darwin.close(probe) }
        if code == EPERM || code == EACCES { throw HDF5FileError.notPermitted(String(cString: strerror(code))) }
        let file = url.path.withCString { h5.h5fopen($0, 0x0000, 0) }
        guard file >= 0 else { throw HDF5FileError.cannotOpen(errorStack(h5) ?? "HDF5 gave no reason") }
        return file
    }

    /// `hdr.nmesgs` at 4 and `hdr.mesg.present` at 48 of `H5O_native_info_t` (bit n set when a message of type n is in the
    /// header), measured on the shipped libhdf5 2.1.1; the attribute message is type 12, the attribute-info message 21.
    private static let nativeInfoBytes = 256
    private static let fieldHeader: UInt32 = 0x0008          // H5O_NATIVE_INFO_HDR: the checksummed object header, no heap
    private static let presentOffset = 48

    /// A root whose object header carries an attribute-info message and no attribute message keeps its attributes in dense
    /// storage; a crafted such file can crash libhdf5 or spin it at the first attribute access. Only the header is read.
    /// A filter, not a guarantee: a forger can recompute the checksum.
    private static func requireCompactAttributes(of file: hid_t, _ h5: SharedHDF5) throws {
        let root = "/".withCString { h5.h5oopen(file, $0, 0) }
        guard root >= 0 else { throw hdf5Failure("opening the root group", h5) }
        defer { _ = h5.h5oclose(root) }
        var native = [UInt8](repeating: 0, count: nativeInfoBytes)
        guard native.withUnsafeMutableBytes({ h5.h5ogetNativeInfo(root, $0.baseAddress, fieldHeader) }) >= 0 else {
            throw hdf5Failure("reading the root's object header", h5)
        }
        let present = native.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: presentOffset, as: UInt64.self) }
        if present & (UInt64(1) << 21) != 0, present & (UInt64(1) << 12) == 0 { throw HDF5FileError.denseAttributeStorage }
    }

    private static func readString(_ name: String, of file: hid_t, maximumStringBytes: Int, _ h5: SharedHDF5) throws -> String? {
        let exists = name.withCString { h5.h5aexists(file, $0) }
        guard exists >= 0 else { throw hdf5Failure("looking for the \(name) attribute", h5) }
        guard exists > 0 else { return nil }
        let attribute = name.withCString { h5.h5aopen(file, $0, 0) }
        guard attribute >= 0 else { throw hdf5Failure("opening the \(name) attribute", h5) }
        defer { _ = h5.h5aclose(attribute) }
        let space = h5.h5agetSpace(attribute)
        guard space >= 0 else { throw hdf5Failure("opening the \(name) attribute's space", h5) }
        defer { _ = h5.h5sclose(space) }
        // Scalar: rank 0 holding one element (rank 0 with none is HDF5's null dataspace; rank 1 is an array).
        guard h5.h5sgetNdims(space) == 0, h5.h5sgetNpoints(space) == 1 else { throw HDF5FileError.malformedAttribute(name) }
        let type = h5.h5agetType(attribute)
        guard type >= 0 else { throw hdf5Failure("opening the \(name) attribute's type", h5) }
        defer { _ = h5.h5tclose(type) }
        guard h5.h5tgetClass(type) == 3 else { throw HDF5FileError.malformedAttribute(name) }          // H5T_STRING
        let variable = h5.h5tisVariableStr(type)
        guard variable >= 0 else { throw hdf5Failure("reading the \(name) attribute's type", h5) }
        guard variable == 0 else { throw HDF5FileError.variableLengthString(name) }
        let size = h5.h5tgetSize(type)
        guard size > 0 else { throw hdf5Failure("reading the \(name) attribute's size", h5) }
        guard size <= maximumStringBytes else { throw HDF5FileError.stringTooLong(attribute: name, bytes: size) }
        var storage = [UInt8](repeating: 0, count: size)
        guard storage.withUnsafeMutableBytes({ h5.h5aread(attribute, type, $0.baseAddress) }) >= 0 else {
            throw hdf5Failure("reading the \(name) attribute", h5)
        }
        // The text, then only padding: a NUL inside the text would end it for any C reader and silently lose the rest.
        let length = storage.firstIndex(of: 0) ?? size
        guard storage[length...].allSatisfy({ $0 == 0 }) else { throw HDF5FileError.malformedAttribute(name) }
        guard let text = String(validating: storage[..<length], as: UTF8.self) else { throw HDF5FileError.invalidUTF8(name) }
        return text
    }

    static func writeString(_ name: String, _ value: String, on file: hid_t, _ h5: SharedHDF5) throws {
        let stored = value.isEmpty ? [UInt8(0)] : Array(value.utf8)
        let type = h5.h5tcopy(h5.stringC1)
        guard type >= 0 else { throw failure("making the text type for \(name)", h5) }
        defer { _ = h5.h5tclose(type) }
        // H5T_CSET_UTF8 = 1, H5T_STR_NULLPAD = 1.
        guard h5.h5tsetSize(type, stored.count) >= 0, h5.h5tsetCset(type, 1) >= 0, h5.h5tsetStrpad(type, 1) >= 0 else {
            throw failure("making the UTF-8 text type for \(name)", h5)
        }
        let space = h5.h5screate(0)                                   // H5S_SCALAR
        guard space >= 0 else { throw failure("making the space for \(name)", h5) }
        defer { _ = h5.h5sclose(space) }
        let attribute = name.withCString { h5.h5acreate2(file, $0, type, space, 0, 0) }
        guard attribute >= 0 else { throw failure("creating the \(name) attribute", h5) }
        defer { _ = h5.h5aclose(attribute) }
        guard stored.withUnsafeBytes({ h5.h5awrite(attribute, type, $0.baseAddress) }) >= 0 else {
            throw failure("writing the \(name) attribute", h5)
        }
    }

    static func hdf5Failure(_ operation: String, _ h5: SharedHDF5) -> HDF5FileError {
        .hdf5(operation: operation, detail: errorStack(h5) ?? "HDF5 gave no reason")
    }

    static func failure(_ operation: String, _ h5: SharedHDF5) -> HDF5FileError {
        .cannotWrite(operation: operation, detail: errorStack(h5) ?? "HDF5 gave no reason")
    }

    /// The innermost frame of HDF5's current error stack, with its minor code, or nil if empty. The stack is process-global
    /// (the shipped build is not thread-safe), so call it immediately after the failing call under `HDF5Serial`.
    static func errorStack(_ h5: SharedHDF5) -> String? {
        guard let h5eprint2 = h5.h5eprint2 else { return nil }
        var buffer: UnsafeMutablePointer<CChar>?
        var size = 0
        guard let stream = open_memstream(&buffer, &size) else { return nil }
        _ = h5eprint2(0, stream)
        fclose(stream)
        defer { if let buffer { free(buffer) } }
        guard let buffer, size > 0 else { return nil }
        let lines = String(cString: buffer).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let innermost = lines.last { $0.hasPrefix("#") }.flatMap { frame -> String? in
            guard let range = frame.range(of: "): ", options: .backwards) else { return nil }
            return String(frame[range.upperBound...])
        }
        let minor = lines.last { $0.hasPrefix("minor:") }
            .map { $0.replacingOccurrences(of: "minor:", with: "").trimmingCharacters(in: .whitespaces) }
        switch (innermost, minor) {
        case let (detail?, code?): return "\(detail) [\(code)]"
        case let (detail?, nil): return detail
        case let (nil, code?): return code
        case (nil, nil): return nil
        }
    }
}
