//
//  FormatoSignal.swift
//  Role: A signal: its values, one axis per dimension in array order, its title, its
//        signal type and its metadata; eager (`FormatoSignal`) or lazy (`FormatoLazySignal` over a `FormatoLazyArray`).
//        REGISTERED EQUAL: `load()` is `read(start: zeros, count: shape)`, and every hyperslab a lazy array reads equals the
//        same slab cut from the eager array, bit for bit (`ArrayTests`).
//

import Foundation

public nonisolated struct FormatoSignal: Sendable, Equatable {
    public let title: String
    /// RosettaSciIO's `signal_type`: "EELS", "EDS_TEM", "CL", "" for none.
    public let signalType: String
    /// One per dimension of `data.shape`, in array order.
    public let axes: [FormatoAxis]
    public let metadata: FormatoMetadata
    public let data: FormatoArray

    public init(title: String, signalType: String, axes: [FormatoAxis], metadata: FormatoMetadata, data: FormatoArray) {
        self.title = title
        self.signalType = signalType
        self.axes = axes
        self.metadata = metadata
        self.data = data
    }
}

/// An array read on demand. `read` returns the hyperslab `[start, start + count)` per dimension, in C order, little-endian,
/// and touches only what it needs (a reader seeks to it; it never loads the whole file for a slab).
public nonisolated protocol FormatoLazyArray: Sendable {
    var dataType: FormatoDataType { get }
    var shape: [Int] { get }
    func read(start: [Int], count: [Int]) throws -> FormatoArray
}

extension FormatoLazyArray {
    /// The whole array: `read(start: zeros, count: shape)`.
    public func readAll() throws -> FormatoArray {
        try read(start: [Int](repeating: 0, count: shape.count), count: shape)
    }
}

public nonisolated struct FormatoLazySignal: Sendable {
    public let title: String
    public let signalType: String
    public let axes: [FormatoAxis]
    public let metadata: FormatoMetadata
    public let array: any FormatoLazyArray

    public init(title: String, signalType: String, axes: [FormatoAxis], metadata: FormatoMetadata, array: any FormatoLazyArray) {
        self.title = title
        self.signalType = signalType
        self.axes = axes
        self.metadata = metadata
        self.array = array
    }

    /// The eager signal: the whole array read once.
    public func load() throws -> FormatoSignal {
        FormatoSignal(title: title, signalType: signalType, axes: axes, metadata: metadata, data: try array.readAll())
    }
}

/// A lazy array over bytes already in memory (a test reference, or a reader that has its data whole).
public nonisolated struct FormatoInMemoryArray: FormatoLazyArray {
    public let array: FormatoArray
    public init(_ array: FormatoArray) { self.array = array }
    public var dataType: FormatoDataType { array.dataType }
    public var shape: [Int] { array.shape }
    public func read(start: [Int], count: [Int]) throws -> FormatoArray { try array.slab(start: start, count: count) }
}

/// A lazy array stored contiguously in C order at `offset` in a file, little-endian: each contiguous run of a slab is one
/// positioned read (`pread`), so a slab never reads bytes outside itself. DM stores its image data this way.
public nonisolated struct FormatoFileArray: FormatoLazyArray {
    public let path: String
    public let offset: Int
    public let dataType: FormatoDataType
    public let shape: [Int]

    public init(path: String, offset: Int, dataType: FormatoDataType, shape: [Int]) {
        self.path = path
        self.offset = offset
        self.dataType = dataType
        self.shape = shape
    }

    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        let size = dataType.byteSize
        let total = try FormatoArray.elementCount(count) * size
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), String(cString: strerror(errno))) }
        defer { close(fd) }
        var out = Data(count: total)
        var failure: FormatoReadError?
        out.withUnsafeMutableBytes { dst in
            var written = 0
            FormatoArray.forEachContiguousRun(start: start, count: count, shape: shape) { element, length in
                guard failure == nil else { return }
                let want = length * size
                var done = 0
                while done < want {
                    let n = pread(fd, dst.baseAddress! + written + done, want - done, off_t(offset + element * size + done))
                    if n <= 0 { failure = .truncated(formatoDisplayFileName(path)); return }
                    done += n
                }
                written += want
            }
        }
        if let failure { throw failure }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}

public nonisolated enum FormatoReadError: Error, Equatable, LocalizedError {
    case cannotOpen(String, String)
    case truncated(String)
    /// A stored type FormatoKit does not read (complex, RGB, bool, packed complex): named, never converted.
    case unsupportedDataType(String)
    /// A layout or calibration the reader refuses rather than guesses.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let name, let why): return "\(name) cannot be opened: \(why)."
        case .truncated(let name): return "\(name) ends before its data does."
        case .unsupportedDataType(let what): return "\(what) is stored as a type this reader does not read."
        case .unsupported(let what): return what
        }
    }
}
