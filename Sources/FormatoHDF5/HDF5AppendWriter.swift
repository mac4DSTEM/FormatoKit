//
//  HDF5AppendWriter.swift
//  Role: add groups, datasets and attributes to an HDF5 file (new or existing) without disturbing what is already in it,
//        through the one shared loader (`SharedHDF5`, under `HDF5Serial`). What the added content means (a calibration
//        record, a result map, a processing note) belongs to the caller; this is the file layer.
//
//  - `.atomicCopy` (default): the file's bytes are copied to a scratch file (`HDF5RootAttributes.temporaryURL`), the scratch
//    is opened read/write, the body runs, the close is checked, and the scratch is published onto the destination only over
//    the very file that was copied (`HDF5RootAttributes.publish`, identity taken before the copy). Any failure, a throwing
//    body included, leaves the destination byte for byte as it was and removes the scratch.
//  - `.inPlace`: the destination is opened read/write and changed directly. NOT atomic: a failure or a crash partway can
//    leave the file partly changed, or damaged. A file that did not exist and was created by the call is removed on failure.
//
//  The whole call, body included, runs under `HDF5Serial`. The body runs synchronously on the calling thread; it must not
//  wait for another thread that uses HDF5 (that thread would wait for the lock the body's caller holds).
//

import Foundation
import Darwin
import FormatoCore

public nonisolated enum HDF5AppendMode: Sendable, Equatable {
    /// Work on a copy and publish it by atomic rename; the destination is unchanged unless everything succeeds.
    case atomicCopy
    /// Change the destination directly. Not atomic.
    case inPlace
}

public nonisolated enum HDF5AppendWriter {
    /// Opens (or creates) the HDF5 file at `url`, runs `body` with a write session, closes the file with the close checked
    /// and, for `.atomicCopy`, publishes. The session is valid only inside `body`; one used after it throws.
    ///
    /// Unrelated content (root attributes, other groups, datasets, their bytes and attributes) is not touched. Space freed by
    /// `deleteLink` or a replaced dataset is not returned to the file (HDF5 does not reclaim it without a repack).
    ///
    /// - Throws: `HDF5FileError` for the library, the file and the HDF5 calls; whatever `body` throws, unchanged.
    public static func append(to url: URL, mode: HDF5AppendMode = .atomicCopy,
                              body: (HDF5WriteSession) throws -> Void) throws {
        guard url.isFileURL else { throw HDF5FileError.cannotOpen("not a file URL") }
        try HDF5RootAttributes.withLibrary { h5 in
            let identity = HDF5FileIdentity(ofItemAt: url.path)
            if identity != nil {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw HDF5FileError.cannotOpen("the file cannot be examined") }
                if info.st_mode & S_IFMT == S_IFLNK && mode == .atomicCopy {
                    throw HDF5FileError.cannotWrite(operation: "appending",
                        detail: "the destination is a symbolic link; append to its target, or use inPlace")
                }
                var target = stat()
                guard stat(url.path, &target) == 0, target.st_mode & S_IFMT == S_IFREG else {
                    throw HDF5FileError.cannotOpen("not a regular file")
                }
            }
            switch mode {
            case .inPlace: try appendInPlace(url, existing: identity != nil, h5, body)
            case .atomicCopy: try appendAtomically(url, checked: identity, h5, body)
            }
        }
    }

    private static func appendInPlace(_ url: URL, existing: Bool, _ h5: SharedHDF5,
                                      _ body: (HDF5WriteSession) throws -> Void) throws {
        let file: hid_t
        if existing {
            file = url.path.withCString { h5.h5fopen($0, 0x0001, 0) }              // H5F_ACC_RDWR
            guard file >= 0 else { throw HDF5FileError.cannotOpen(HDF5RootAttributes.errorStack(h5) ?? "HDF5 gave no reason") }
        } else {
            file = url.path.withCString { h5.h5fcreate($0, 0x0004, 0, 0) }          // H5F_ACC_EXCL
            guard file >= 0 else { throw HDF5RootAttributes.failure("creating the file", h5) }
        }
        do { try run(file, h5, body) } catch {
            if !existing { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func appendAtomically(_ url: URL, checked: HDF5FileIdentity?, _ h5: SharedHDF5,
                                         _ body: (HDF5WriteSession) throws -> Void) throws {
        let (scratch, scratchDirectory) = HDF5RootAttributes.temporaryURL(for: url, namePrefix: ".formato-append-")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        }
        let file: hid_t
        if checked != nil {
            // Data, permissions and attributes; a clone on APFS, so a large file costs no copy.
            let status = copyfile(url.path, scratch.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE))
            guard status == 0 else {
                throw HDF5FileError.cannotWrite(operation: "copying the file", detail: String(cString: strerror(errno)))
            }
            file = scratch.path.withCString { h5.h5fopen($0, 0x0001, 0) }
            guard file >= 0 else { throw HDF5FileError.cannotOpen(HDF5RootAttributes.errorStack(h5) ?? "HDF5 gave no reason") }
        } else {
            file = scratch.path.withCString { h5.h5fcreate($0, 0x0002, 0, 0) }      // H5F_ACC_TRUNC
            guard file >= 0 else { throw HDF5RootAttributes.failure("creating the file", h5) }
        }
        try run(file, h5, body)
        let descriptor = scratch.path.withCString { Darwin.open($0, O_RDONLY) }
        if descriptor >= 0 { _ = fcntl(descriptor, F_FULLFSYNC); _ = Darwin.close(descriptor) }
        try HDF5RootAttributes.publish(scratch, onto: url, replacing: checked)
    }

    /// Runs the body on `file` and closes it, the close checked. The file is closed on every path.
    private static func run(_ file: hid_t, _ h5: SharedHDF5, _ body: (HDF5WriteSession) throws -> Void) throws {
        let session = HDF5WriteSession(h5: h5, file: file)
        do { try body(session) } catch {
            session.invalidate()
            _ = h5.h5fclose(file)
            throw error
        }
        session.invalidate()
        guard h5.h5fclose(file) >= 0 else { throw HDF5RootAttributes.failure("closing the file", h5) }
    }
}

/// The open file of one `HDF5AppendWriter.append` call. Valid only inside the call's body (a later use throws); not
/// `Sendable`, and every method runs under `HDF5Serial`.
public nonisolated final class HDF5WriteSession {
    private let h5: SharedHDF5
    private var file: hid_t

    fileprivate init(h5: SharedHDF5, file: hid_t) { self.h5 = h5; self.file = file }
    fileprivate func invalidate() { file = -1 }

    private func open<T>(_ body: (hid_t) throws -> T) throws -> T {
        try HDF5Serial.run {
            guard file >= 0 else { throw HDF5FileError.invalidArgument("the write session is closed") }
            return try body(file)
        }
    }

    /// Whether a link exists at `path` (every component must exist).
    public func exists(_ path: String) throws -> Bool {
        let parts = try HDF5Ops.components(path)
        return try open { HDF5Ops.linkExists(h5, $0, parts) }
    }

    /// Creates the group at `path` and any missing groups above it. An existing group is fine; an existing dataset or other
    /// object anywhere along the path throws `wrongKind`.
    public func createGroup(_ path: String) throws {
        let parts = try HDF5Ops.components(path)
        try open { try makeGroups(parts, $0, path) }
    }

    /// Writes `array` as a new dataset at `path` (missing groups above it are created), stored in the array's own type and
    /// byte values (little-endian). Only the integer and float types are written; the colour types throw `invalidArgument`.
    /// - Parameters:
    ///   - chunk: a chunked layout with this chunk shape (one extent per dimension, each from 1 to the dataset's extent), or
    ///     contiguous when nil.
    ///   - replace: when false (default) an existing link at `path` throws `alreadyExists`. When true an existing dataset is
    ///     unlinked first (its space stays in the file); an existing group is never replaced (`alreadyExists`: use `deleteLink`).
    ///     Everything that can fail is checked before the old dataset is unlinked.
    public func writeDataset(_ path: String, _ array: FormatoArray, chunk: [Int]? = nil, replace: Bool = false) throws {
        try makeDataset(path, dataType: array.dataType, shape: array.shape, chunk: chunk, replace: replace, bytes: array.bytes)
    }

    /// Creates a dataset of `dataType` and `shape` at `path` with no data written (HDF5 allocates a chunked dataset lazily, so
    /// a very large one costs nothing until `writeSlab` fills it; unwritten elements read back as zero). The same rules as
    /// `writeDataset` for missing groups, `chunk` and `replace`. For a file built a tile at a time.
    public func createDataset(_ path: String, dataType: FormatoDataType, shape: [Int], chunk: [Int]? = nil,
                              replace: Bool = false) throws {
        try makeDataset(path, dataType: dataType, shape: shape, chunk: chunk, replace: replace, bytes: nil)
    }

    private func makeDataset(_ path: String, dataType: FormatoDataType, shape: [Int], chunk: [Int]?, replace: Bool,
                             bytes: Data?) throws {
        let parts = try HDF5Ops.components(path)
        guard !parts.isEmpty else { throw HDF5FileError.invalidPath(path) }
        guard let nativeType = HDF5Ops.native(h5, dataType) else {
            throw HDF5FileError.invalidArgument("the \(dataType.rawValue) type cannot be written")
        }
        guard shape.allSatisfy({ $0 >= 0 }) else { throw HDF5FileError.invalidArgument("shape \(shape) is negative") }
        if let chunk {
            guard !shape.isEmpty, chunk.count == shape.count,
                  zip(chunk, shape).allSatisfy({ $0 >= 1 && $0 <= $1 }) else {
                throw HDF5FileError.invalidArgument("chunk \(chunk) does not fit shape \(shape)")
            }
            var chunkBytes = dataType.byteSize
            for extent in chunk {
                let (product, overflow) = chunkBytes.multipliedReportingOverflow(by: extent)
                guard !overflow, product < (1 << 32) else { throw HDF5FileError.invalidArgument("chunk \(chunk) is over 4 GiB") }
                chunkBytes = product
            }
        }
        guard shape.count <= HDF5Ops.maximumRank else { throw HDF5FileError.limitExceeded("rank \(shape.count)") }
        try open { file in
            try checkParents(Array(parts.dropLast()), file, path)
            if HDF5Ops.linkExists(h5, file, parts) {
                guard replace else { throw HDF5FileError.alreadyExists(path) }
                guard HDF5Ops.kind(h5, file, parts) != .group else { throw HDF5FileError.alreadyExists("\(path) (a group; use deleteLink)") }
                guard HDF5Ops.absolute(parts).withCString({ h5.h5ldelete(file, $0, 0) }) >= 0 else {
                    throw HDF5RootAttributes.failure("unlinking \(path)", h5)
                }
            }
            try makeGroups(Array(parts.dropLast()), file, path)
            let dims = shape.map(UInt64.init)
            let space = dims.isEmpty ? h5.h5screate(0) : h5.h5screateSimple(Int32(dims.count), dims, nil)
            guard space >= 0 else { throw HDF5RootAttributes.failure("making the space of \(path)", h5) }
            defer { _ = h5.h5sclose(space) }
            var properties: hid_t = 0
            if let chunk {
                properties = h5.h5pcreate(h5.datasetCreateClass)
                guard properties >= 0 else { throw HDF5RootAttributes.failure("making the dataset properties of \(path)", h5) }
                guard h5.h5psetChunk(properties, Int32(chunk.count), chunk.map(UInt64.init)) >= 0 else {
                    _ = h5.h5pclose(properties)
                    throw HDF5RootAttributes.failure("setting the chunk shape of \(path)", h5)
                }
            }
            defer { if properties > 0 { _ = h5.h5pclose(properties) } }
            let dataset = HDF5Ops.absolute(parts).withCString { h5.h5dcreate2(file, $0, nativeType, space, 0, properties, 0) }
            guard dataset >= 0 else { throw HDF5RootAttributes.failure("creating \(path)", h5) }
            defer { _ = h5.h5dclose(dataset) }
            if let bytes, !bytes.isEmpty {
                guard bytes.withUnsafeBytes({ h5.h5dwrite(dataset, nativeType, 0, 0, 0, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.failure("writing \(path)", h5)
                }
            }
        }
    }

    /// Writes `array` into the existing numeric dataset at `path`, with its first element at `start` (one index per dimension;
    /// the array has the dataset's rank and its elements' type). `invalidArgument` when the type differs from the dataset's
    /// stored type or the slab leaves the dataset; `notFound` / `wrongKind` for a missing or non-dataset path. For a dataset
    /// built by `createDataset` a tile at a time.
    public func writeSlab(_ path: String, start: [Int], _ array: FormatoArray) throws {
        let parts = try HDF5Ops.components(path)
        guard let nativeType = HDF5Ops.native(h5, array.dataType) else {
            throw HDF5FileError.invalidArgument("the \(array.dataType.rawValue) type cannot be written")
        }
        try open { file in
            try HDF5Ops.withDataset(h5, file, path, parts) { dataset in
                let found = try HDF5Ops.info(h5, dataset, path)
                guard case .numeric(let stored) = found.type, stored == array.dataType else {
                    throw HDF5FileError.invalidArgument("\(path) does not store \(array.dataType.rawValue): \(found.type)")
                }
                guard start.count == found.shape.count, array.shape.count == found.shape.count else {
                    throw HDF5FileError.invalidArgument("rank \(array.shape.count) at \(start) into \(path) of shape \(found.shape)")
                }
                do { try FormatoArray.checkSlab(start: start, count: array.shape, shape: found.shape) } catch {
                    throw HDF5FileError.invalidArgument("slab \(start) of \(array.shape) is outside \(path) of shape \(found.shape)")
                }
                guard !array.bytes.isEmpty else { return }
                if found.shape.isEmpty {
                    guard array.bytes.withUnsafeBytes({ h5.h5dwrite(dataset, nativeType, 0, 0, 0, $0.baseAddress) }) >= 0 else {
                        throw HDF5RootAttributes.failure("writing \(path)", h5)
                    }
                    return
                }
                let fileSpace = h5.h5dgetSpace(dataset)
                guard fileSpace >= 0 else { throw HDF5RootAttributes.failure("opening the space of \(path)", h5) }
                defer { _ = h5.h5sclose(fileSpace) }
                let starts = start.map(UInt64.init), counts = array.shape.map(UInt64.init)
                guard h5.h5sselectHyperslab(fileSpace, 0, starts, nil, counts, nil) >= 0 else {      // H5S_SELECT_SET
                    throw HDF5RootAttributes.failure("selecting the slab of \(path)", h5)
                }
                let memorySpace = h5.h5screateSimple(Int32(counts.count), counts, nil)
                guard memorySpace >= 0 else { throw HDF5RootAttributes.failure("making the memory space for \(path)", h5) }
                defer { _ = h5.h5sclose(memorySpace) }
                guard array.bytes.withUnsafeBytes({ h5.h5dwrite(dataset, nativeType, memorySpace, fileSpace, 0, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.failure("writing the slab of \(path)", h5)
                }
            }
        }
    }

    /// Writes a scalar text dataset at `path` (missing groups above it are created), stored as variable-length text, the way
    /// h5py writes a Python `str` and the way py4DSTEM's metadata strings are stored. `utf8: false` stores it as ASCII (the
    /// text must then be ASCII). A NUL byte throws `embeddedNUL`. `replace` as in `writeDataset`.
    public func writeText(_ path: String, _ text: String, utf8: Bool = true, replace: Bool = false) throws {
        let parts = try HDF5Ops.components(path)
        guard !parts.isEmpty else { throw HDF5FileError.invalidPath(path) }
        guard !text.utf8.contains(0) else { throw HDF5FileError.embeddedNUL(path) }
        guard utf8 || text.utf8.allSatisfy({ $0 < 0x80 }) else { throw HDF5FileError.invalidArgument("\(path) is not ASCII") }
        try open { file in
            try prepareScalar(parts, file, path, replace: replace)
            let type = try variableLengthTextType(utf8: utf8, for: path)
            defer { _ = h5.h5tclose(type) }
            try createScalar(parts, file, path, type: type) { dataset in
                text.withCString { characters -> herr_t in
                    var pointer: UnsafePointer<CChar>? = characters
                    return withUnsafePointer(to: &pointer) { h5.h5dwrite(dataset, type, 0, 0, 0, $0) }
                }
            }
        }
    }

    /// Writes a scalar boolean dataset at `path` as h5py stores a NumPy `bool`: an 8-bit enumeration {FALSE = 0, TRUE = 1}.
    public func writeBool(_ path: String, _ value: Bool, replace: Bool = false) throws {
        let parts = try HDF5Ops.components(path)
        guard !parts.isEmpty else { throw HDF5FileError.invalidPath(path) }
        try open { file in
            try prepareScalar(parts, file, path, replace: replace)
            let type = h5.h5tenumCreate(h5.int8)
            guard type >= 0 else { throw HDF5RootAttributes.failure("making the bool type of \(path)", h5) }
            defer { _ = h5.h5tclose(type) }
            var no: Int8 = 0, yes: Int8 = 1
            guard "FALSE".withCString({ h5.h5tenumInsert(type, $0, &no) }) >= 0,
                  "TRUE".withCString({ h5.h5tenumInsert(type, $0, &yes) }) >= 0 else {
                throw HDF5RootAttributes.failure("defining the bool type of \(path)", h5)
            }
            var stored: Int8 = value ? 1 : 0
            try createScalar(parts, file, path, type: type) { dataset in
                withUnsafePointer(to: &stored) { h5.h5dwrite(dataset, type, 0, 0, 0, $0) }
            }
        }
    }

    /// Sets the attribute `name` on the object at `path` (a group or dataset; the root is "/"), replacing an existing one.
    /// Text is stored as fixed-length UTF-8, null padded, exactly as long as its UTF-8 bytes (an array of texts as long as the
    /// longest; an empty text is one NUL); integers as int64 and reals as float64, scalar or one-dimensional as the value says.
    /// A text with a NUL byte throws `embeddedNUL`. The old attribute is deleted before the new one is created.
    public func setAttribute(_ name: String, on path: String, _ value: HDF5AttributeValue) throws {
        let parts = try HDF5Ops.components(path)
        guard !name.isEmpty, !name.utf8.contains(0) else { throw HDF5FileError.invalidPath(name) }
        let texts: [String]
        switch value {
        case .text(let text): texts = [text]
        case .texts(let all): texts = all
        default: texts = []
        }
        for text in texts where text.utf8.contains(0) { throw HDF5FileError.embeddedNUL(name) }
        try open { file in
            try HDF5Ops.withObject(h5, file, path, parts) { object in
                let exists = name.withCString { h5.h5aexists(object, $0) }
                guard exists >= 0 else { throw HDF5RootAttributes.failure("looking for the \(name) attribute", h5) }
                if exists > 0 {
                    guard name.withCString({ h5.h5adelete(object, $0) }) >= 0 else {
                        throw HDF5RootAttributes.failure("replacing the \(name) attribute", h5)
                    }
                }
                switch value {
                case .text(let text): try HDF5RootAttributes.writeString(name, text, on: object, h5)
                case .texts(let all): try writeStrings(name, all, on: object)
                case .integer(let v): try writeNumbers(name, [v], scalar: true, type: h5.int64, on: object)
                case .integers(let v): try writeNumbers(name, v, scalar: false, type: h5.int64, on: object)
                case .real(let v): try writeNumbers(name, [v], scalar: true, type: h5.float64, on: object)
                case .reals(let v): try writeNumbers(name, v, scalar: false, type: h5.float64, on: object)
                }
            }
        }
    }

    /// Sets the text attribute `name` on the object at `path` as variable-length text (UTF-8), the way h5py writes a Python
    /// `str` attribute and py4DSTEM / emdfile's group attributes are stored; `setAttribute(_:on:_:)` stores fixed-length text.
    /// Replaces an existing attribute (deleted first). A NUL byte throws `embeddedNUL`.
    public func setVariableLengthTextAttribute(_ name: String, on path: String, _ text: String) throws {
        let parts = try HDF5Ops.components(path)
        guard !name.isEmpty, !name.utf8.contains(0) else { throw HDF5FileError.invalidPath(name) }
        guard !text.utf8.contains(0) else { throw HDF5FileError.embeddedNUL(name) }
        try open { file in
            try HDF5Ops.withObject(h5, file, path, parts) { object in
                let exists = name.withCString { h5.h5aexists(object, $0) }
                guard exists >= 0 else { throw HDF5RootAttributes.failure("looking for the \(name) attribute", h5) }
                if exists > 0, name.withCString({ h5.h5adelete(object, $0) }) < 0 {
                    throw HDF5RootAttributes.failure("replacing the \(name) attribute", h5)
                }
                let type = try variableLengthTextType(utf8: true, for: name)
                defer { _ = h5.h5tclose(type) }
                try store(name, type: type, count: 1, scalar: true, on: object) { attribute in
                    text.withCString { characters -> herr_t in
                        var pointer: UnsafePointer<CChar>? = characters
                        return withUnsafePointer(to: &pointer) { h5.h5awrite(attribute, type, $0) }
                    }
                }
            }
        }
    }

    /// Removes the link at `path` (a group's whole subtree, or a dataset); `notFound` when there is none. The root cannot be removed.
    public func deleteLink(_ path: String) throws {
        let parts = try HDF5Ops.components(path)
        guard !parts.isEmpty else { throw HDF5FileError.invalidPath(path) }
        try open { file in
            guard HDF5Ops.linkExists(h5, file, parts) else { throw HDF5FileError.notFound(path) }
            guard HDF5Ops.absolute(parts).withCString({ h5.h5ldelete(file, $0, 0) }) >= 0 else {
                throw HDF5RootAttributes.failure("unlinking \(path)", h5)
            }
        }
    }

    // MARK: Internals (all under open)

    /// Throws `wrongKind` when a component of `parts` that exists is not a group.
    private func checkParents(_ parts: [String], _ file: hid_t, _ path: String) throws {
        guard !parts.isEmpty else { return }
        for count in 1...parts.count {
            let prefix = Array(parts.prefix(count))
            guard HDF5Ops.linkExists(h5, file, prefix) else { return }
            guard HDF5Ops.kind(h5, file, prefix) == .group else {
                throw HDF5FileError.wrongKind(path: HDF5Ops.absolute(prefix), expected: "group")
            }
        }
    }

    private func makeGroups(_ parts: [String], _ file: hid_t, _ path: String) throws {
        guard !parts.isEmpty else { return }
        try checkParents(parts, file, path)
        for count in 1...parts.count {
            let prefix = Array(parts.prefix(count))
            if HDF5Ops.linkExists(h5, file, prefix) { continue }
            let group = HDF5Ops.absolute(prefix).withCString { h5.h5gcreate2(file, $0, 0, 0, 0) }
            guard group >= 0 else { throw HDF5RootAttributes.failure("creating the group \(HDF5Ops.absolute(prefix))", h5) }
            _ = h5.h5oclose(group)
        }
    }

    private func variableLengthTextType(utf8: Bool, for name: String) throws -> hid_t {
        let type = h5.h5tcopy(h5.stringC1)
        guard type >= 0 else { throw HDF5RootAttributes.failure("making the text type for \(name)", h5) }
        // H5T_VARIABLE is (size_t)-1; H5T_CSET_UTF8 = 1, H5T_CSET_ASCII = 0.
        guard h5.h5tsetSize(type, -1) >= 0, h5.h5tsetCset(type, utf8 ? 1 : 0) >= 0 else {
            _ = h5.h5tclose(type)
            throw HDF5RootAttributes.failure("making the variable-length text type for \(name)", h5)
        }
        return type
    }

    /// The checks and unlinking shared by the scalar dataset writers (all under `open`).
    private func prepareScalar(_ parts: [String], _ file: hid_t, _ path: String, replace: Bool) throws {
        try checkParents(Array(parts.dropLast()), file, path)
        if HDF5Ops.linkExists(h5, file, parts) {
            guard replace else { throw HDF5FileError.alreadyExists(path) }
            guard HDF5Ops.kind(h5, file, parts) != .group else { throw HDF5FileError.alreadyExists("\(path) (a group; use deleteLink)") }
            guard HDF5Ops.absolute(parts).withCString({ h5.h5ldelete(file, $0, 0) }) >= 0 else {
                throw HDF5RootAttributes.failure("unlinking \(path)", h5)
            }
        }
        try makeGroups(Array(parts.dropLast()), file, path)
    }

    private func createScalar(_ parts: [String], _ file: hid_t, _ path: String, type: hid_t,
                              write: (hid_t) -> herr_t) throws {
        let space = h5.h5screate(0)
        guard space >= 0 else { throw HDF5RootAttributes.failure("making the space of \(path)", h5) }
        defer { _ = h5.h5sclose(space) }
        let dataset = HDF5Ops.absolute(parts).withCString { h5.h5dcreate2(file, $0, type, space, 0, 0, 0) }
        guard dataset >= 0 else { throw HDF5RootAttributes.failure("creating \(path)", h5) }
        defer { _ = h5.h5dclose(dataset) }
        guard write(dataset) >= 0 else { throw HDF5RootAttributes.failure("writing \(path)", h5) }
    }

    private func writeStrings(_ name: String, _ texts: [String], on object: hid_t) throws {
        let size = max(1, texts.map { $0.utf8.count }.max() ?? 1)
        var storage = [UInt8](repeating: 0, count: size * texts.count)
        for (i, text) in texts.enumerated() { storage.replaceSubrange((i * size)..<(i * size + text.utf8.count), with: Array(text.utf8)) }
        let type = h5.h5tcopy(h5.stringC1)
        guard type >= 0 else { throw HDF5RootAttributes.failure("making the text type for \(name)", h5) }
        defer { _ = h5.h5tclose(type) }
        guard h5.h5tsetSize(type, size) >= 0, h5.h5tsetCset(type, 1) >= 0, h5.h5tsetStrpad(type, 1) >= 0 else {
            throw HDF5RootAttributes.failure("making the UTF-8 text type for \(name)", h5)
        }
        try store(name, type: type, count: texts.count, scalar: false, on: object) { h5.h5awrite($0, type, storage) }
    }

    private func writeNumbers<T: BitwiseCopyable>(_ name: String, _ values: [T], scalar: Bool, type: hid_t, on object: hid_t) throws {
        try store(name, type: type, count: values.count, scalar: scalar, on: object) { attribute in values.withUnsafeBytes { h5.h5awrite(attribute, type, $0.baseAddress) } }
    }

    private func store(_ name: String, type: hid_t, count: Int, scalar: Bool, on object: hid_t,
                       write: (hid_t) -> herr_t) throws {
        let dims = [UInt64(count)]
        let space = scalar ? h5.h5screate(0) : h5.h5screateSimple(1, dims, nil)
        guard space >= 0 else { throw HDF5RootAttributes.failure("making the space for \(name)", h5) }
        defer { _ = h5.h5sclose(space) }
        let attribute = name.withCString { h5.h5acreate2(object, $0, type, space, 0, 0) }
        guard attribute >= 0 else { throw HDF5RootAttributes.failure("creating the \(name) attribute", h5) }
        defer { _ = h5.h5aclose(attribute) }
        if count > 0 {
            guard write(attribute) >= 0 else { throw HDF5RootAttributes.failure("writing the \(name) attribute", h5) }
        }
    }
}
