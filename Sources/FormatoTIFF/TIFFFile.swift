//
//  TIFFFile.swift
//  Role: the TIFF container (docs/registration-step-2.md §1.1, §3.2): the header (classic TIFF and BigTIFF, II and MM),
//        every directory of the main chain, every tag with its code, type, count and value as stored, and the pixel
//        data of a page (uncompressed, strips, contiguous, 1/3/4 samples of 8 to 64 bits). The tag walker is public, so
//        a consumer reads any private tag (Thermo Fisher's Velox XML 34683, Gatan's 65027, TIA's) as it is stored.
//        Tag values decode as tifffile 2026.9.20 decodes them (`TiffTag._process_value`): ASCII loses its trailing NULs,
//        decodes as UTF-8 or else cp1252, and is stripped of surrounding whitespace.
//        Written for FormatoKit; a GPL-3.0 TIFF image reader from an earlier project was read as the seed.
//

import Foundation
import FormatoCore

/// A TIFF tag's value, decoded by its TIFF type.
public nonisolated enum TIFFTagValue: Sendable, Equatable {
    /// BYTE, SHORT, LONG, LONG8, IFD, IFD8 and the signed SBYTE, SSHORT, SLONG, SLONG8.
    case integers([Int64])
    /// RATIONAL and SRATIONAL, numerator and denominator.
    case rationals([TIFFRational])
    /// FLOAT and DOUBLE.
    case reals([Double])
    /// ASCII, decoded (trailing NULs dropped, UTF-8 or cp1252, whitespace stripped).
    case text(String)
    /// UNDEFINED, and any type this reader does not know (kept as stored).
    case bytes(Data)
}

public nonisolated struct TIFFRational: Sendable, Equatable {
    public let numerator: Int64
    public let denominator: Int64
}

public nonisolated struct TIFFTag: Sendable, Equatable {
    public let code: Int
    /// The TIFF data type (1 BYTE, 2 ASCII, 3 SHORT, 4 LONG, 5 RATIONAL, 6 SBYTE, 7 UNDEFINED, 8 SSHORT, 9 SLONG,
    /// 10 SRATIONAL, 11 FLOAT, 12 DOUBLE, 13 IFD, 16 LONG8, 17 SLONG8, 18 IFD8).
    public let type: Int
    public let count: Int
    /// Where the value's bytes start in the file (inside the entry when they fit there).
    public let valueOffset: Int
    /// The value's bytes as stored (file byte order).
    public let raw: Data
    public let value: TIFFTagValue

    /// The value as integers (an integer type, or a rational with denominator 1), nil otherwise.
    public var integers: [Int64]? {
        if case .integers(let v) = value { return v }
        return nil
    }
    public var integer: Int64? { integers?.first }
    public var text: String? { if case .text(let s) = value { return s }; return nil }
}

public nonisolated struct TIFFDirectory: Sendable {
    public let offset: Int
    public let tags: [TIFFTag]
    public subscript(code: Int) -> TIFFTag? { tags.first { $0.code == code } }
}

public nonisolated enum TIFFError: Error, Equatable, LocalizedError {
    case notTIFF(String)
    case truncated(String)
    case loop(String)
    /// A page layout this reader refuses rather than guesses: compression, tiles, planar 2, a sample layout.
    case unsupportedLayout(String)

    public var errorDescription: String? {
        switch self {
        case .notTIFF(let n): return "\(n) is not a TIFF file."
        case .truncated(let n): return "\(n) ends before its data does."
        case .loop(let n): return "\(n)'s directory chain loops."
        case .unsupportedLayout(let why): return why
        }
    }
}

public nonisolated struct TIFFFile: Sendable {
    public let path: String
    public let bigEndian: Bool
    public let bigTIFF: Bool
    public let directories: [TIFFDirectory]
    let data: Data

    private static let typeSizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8,
                                                 13: 4, 16: 8, 17: 8, 18: 8]

    public init(path: String) throws {
        let name = formatoDisplayFileName(path)
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(name, error.localizedDescription)
        }
        try self.init(data: data, path: path)
    }

    public init(data: Data, path: String = "(memory)") throws {
        let name = formatoDisplayFileName(path)
        self.path = path
        self.data = data
        guard data.count >= 8 else { throw TIFFError.notTIFF(name) }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        guard (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) else { throw TIFFError.notTIFF(name) }
        let big = b0 == 0x4D
        bigEndian = big
        let reader = ByteReader(data: data, bigEndian: big)
        let magic = try reader.u16(2, name)
        var first: Int
        switch magic {
        case 42:
            bigTIFF = false
            first = Int(try reader.u32(4, name))
        case 43:
            guard data.count >= 16, try reader.u16(4, name) == 8, try reader.u16(6, name) == 0 else { throw TIFFError.notTIFF(name) }
            bigTIFF = true
            first = try reader.int64(8, name)
        default:
            throw TIFFError.notTIFF(name)
        }
        var dirs: [TIFFDirectory] = []
        var seen = Set<Int>()
        while first != 0 {
            guard seen.insert(first).inserted else { throw TIFFError.loop(name) }
            let (dir, next) = try TIFFFile.readDirectory(at: first, reader: reader, bigTIFF: bigTIFF, name: name)
            dirs.append(dir)
            first = next
        }
        directories = dirs
    }

    private static func readDirectory(at offset: Int, reader: ByteReader, bigTIFF: Bool, name: String) throws
        -> (TIFFDirectory, Int) {
        let count = bigTIFF ? try reader.int64(offset, name) : Int(try reader.u16(offset, name))
        let entrySize = bigTIFF ? 20 : 12
        let start = offset + (bigTIFF ? 8 : 2)
        guard count >= 0, count < 1 << 20 else { throw TIFFError.truncated(name) }
        var tags: [TIFFTag] = []
        tags.reserveCapacity(count)
        for i in 0..<count {
            let e = start + i * entrySize
            let code = Int(try reader.u16(e, name)), type = Int(try reader.u16(e + 2, name))
            let n = bigTIFF ? try reader.int64(e + 4, name) : Int(try reader.u32(e + 4, name))
            let fieldOffset = e + (bigTIFF ? 12 : 8)
            let inline = bigTIFF ? 8 : 4
            let size = typeSizes[type] ?? 1
            let (bytes, overflow) = n.multipliedReportingOverflow(by: size)
            guard !overflow, n >= 0 else { throw TIFFError.truncated(name) }
            let valueOffset = bytes <= inline ? fieldOffset
                : (bigTIFF ? try reader.int64(fieldOffset, name) : Int(try reader.u32(fieldOffset, name)))
            let raw = try reader.slice(valueOffset, bytes, name)
            tags.append(TIFFTag(code: code, type: type, count: n, valueOffset: valueOffset, raw: raw,
                                value: decode(raw, type: type, count: n, bigEndian: reader.bigEndian)))
        }
        let nextAt = start + count * entrySize
        let next = bigTIFF ? try reader.int64(nextAt, name) : Int(try reader.u32(nextAt, name))
        return (TIFFDirectory(offset: offset, tags: tags), next)
    }

    static func decode(_ raw: Data, type: Int, count: Int, bigEndian: Bool) -> TIFFTagValue {
        let r = ByteReader(data: raw, bigEndian: bigEndian)
        func ints(_ size: Int, _ f: (Int) -> Int64) -> TIFFTagValue { .integers((0..<count).map { f($0 * size) }) }
        switch type {
        case 1: return ints(1) { Int64(r.u8($0)) }
        case 6: return ints(1) { Int64(Int8(bitPattern: r.u8($0))) }
        case 3: return ints(2) { Int64(r.u16u($0)) }
        case 8: return ints(2) { Int64(Int16(bitPattern: r.u16u($0))) }
        case 4, 13: return ints(4) { Int64(r.u32u($0)) }
        case 9: return ints(4) { Int64(Int32(bitPattern: r.u32u($0))) }
        case 16, 18: return ints(8) { Int64(bitPattern: r.u64u($0)) }
        case 17: return ints(8) { Int64(bitPattern: r.u64u($0)) }
        case 5: return .rationals((0..<count).map { TIFFRational(numerator: Int64(r.u32u($0 * 8)), denominator: Int64(r.u32u($0 * 8 + 4))) })
        case 10: return .rationals((0..<count).map {
            TIFFRational(numerator: Int64(Int32(bitPattern: r.u32u($0 * 8))), denominator: Int64(Int32(bitPattern: r.u32u($0 * 8 + 4))))
        })
        case 11: return .reals((0..<count).map { Double(Float(bitPattern: r.u32u($0 * 4))) })
        case 12: return .reals((0..<count).map { Double(bitPattern: r.u64u($0 * 8)) })
        case 2: return .text(asciiString(raw))
        default: return .bytes(raw)
        }
    }

    /// tifffile's ASCII rule: trailing NULs dropped, UTF-8 or else cp1252, whitespace stripped.
    static func asciiString(_ raw: Data) -> String {
        var bytes = [UInt8](raw)
        while bytes.last == 0 { bytes.removeLast() }
        let s = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .windowsCP1252) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `bytes2str` (used for INI text): up to the first NUL, UTF-8 or else cp1252, not stripped.
    static func bytes2str(_ raw: Data) -> String {
        let bytes = [UInt8](raw.prefix { $0 != 0 })
        // Python's UTF-8 decode keeps a byte-order mark as U+FEFF, which Foundation drops: kept here (Gate B F15).
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        guard let s = String(bytes: bytes, encoding: .utf8) else { return String(bytes: bytes, encoding: .windowsCP1252) ?? "" }
        return bom && !s.hasPrefix("\u{FEFF}") ? "\u{FEFF}" + s : s
    }

    /// Python's `str.splitlines()`: "\r\n", "\r", "\n", "\u{0B}", "\u{0C}", "\u{1C}"-"\u{1E}", "\u{85}", U+2028, U+2029
    /// each end a line (Gate B F15).
    static func splitLines(_ s: String) -> [Substring] {
        s.split(omittingEmptySubsequences: false, whereSeparator: { c in
            c.isNewline || c == "\u{1C}" || c == "\u{1D}" || c == "\u{1E}" || c == "\u{0B}" || c == "\u{0C}"
        })
    }
}

/// Bounds-checked reads in one byte order.
nonisolated struct ByteReader {
    let data: Data
    let bigEndian: Bool
    func check(_ offset: Int, _ n: Int, _ name: String) throws {
        guard offset >= 0, n >= 0, n <= data.count, offset <= data.count - n else { throw TIFFError.truncated(name) }
    }
    func slice(_ offset: Int, _ n: Int, _ name: String) throws -> Data {
        try check(offset, n, name)
        return Data(data[(data.startIndex + offset)..<(data.startIndex + offset + n)])
    }
    func u8(_ o: Int) -> UInt8 { data[data.startIndex + o] }
    func u16u(_ o: Int) -> UInt16 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
        return bigEndian ? UInt16(bigEndian: v) : UInt16(littleEndian: v)
    }
    func u32u(_ o: Int) -> UInt32 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
    }
    func u64u(_ o: Int) -> UInt64 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
        return bigEndian ? UInt64(bigEndian: v) : UInt64(littleEndian: v)
    }
    func u16(_ o: Int, _ name: String) throws -> UInt16 { try check(o, 2, name); return u16u(o) }
    /// A BigTIFF count or offset as Int; one at or beyond 2^63 cannot address this file and is refused (Gate B F9).
    func int64(_ o: Int, _ name: String) throws -> Int {
        guard let v = Int(exactly: try u64(o, name)) else { throw TIFFError.truncated(name) }
        return v
    }
    func u32(_ o: Int, _ name: String) throws -> UInt32 { try check(o, 4, name); return u32u(o) }
    func u64(_ o: Int, _ name: String) throws -> UInt64 { try check(o, 8, name); return u64u(o) }
}
