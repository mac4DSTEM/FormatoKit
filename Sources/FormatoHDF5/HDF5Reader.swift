//
//  HDF5Reader.swift
//  Role: low-level, format-agnostic read access to any HDF5 file through the one shared loader (`SharedHDF5`, under
//        `HDF5Serial`): which objects exist, their kind, group children, attribute names and values, dataset shape and
//        stored type, hyperslab reads as `FormatoArray`, and string datasets. What a given file's layout MEANS (EMD, hspy,
//        a session file) belongs to the caller; this is the access layer the format modules and consumers share with the
//        append writer (`HDF5AppendWriter`).
//
//  Every call opens the file, does its one operation under `HDF5Serial` and closes it: no HDF5 handle ever leaves a call, and
//  none is held across an `await`. Missing things and unsupported types throw `HDF5FileError`; sizes are bounded (rank at most
//  32, element counts checked for overflow, a byte cap per read, a cap per string).
//

import Foundation
import Darwin
import FormatoCore

/// What an HDF5 object is.
public nonisolated enum HDF5ObjectKind: Sendable, Equatable {
    case group, dataset
    /// A named datatype, or anything else HDF5 can link to.
    case other
}

/// The stored element type of a dataset, as far as this layer reads it.
public nonisolated enum HDF5DatasetType: Sendable, Equatable {
    /// An integer or floating-point type FormatoCore holds; `readDataset` returns it as stored (any byte order, as little-endian).
    case numeric(FormatoDataType)
    /// A string type: fixed-length or variable-length; `readStrings` reads it.
    case string(variableLength: Bool)
    /// Any other type, by name: `compound`, `enum` (h5py's bool), `array`, `vlen`, `reference`, `opaque`, `bitfield`, `time`, or
    /// a size FormatoCore has no type for (`float16`, `int128`).
    case unsupported(String)
}

/// A dataset's shape (C order, slowest first; `[]` for a scalar) and stored type.
public nonisolated struct HDF5DatasetInfo: Sendable, Equatable {
    public let shape: [Int]
    public let type: HDF5DatasetType
    public init(shape: [Int], type: HDF5DatasetType) { self.shape = shape; self.type = type }
}

/// An attribute value: a scalar or a one-dimensional array of text, integers or reals. Text is UTF-8 (fixed-length or
/// variable-length when read; fixed-length, null padded, when written).
public nonisolated enum HDF5AttributeValue: Sendable, Equatable {
    case text(String)
    case texts([String])
    case integer(Int64)
    case integers([Int64])
    case real(Double)
    case reals([Double])
}

public nonisolated struct HDF5Reader: Sendable {
    /// The file this reader opens for every call.
    public let url: URL
    /// The default cap on the bytes one `readDataset` or `readStrings` returns: 4 GiB.
    public static let defaultMaximumBytes = 4 << 30
    /// The default cap on one string: 4 MiB.
    public static let defaultMaximumStringBytes = 4 << 20

    /// Opens `url` once to check that it is a readable HDF5 file; throws `cannotOpen` (not HDF5, missing), `notPermitted`
    /// or `library` otherwise. The file is closed again: each call below opens it for itself.
    public init(url: URL) throws {
        self.url = url
        try withFile { _, _ in }
    }

    /// Whether a link exists at `path` (every component must exist).
    public func exists(_ path: String) throws -> Bool {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in HDF5Ops.linkExists(h5, file, parts) }
    }

    /// The kind of the object at `path`; `notFound` when there is none (a dangling soft link is `other`).
    public func kind(of path: String) throws -> HDF5ObjectKind {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in
            guard HDF5Ops.linkExists(h5, file, parts) else { throw HDF5FileError.notFound(path) }
            return HDF5Ops.kind(h5, file, parts)
        }
    }

    /// The link names in the group at `path`, sorted by their UTF-8 bytes (h5py's order).
    public func children(of path: String) throws -> [String] {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withObject(h5, file, path, parts) { obj in
            guard HDF5Ops.kindOf(h5, obj) == .group else { throw HDF5FileError.wrongKind(path: path, expected: "group") }
            return try HDF5Ops.children(h5, obj, path)
        } }
    }

    /// The attribute names on the object at `path` (the root is "/"), sorted by their UTF-8 bytes.
    public func attributeNames(of path: String) throws -> [String] {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withObject(h5, file, path, parts) { obj in
            try HDF5Ops.attributeNames(h5, obj, path)
        } }
    }

    /// The attribute `name` on the object at `path`; `notFound` when absent. Scalars and one-dimensional arrays of text,
    /// integers and reals; anything else throws `unsupportedType`. An unsigned 64-bit value over `Int64.max` throws
    /// `limitExceeded` rather than wrapping.
    public func attribute(_ name: String, of path: String) throws -> HDF5AttributeValue {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withObject(h5, file, path, parts) { obj in
            try HDF5Ops.readAttribute(h5, obj, name, path, maximumStringBytes: Self.defaultMaximumStringBytes)
        } }
    }

    /// The shape and stored type of the dataset at `path`.
    public func datasetInfo(_ path: String) throws -> HDF5DatasetInfo {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withDataset(h5, file, path, parts) { ds in
            try HDF5Ops.info(h5, ds, path)
        } }
    }

    /// A rectangular hyperslab of a numeric dataset, as stored (a float16 dataset is returned as float32 although `datasetInfo` reports `unsupported("float16")`) (C order, little-endian bytes; the element type is the stored one).
    /// `start` and `count` default to the whole dataset; both must have the dataset's rank. A zero count returns an empty array.
    public func readDataset(_ path: String, start: [Int]? = nil, count: [Int]? = nil,
                            maximumBytes: Int = defaultMaximumBytes) throws -> FormatoArray {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withDataset(h5, file, path, parts) { ds in
            try HDF5Ops.readNumeric(h5, ds, path, start: start, count: count, maximumBytes: maximumBytes)
        } }
    }

    /// Every string of a string dataset (fixed-length or variable-length), flattened in C order. A fixed-length string ends at
    /// its first NUL. Invalid UTF-8 throws `invalidUTF8`; a string over `maximumStringBytes` throws `stringTooLong`.
    public func readStrings(_ path: String, maximumStringBytes: Int = defaultMaximumStringBytes,
                            maximumBytes: Int = defaultMaximumBytes) throws -> [String] {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withDataset(h5, file, path, parts) { ds in
            try HDF5Ops.readStrings(h5, ds, path, maximumStringBytes: maximumStringBytes, maximumBytes: maximumBytes)
        } }
    }

    /// The chunk shape of the dataset at `path`, or nil when it is stored contiguously or compactly (not chunked).
    public func chunkShape(of path: String) throws -> [Int]? {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withDataset(h5, file, path, parts) { ds in
            try HDF5Ops.chunkShape(h5, ds, path)
        } }
    }

    /// Every object below the group at `path`, depth first, each group before its members, as absolute paths with their kind
    /// (links are followed: a soft link to a group is walked). Siblings are in `children(of:)` order. More than
    /// `maximumObjects` objects or a depth over 64 (a link cycle) throws `limitExceeded`.
    public func descendants(of path: String = "/", maximumObjects: Int = 1 << 16) throws -> [(path: String, kind: HDF5ObjectKind)] {
        var out: [(path: String, kind: HDF5ObjectKind)] = []
        func walk(_ group: String, depth: Int) throws {
            guard depth <= 64 else { throw HDF5FileError.limitExceeded("links nest deeper than 64 below \(path)") }
            for name in try children(of: group) {
                let child = group == "/" ? "/" + name : group + "/" + name
                guard out.count < maximumObjects else { throw HDF5FileError.limitExceeded("more than \(maximumObjects) objects below \(path)") }
                let kind = try self.kind(of: child)
                out.append((child, kind))
                if kind == .group { try walk(child, depth: depth + 1) }
            }
        }
        guard try kind(of: path) == .group else { throw HDF5FileError.wrongKind(path: path, expected: "group") }
        try walk(path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path, depth: 0)
        return out
    }

    /// How a link is stored.
    public enum LinkKind: Sendable, Equatable { case hard, soft, external }

    /// One object found by `walk`.
    public struct WalkEntry: Sendable, Equatable {
        public let path: String
        public let kind: HDF5ObjectKind
        public let link: LinkKind
        /// The object's identity in the file (file number and token, from `H5Oget_info_by_name3`): two hard links to one
        /// object carry the same value. Nil for soft and external links, and when the library cannot say.
        public let identity: Data?
    }

    /// Every link below the group at `path` (the root is "/"), depth first, parents before members, siblings in `children(of:)`
    /// order, with each link's kind and the object identity. Unlike `descendants`, a group reached by a second hard link (an
    /// alias, or a cycle back to an ancestor) is listed but not entered again, and a soft or external link is listed but not
    /// followed, so neither lists a subtree twice nor loops. More than `maximumObjects` entries or a depth over 64 throws
    /// `limitExceeded`. One file open, one lock hold.
    public func walk(from path: String = "/", maximumObjects: Int = 1 << 17) throws -> [WalkEntry] {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in
            var out: [WalkEntry] = []
            var entered = Set<Data>()
            func visit(_ groupParts: [String], depth: Int) throws {
                guard depth <= 64 else { throw HDF5FileError.limitExceeded("links nest deeper than 64 below \(path)") }
                let groupPath = HDF5Ops.absolute(groupParts)
                let names = try HDF5Ops.withObject(h5, file, groupPath, groupParts) { obj in
                    try HDF5Ops.children(h5, obj, groupPath)
                }
                for name in names {
                    guard out.count < maximumObjects else { throw HDF5FileError.limitExceeded("more than \(maximumObjects) objects below \(path)") }
                    let childParts = groupParts + [name]
                    let childPath = HDF5Ops.absolute(childParts)
                    let (link, identity) = HDF5Ops.linkInfo(h5, file, childPath)
                    let kind = HDF5Ops.kind(h5, file, childParts)
                    out.append(WalkEntry(path: childPath, kind: kind, link: link, identity: identity))
                    guard kind == .group, link == .hard else { continue }
                    if let identity, !entered.insert(identity).inserted { continue }
                    try visit(childParts, depth: depth + 1)
                }
            }
            guard HDF5Ops.linkExists(h5, file, parts) else { throw HDF5FileError.notFound(path) }
            guard HDF5Ops.kind(h5, file, parts) == .group else { throw HDF5FileError.wrongKind(path: path, expected: "group") }
            if let identity = HDF5Ops.linkInfo(h5, file, HDF5Ops.absolute(parts)).1 { entered.insert(identity) }
            try visit(parts, depth: 0)
            return out
        }
    }

    /// The values of an enum dataset whose base type is a one-byte integer (h5py's `bool`: FALSE = 0, TRUE = 1), flattened in C
    /// order, true where the stored value is not 0. Any other type throws `unsupportedType`.
    public func readBooleans(_ path: String, maximumBytes: Int = defaultMaximumBytes) throws -> [Bool] {
        let parts = try HDF5Ops.components(path)
        return try withFile { h5, file in try HDF5Ops.withDataset(h5, file, path, parts) { ds in
            try HDF5Ops.readBooleans(h5, ds, path, maximumBytes: maximumBytes)
        } }
    }

    private func withFile<T>(_ body: (SharedHDF5, hid_t) throws -> T) throws -> T {
        try HDF5RootAttributes.withLibrary { h5 in
            let file = try HDF5RootAttributes.openForReading(url, h5)
            defer { _ = h5.h5fclose(file) }
            return try body(h5, file)
        }
    }
}

// MARK: - Shared operations (reader and write session). Every caller holds HDF5Serial and an open file.

nonisolated enum HDF5Ops {
    static let maximumRank = 32
    static let maximumAttributeElements = 1 << 24
    static let maximumLinks = 1 << 22

    static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw HDF5FileError.invalidPath(path) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw HDF5FileError.invalidPath(path) }
        return parts
    }

    static func absolute(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }

    /// Whether every link along `parts` exists (the root always does).
    static func linkExists(_ h5: SharedHDF5, _ file: hid_t, _ parts: [String]) -> Bool {
        var prefix = ""
        for part in parts {
            prefix += "/" + part
            guard prefix.withCString({ h5.h5lexists(file, $0, 0) }) > 0 else { return false }
        }
        return true
    }

    static func kindOf(_ h5: SharedHDF5, _ object: hid_t) -> HDF5ObjectKind {
        switch h5.h5igetType(object) {
        case 2: .group
        case 5: .dataset
        default: .other
        }
    }

    /// The kind of the object at `parts` (`other` when it cannot be opened).
    static func kind(_ h5: SharedHDF5, _ file: hid_t, _ parts: [String]) -> HDF5ObjectKind {
        let id = absolute(parts).withCString { h5.h5oopen(file, $0, 0) }
        guard id >= 0 else { return .other }
        defer { _ = h5.h5oclose(id) }
        return kindOf(h5, id)
    }

    static func withObject<T>(_ h5: SharedHDF5, _ file: hid_t, _ path: String, _ parts: [String],
                              _ body: (hid_t) throws -> T) throws -> T {
        guard linkExists(h5, file, parts) else { throw HDF5FileError.notFound(path) }
        let id = absolute(parts).withCString { h5.h5oopen(file, $0, 0) }
        guard id >= 0 else { throw HDF5FileError.notFound(path) }
        defer { _ = h5.h5oclose(id) }
        return try body(id)
    }

    static func withDataset<T>(_ h5: SharedHDF5, _ file: hid_t, _ path: String, _ parts: [String],
                               _ body: (hid_t) throws -> T) throws -> T {
        try withObject(h5, file, path, parts) { obj in
            guard kindOf(h5, obj) == .dataset else { throw HDF5FileError.wrongKind(path: path, expected: "dataset") }
            return try body(obj)
        }
    }

    /// The link type of `path` (`H5Lget_info2`: the first field is `H5L_type_t`, 0 hard, 1 soft, 64 external) and, for a hard
    /// link, the object identity (`H5Oget_info_by_name3` with `H5O_INFO_BASIC`: the file number and token are the first 24 bytes).
    static func linkInfo(_ h5: SharedHDF5, _ file: hid_t, _ path: String) -> (HDF5Reader.LinkKind, Data?) {
        guard let linkGet = h5.h5lgetInfo2 else { return (.hard, nil) }
        var link = [UInt8](repeating: 0, count: 256)
        guard path.withCString({ name in link.withUnsafeMutableBytes { linkGet(file, name, $0.baseAddress, 0) } }) >= 0 else { return (.hard, nil) }
        switch link.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) {
        case 0: break
        case 1: return (.soft, nil)
        default: return (.external, nil)
        }
        guard let objectGet = h5.h5ogetInfoByName3 else { return (.hard, nil) }
        var object = [UInt8](repeating: 0, count: 256)
        let got = path.withCString { name in object.withUnsafeMutableBytes { objectGet(file, name, $0.baseAddress, 1, 0) } }
        return (.hard, got >= 0 ? Data(object[0..<24]) : nil)
    }

    // MARK: Listing

    private final class Names { var values: [String] = []; var overflow = false }

    static func sorted(_ names: [String]) -> [String] { names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }

    static func children(_ h5: SharedHDF5, _ group: hid_t, _ path: String) throws -> [String] {
        let box = Names()
        let callback: SharedHDF5.H5Literate = { _, name, _, data in
            guard let name, let data else { return -1 }
            let box = Unmanaged<Names>.fromOpaque(data).takeUnretainedValue()
            if box.values.count >= HDF5Ops.maximumLinks { box.overflow = true; return 1 }
            box.values.append(String(cString: name))
            return 0
        }
        let status = withExtendedLifetime(box) { h5.h5literate2(group, 0, 1, nil, callback, Unmanaged.passUnretained(box).toOpaque()) }
        guard status >= 0 else { throw HDF5RootAttributes.hdf5Failure("listing the links of \(path)", h5) }
        guard !box.overflow else { throw HDF5FileError.limitExceeded("more than \(maximumLinks) links in \(path)") }
        return sorted(box.values)
    }

    static func attributeNames(_ h5: SharedHDF5, _ object: hid_t, _ path: String) throws -> [String] {
        let box = Names()
        let callback: SharedHDF5.H5Aoperator = { _, name, _, data in
            guard let name, let data else { return -1 }
            let box = Unmanaged<Names>.fromOpaque(data).takeUnretainedValue()
            if box.values.count >= HDF5Ops.maximumLinks { box.overflow = true; return 1 }
            box.values.append(String(cString: name))
            return 0
        }
        let status = withExtendedLifetime(box) { h5.h5aiterate2(object, 0, 1, nil, callback, Unmanaged.passUnretained(box).toOpaque()) }
        guard status >= 0 else { throw HDF5RootAttributes.hdf5Failure("listing the attributes of \(path)", h5) }
        guard !box.overflow else { throw HDF5FileError.limitExceeded("more than \(maximumLinks) attributes on \(path)") }
        return sorted(box.values)
    }

    // MARK: Types and shapes

    private static let classNames = ["integer", "float", "time", "string", "bitfield", "opaque", "compound", "reference", "enum",
                                     "vlen", "array"]
    static func className(_ cls: Int32) -> String { cls >= 0 && Int(cls) < classNames.count ? classNames[Int(cls)] : "class\(cls)" }

    static func dimensions(_ h5: SharedHDF5, _ space: hid_t, _ what: String) throws -> [Int] {
        guard space >= 0 else { throw HDF5RootAttributes.hdf5Failure("opening the space of \(what)", h5) }
        let rank = h5.h5sgetNdims(space)
        guard rank >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the rank of \(what)", h5) }
        guard rank <= maximumRank else { throw HDF5FileError.limitExceeded("rank \(rank) of \(what) is over \(maximumRank)") }
        if rank == 0 {
            // Scalar: one element. A null dataspace also has rank 0 but no element.
            guard h5.h5sgetNpoints(space) == 1 else { throw HDF5FileError.unsupportedType(path: what, type: "null dataspace") }
            return []
        }
        var dims = [hsize_t](repeating: 0, count: Int(rank))
        guard h5.h5sgetDims(space, &dims, nil) >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the shape of \(what)", h5) }
        guard dims.allSatisfy({ $0 <= UInt64(Int.max) }) else { throw HDF5FileError.limitExceeded("extent of \(what)") }
        let shape = dims.map(Int.init)
        do { _ = try FormatoArray.elementCount(shape) } catch { throw HDF5FileError.limitExceeded("element count of \(what)") }
        return shape
    }

    static func datasetType(_ h5: SharedHDF5, _ type: hid_t) -> HDF5DatasetType {
        let cls = h5.h5tgetClass(type), bits = h5.h5tgetSize(type) * 8
        switch cls {
        case 0:
            let name = "\(h5.h5tgetSign(type) == 1 ? "int" : "uint")\(bits)"
            return FormatoDataType(rawValue: name).map(HDF5DatasetType.numeric) ?? .unsupported(name)
        case 1:
            let name = "float\(bits)"
            return FormatoDataType(rawValue: name).map(HDF5DatasetType.numeric) ?? .unsupported(name)
        case 3:
            return .string(variableLength: h5.h5tisVariableStr(type) > 0)
        default:
            return .unsupported(className(cls))
        }
    }

    static func native(_ h5: SharedHDF5, _ type: FormatoDataType) -> hid_t? {
        switch type {
        case .float32: h5.float32
        case .float64: h5.float64
        case .uint8: h5.uint8
        case .uint16: h5.uint16
        case .uint32: h5.uint32
        case .uint64: h5.uint64
        case .int8: h5.int8
        case .int16: h5.int16
        case .int32: h5.int32
        case .int64: h5.int64
        case .rgb8, .rgba8, .rgb16, .rgba16: nil
        }
    }

    static func info(_ h5: SharedHDF5, _ dataset: hid_t, _ path: String) throws -> HDF5DatasetInfo {
        let space = h5.h5dgetSpace(dataset); defer { if space >= 0 { _ = h5.h5sclose(space) } }
        let type = h5.h5dgetType(dataset)
        guard type >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the type of \(path)", h5) }
        defer { _ = h5.h5tclose(type) }
        return HDF5DatasetInfo(shape: try dimensions(h5, space, path), type: datasetType(h5, type))
    }

    static func chunkShape(_ h5: SharedHDF5, _ dataset: hid_t, _ path: String) throws -> [Int]? {
        let plist = h5.h5dgetCreatePlist(dataset)
        guard plist >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the layout of \(path)", h5) }
        defer { _ = h5.h5pclose(plist) }
        guard h5.h5pgetLayout(plist) == 2 else { return nil }          // H5D_CHUNKED
        var dims = [hsize_t](repeating: 0, count: maximumRank)
        let rank = h5.h5pgetChunk(plist, Int32(maximumRank), &dims)
        guard rank >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the chunk shape of \(path)", h5) }
        return dims.prefix(Int(rank)).map { Int(clamping: $0) }
    }

    static func readBooleans(_ h5: SharedHDF5, _ dataset: hid_t, _ path: String, maximumBytes: Int) throws -> [Bool] {
        let space = h5.h5dgetSpace(dataset); defer { if space >= 0 { _ = h5.h5sclose(space) } }
        let type = h5.h5dgetType(dataset)
        guard type >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the type of \(path)", h5) }
        defer { _ = h5.h5tclose(type) }
        guard h5.h5tgetClass(type) == 8, h5.h5tgetSize(type) == 1 else {   // H5T_ENUM over one byte
            throw HDF5FileError.unsupportedType(path: path, type: className(h5.h5tgetClass(type)))
        }
        let elements = try FormatoArray.elementCount(try dimensions(h5, space, path))
        guard elements <= maximumBytes else { throw HDF5FileError.limitExceeded("reading \(path) needs more than \(maximumBytes) bytes") }
        var bytes = [UInt8](repeating: 0, count: elements)
        if elements > 0 {
            guard bytes.withUnsafeMutableBytes({ h5.h5dread(dataset, type, 0, 0, 0, $0.baseAddress) }) >= 0 else {
                throw HDF5RootAttributes.hdf5Failure("reading \(path)", h5)
            }
        }
        return bytes.map { $0 != 0 }
    }

    // MARK: Reading datasets

    static func readNumeric(_ h5: SharedHDF5, _ dataset: hid_t, _ path: String, start: [Int]?, count: [Int]?,
                            maximumBytes: Int) throws -> FormatoArray {
        var found = try info(h5, dataset, path)
        // float16 is read as float32 (HDF5 converts; every half-precision value is exact in float32).
        if found.type == .unsupported("float16") { found = HDF5DatasetInfo(shape: found.shape, type: .numeric(.float32)) }
        guard case .numeric(let dataType) = found.type, let nativeType = native(h5, dataType) else {
            switch found.type {
            case .string: throw HDF5FileError.unsupportedType(path: path, type: "string (use readStrings)")
            case .unsupported(let name): throw HDF5FileError.unsupportedType(path: path, type: name)
            case .numeric(let type): throw HDF5FileError.unsupportedType(path: path, type: type.rawValue)
            }
        }
        let start = start ?? [Int](repeating: 0, count: found.shape.count), count = count ?? found.shape
        do { try FormatoArray.validateSlab(start: start, count: count, shape: found.shape) } catch {
            throw HDF5FileError.invalidArgument("slab \(start) of \(count) is outside \(path) of shape \(found.shape)")
        }
        let elements = try FormatoArray.elementCount(count)
        let (bytes, overflow) = elements.multipliedReportingOverflow(by: dataType.byteSize)
        guard !overflow, bytes <= maximumBytes else { throw HDF5FileError.limitExceeded("reading \(path) needs more than \(maximumBytes) bytes") }
        var data = Data(count: bytes)
        if bytes > 0 {
            let space = h5.h5dgetSpace(dataset); defer { _ = h5.h5sclose(space) }
            if found.shape.isEmpty {
                guard data.withUnsafeMutableBytes({ h5.h5dread(dataset, nativeType, 0, 0, 0, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("reading \(path)", h5)
                }
            } else {
                let c = count.map(UInt64.init), s = start.map(UInt64.init)
                guard h5.h5sselectHyperslab(space, 0, s, nil, c, nil) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("selecting the slab of \(path)", h5)
                }
                let memory = h5.h5screateSimple(Int32(c.count), c, nil)
                guard memory >= 0 else { throw HDF5RootAttributes.hdf5Failure("making the memory space for \(path)", h5) }
                defer { _ = h5.h5sclose(memory) }
                guard data.withUnsafeMutableBytes({ h5.h5dread(dataset, nativeType, memory, space, 0, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("reading \(path)", h5)
                }
            }
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: data)
    }

    static func decode(_ bytes: UnsafeRawBufferPointer, _ name: String, maximumStringBytes: Int) throws -> String {
        guard bytes.count <= maximumStringBytes else { throw HDF5FileError.stringTooLong(attribute: name, bytes: bytes.count) }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw HDF5FileError.invalidUTF8(name) }
        return text
    }

    /// `elements` strings of the string type `type`, read with `read(type, buffer)`.
    static func strings(_ h5: SharedHDF5, type: hid_t, elements: Int, name: String, maximumStringBytes: Int, maximumBytes: Int,
                        read: (UnsafeMutableRawPointer?) -> herr_t) throws -> [String] {
        let variable = h5.h5tisVariableStr(type)
        guard variable >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the string type of \(name)", h5) }
        if variable > 0 {
            let (bytes, overflow) = elements.multipliedReportingOverflow(by: MemoryLayout<UnsafeMutablePointer<CChar>?>.size)
            guard !overflow, bytes <= maximumBytes else { throw HDF5FileError.limitExceeded("reading \(name) needs more than \(maximumBytes) bytes") }
            var pointers = [UnsafeMutablePointer<CChar>?](repeating: nil, count: elements)
            defer { for p in pointers { if let p { _ = h5.h5freeMemory(p) } } }
            guard pointers.withUnsafeMutableBytes({ read($0.baseAddress) }) >= 0 else {
                throw HDF5RootAttributes.hdf5Failure("reading \(name)", h5)
            }
            return try pointers.map { p in
                guard let p else { return "" }
                return try decode(UnsafeRawBufferPointer(start: p, count: strlen(p)), name, maximumStringBytes: maximumStringBytes)
            }
        }
        let size = h5.h5tgetSize(type)
        guard size > 0 else { throw HDF5RootAttributes.hdf5Failure("reading the string size of \(name)", h5) }
        guard size <= maximumStringBytes else { throw HDF5FileError.stringTooLong(attribute: name, bytes: size) }
        let (total, overflow) = elements.multipliedReportingOverflow(by: size)
        guard !overflow, total <= maximumBytes else { throw HDF5FileError.limitExceeded("reading \(name) needs more than \(maximumBytes) bytes") }
        var storage = [UInt8](repeating: 0, count: total)
        if total > 0 {
            guard storage.withUnsafeMutableBytes({ read($0.baseAddress) }) >= 0 else {
                throw HDF5RootAttributes.hdf5Failure("reading \(name)", h5)
            }
        }
        return try storage.withUnsafeBytes { all in
            try (0..<elements).map { i in
                let item = UnsafeRawBufferPointer(rebasing: all[(i * size)..<((i + 1) * size)])
                let end = item.firstIndex(of: 0) ?? size
                return try decode(UnsafeRawBufferPointer(rebasing: item[..<end]), name, maximumStringBytes: maximumStringBytes)
            }
        }
    }

    static func readStrings(_ h5: SharedHDF5, _ dataset: hid_t, _ path: String, maximumStringBytes: Int,
                            maximumBytes: Int) throws -> [String] {
        let found = try info(h5, dataset, path)
        guard case .string = found.type else {
            let name: String
            switch found.type {
            case .numeric(let type): name = type.rawValue
            case .unsupported(let other): name = other
            case .string: name = "string"
            }
            throw HDF5FileError.unsupportedType(path: path, type: name)
        }
        let elements = try FormatoArray.elementCount(found.shape)
        let type = h5.h5dgetType(dataset)
        guard type >= 0 else { throw HDF5RootAttributes.hdf5Failure("reading the type of \(path)", h5) }
        defer { _ = h5.h5tclose(type) }
        return try strings(h5, type: type, elements: elements, name: path, maximumStringBytes: maximumStringBytes,
                           maximumBytes: maximumBytes) { h5.h5dread(dataset, type, 0, 0, 0, $0) }
    }

    // MARK: Attributes

    static func readAttribute(_ h5: SharedHDF5, _ object: hid_t, _ name: String, _ path: String,
                              maximumStringBytes: Int) throws -> HDF5AttributeValue {
        guard !name.isEmpty, !name.utf8.contains(0) else { throw HDF5FileError.invalidPath(name) }
        let label = path + "@" + name
        let exists = name.withCString { h5.h5aexists(object, $0) }
        guard exists >= 0 else { throw HDF5RootAttributes.hdf5Failure("looking for the \(name) attribute", h5) }
        guard exists > 0 else { throw HDF5FileError.notFound(label) }
        let attribute = name.withCString { h5.h5aopen(object, $0, 0) }
        guard attribute >= 0 else { throw HDF5RootAttributes.hdf5Failure("opening the \(name) attribute", h5) }
        defer { _ = h5.h5aclose(attribute) }
        let space = h5.h5agetSpace(attribute)
        guard space >= 0 else { throw HDF5RootAttributes.hdf5Failure("opening the space of \(label)", h5) }
        defer { _ = h5.h5sclose(space) }
        let shape = try dimensions(h5, space, label)
        guard shape.count <= 1 else { throw HDF5FileError.unsupportedType(path: label, type: "rank \(shape.count)") }
        let elements = shape.first ?? 1
        guard elements <= maximumAttributeElements else { throw HDF5FileError.limitExceeded("\(elements) elements in \(label)") }
        let scalar = shape.isEmpty
        let type = h5.h5agetType(attribute)
        guard type >= 0 else { throw HDF5RootAttributes.hdf5Failure("opening the type of \(label)", h5) }
        defer { _ = h5.h5tclose(type) }
        let cls = h5.h5tgetClass(type), size = h5.h5tgetSize(type)
        switch cls {
        case 3:
            let all = try strings(h5, type: type, elements: elements, name: label, maximumStringBytes: maximumStringBytes,
                                  maximumBytes: 64 << 20) { h5.h5aread(attribute, type, $0) }
            return scalar ? .text(all[0]) : .texts(all)
        case 0:
            guard [1, 2, 4, 8].contains(size) else { throw HDF5FileError.unsupportedType(path: label, type: "int\(size * 8)") }
            let unsigned64 = size == 8 && h5.h5tgetSign(type) == 0
            var values = [Int64](repeating: 0, count: elements)
            if elements > 0 {
                let mem = unsigned64 ? h5.uint64 : h5.int64
                guard values.withUnsafeMutableBytes({ h5.h5aread(attribute, mem, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("reading \(label)", h5)
                }
            }
            if unsigned64, values.contains(where: { $0 < 0 }) {      // the bits of a UInt64 over Int64.max
                throw HDF5FileError.limitExceeded("\(label) holds an unsigned 64-bit value over \(Int64.max)")
            }
            return scalar ? .integer(values[0]) : .integers(values)
        case 8 where size == 1:
            // h5py's bool (a one-byte enum, FALSE = 0, TRUE = 1): read as the integers 0 and 1.
            var values = [UInt8](repeating: 0, count: elements)
            if elements > 0 {
                guard values.withUnsafeMutableBytes({ h5.h5aread(attribute, type, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("reading \(label)", h5)
                }
            }
            // Only h5py's bool (members FALSE = 0 and TRUE = 1): any other value means another enum, which stays unsupported.
            guard values.allSatisfy({ $0 <= 1 }) else { throw HDF5FileError.unsupportedType(path: label, type: "enum") }
            let flags = values.map { Int64($0) }
            return scalar ? .integer(flags[0]) : .integers(flags)
        case 1:
            guard [2, 4, 8].contains(size) else { throw HDF5FileError.unsupportedType(path: label, type: "float\(size * 8)") }
            var values = [Double](repeating: 0, count: elements)
            if elements > 0 {
                guard values.withUnsafeMutableBytes({ h5.h5aread(attribute, h5.float64, $0.baseAddress) }) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("reading \(label)", h5)
                }
            }
            return scalar ? .real(values[0]) : .reals(values)
        default:
            throw HDF5FileError.unsupportedType(path: label, type: className(cls))
        }
    }
}
