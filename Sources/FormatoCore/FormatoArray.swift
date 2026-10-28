//
//  FormatoArray.swift
//  Role: The values of a signal as the file stores them: a stored element type, a shape
//        in C order (slowest first, RosettaSciIO's array shape) and the values as little-endian bytes in that order. Two
//        arrays are equal when type, shape and bytes are equal: that is the bit-for-bit claim against RosettaSciIO, whose
//        array `.tobytes()` in little-endian order is the same byte string.
//

import Foundation

/// A stored element type. A file type outside this list (complex, bool) is refused by name, never converted.
/// The colour types are RosettaSciIO's structured RGB arrays: one element is one pixel, its
/// samples interleaved as stored (each sample little-endian), so shape and bytes equal RosettaSciIO's.
public nonisolated enum FormatoDataType: String, Sendable, Equatable, CaseIterable {
    case int8, int16, int32, int64, uint8, uint16, uint32, uint64, float32, float64
    case rgb8, rgba8, rgb16, rgba16

    /// Bytes per element.
    public var byteSize: Int {
        switch self {
        case .int8, .uint8: return 1
        case .int16, .uint16: return 2
        case .int32, .uint32, .float32: return 4
        case .int64, .uint64, .float64: return 8
        case .rgb8: return 3
        case .rgba8: return 4
        case .rgb16: return 6
        case .rgba16: return 8
        }
    }

    /// Samples per element: 1, or 3 / 4 for the colour types.
    public var components: Int {
        switch self {
        case .rgb8, .rgb16: return 3
        case .rgba8, .rgba16: return 4
        default: return 1
        }
    }
}

public nonisolated enum FormatoArrayError: Error, Equatable, LocalizedError {
    /// The byte count is not the product of the shape and the element size.
    case byteCountMismatch(expected: Int, got: Int)
    /// A hyperslab outside the array, or of another rank.
    case slabOutOfBounds(start: [Int], count: [Int], shape: [Int])
    /// A shape with a negative extent, or whose element count overflows.
    case invalidShape([Int])

    public var errorDescription: String? {
        switch self {
        case .byteCountMismatch(let e, let g): return "The array holds \(g) bytes where its shape and type need \(e)."
        case .slabOutOfBounds(let s, let c, let shape): return "The slab at \(s) of \(c) is outside an array of shape \(shape)."
        case .invalidShape(let s): return "\(s) is not a valid array shape."
        }
    }
}

/// Values in C order as little-endian bytes. Immutable; `bytes` is shared copy-on-write.
public nonisolated struct FormatoArray: Sendable, Equatable {
    public let dataType: FormatoDataType
    public let shape: [Int]
    public let bytes: Data

    public init(dataType: FormatoDataType, shape: [Int], bytes: Data) throws {
        let count = try FormatoArray.elementCount(shape)
        let (need, overflow) = count.multipliedReportingOverflow(by: dataType.byteSize)
        guard !overflow else { throw FormatoArrayError.invalidShape(shape) }
        guard bytes.count == need else { throw FormatoArrayError.byteCountMismatch(expected: need, got: bytes.count) }
        self.dataType = dataType
        self.shape = shape
        self.bytes = bytes
    }

    /// The number of elements of `shape` (1 for rank 0); throws for a negative extent or an overflow.
    public static func elementCount(_ shape: [Int]) throws -> Int {
        var n = 1
        for e in shape {
            guard e >= 0 else { throw FormatoArrayError.invalidShape(shape) }
            let (m, o) = n.multipliedReportingOverflow(by: e)
            guard !o else { throw FormatoArrayError.invalidShape(shape) }
            n = m
        }
        return n
    }

    public var count: Int { bytes.count / dataType.byteSize }

    /// Every value converted to Double, in C order (exact for every type except 64-bit integers beyond 2^53); for a
    /// colour type, every sample, interleaved (`count * components` values).
    public func doubles() -> [Double] {
        var out = [Double](repeating: 0, count: count * dataType.components)
        bytes.withUnsafeBytes { p in
            switch dataType {
            case .int8: for i in out.indices { out[i] = Double(p.loadUnaligned(fromByteOffset: i, as: Int8.self)) }
            case .uint8: for i in out.indices { out[i] = Double(p.loadUnaligned(fromByteOffset: i, as: UInt8.self)) }
            case .int16: for i in out.indices { out[i] = Double(Int16(littleEndian: p.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))) }
            case .uint16: for i in out.indices { out[i] = Double(UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))) }
            case .int32: for i in out.indices { out[i] = Double(Int32(littleEndian: p.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self))) }
            case .uint32: for i in out.indices { out[i] = Double(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))) }
            case .int64: for i in out.indices { out[i] = Double(Int64(littleEndian: p.loadUnaligned(fromByteOffset: 8 * i, as: Int64.self))) }
            case .uint64: for i in out.indices { out[i] = Double(UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self))) }
            case .float32: for i in out.indices { out[i] = Double(Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)))) }
            case .float64: for i in out.indices { out[i] = Double(bitPattern: UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self))) }
            case .rgb8, .rgba8: for i in out.indices { out[i] = Double(p.loadUnaligned(fromByteOffset: i, as: UInt8.self)) }
            case .rgb16, .rgba16: for i in out.indices { out[i] = Double(UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))) }
            }
        }
        return out
    }

    /// The hyperslab `[start, start + count)` per dimension, cut from this array in C order: the eager reference every lazy
    /// read is compared with (`ArrayTests`).
    public func slab(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.checkSlab(start: start, count: count, shape: shape)
        let size = dataType.byteSize
        var out = Data(capacity: try FormatoArray.elementCount(count) * size)
        bytes.withUnsafeBytes { src in
            FormatoArray.forEachRun(start: start, count: count, shape: shape) { element, length in
                out.append(contentsOf: UnsafeRawBufferPointer(rebasing: src[(element * size)..<((element + length) * size)]))
            }
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }

    /// Throws unless `start` and `count` have the array's rank and lie inside it (a zero count is allowed).
    public static func checkSlab(start: [Int], count: [Int], shape: [Int]) throws {
        guard start.count == shape.count, count.count == shape.count,
              zip(zip(start, count), shape).allSatisfy({ s, n in s.0 >= 0 && s.1 >= 0 && s.0 <= n && s.1 <= n - s.0 })
        else { throw FormatoArrayError.slabOutOfBounds(start: start, count: count, shape: shape) }
    }

    /// Calls `body(firstElement, length)` for each contiguous run of the slab, in C order: a run is one row of the last
    /// dimension (the whole slab when it is the whole array). Element indices are into the full array.
    public static func forEachRun(start: [Int], count: [Int], shape: [Int], _ body: (Int, Int) -> Void) {
        let rank = shape.count
        if rank == 0 { body(0, 1); return }
        if count.contains(0) { return }
        var strides = [Int](repeating: 1, count: rank)
        for k in stride(from: rank - 2, through: 0, by: -1) { strides[k] = strides[k + 1] * shape[k + 1] }
        let rowLength = count[rank - 1]
        var index = [Int](repeating: 0, count: max(rank - 1, 0))   // position within the slab, outer dimensions
        while true {
            var element = start[rank - 1]
            for k in 0..<(rank - 1) { element += (start[k] + index[k]) * strides[k] }
            body(element, rowLength)
            var k = rank - 2
            while k >= 0 {
                index[k] += 1
                if index[k] < count[k] { break }
                index[k] = 0
                k -= 1
            }
            if k < 0 { return }
        }
    }
}
