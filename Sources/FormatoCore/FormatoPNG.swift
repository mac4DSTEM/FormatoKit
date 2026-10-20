//
//  FormatoPNG.swift
//  Role: write a PNG with text chunks, and put text chunks into a PNG some other encoder made, with the chunk bytes and CRCs
//        computed here; read the text chunks back. For an export that carries its provenance inside the image file.
//
//  Why not ImageIO's property dictionary: on macOS 27.0.1 ImageIO turns the PNG Title, Software and Description properties
//  into an XMP packet (an iTXt chunk "XML:com.adobe.xmp") and never writes the tEXt chunks of those names (measured by the
//  first consumer, 2026-10-13; Pillow then has no `Description`). A reader such as Pillow, ExifTool or a lab notebook script
//  looks for tEXt, so the chunks are written by this file.
//
//  A text entry is a keyword and a value. The keyword is 1 to 79 printable Latin-1 characters (PNG 1.2 section 11.3.4.2:
//  no leading, trailing or doubled space). The value goes in a `tEXt` chunk when it is printable ASCII (space to ~), else in an
//  `iTXt` chunk, UTF-8 and uncompressed, with an empty language tag and translated keyword. Chunks are inserted before the
//  first IDAT, in the order given.
//
//  The encoder writes 8-bit gray, 16-bit gray, 8-bit RGB or 8-bit RGBA, non-interlaced, filter type 0 on every scanline, one
//  IDAT, zlib-wrapped deflate (the Compression framework's, with a stored-block fallback for data it will not shrink).
//

import Foundation
import Compression

/// One text chunk's content.
public nonisolated struct PNGTextEntry: Sendable, Equatable {
    public var keyword: String
    public var value: String
    public init(keyword: String, value: String) { self.keyword = keyword; self.value = value }
}

public nonisolated enum PNGError: Error, Equatable, LocalizedError {
    case notPNG
    case malformed(String)
    case invalidKeyword(String)
    case invalidImage(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notPNG: "the data is not a PNG (no PNG signature)."
        case .malformed(let detail): "the PNG is malformed (\(detail))."
        case .invalidKeyword(let keyword): "\"\(keyword)\" is not a PNG text keyword (1 to 79 printable Latin-1 characters, no leading, trailing or doubled space)."
        case .invalidImage(let detail): "the image cannot be written as a PNG (\(detail))."
        case .unsupported(let detail): "unsupported PNG content (\(detail))."
        }
    }
}

public nonisolated enum PNGPixelFormat: Sendable, Equatable {
    case gray8, gray16, rgb8, rgba8

    /// Bytes per pixel in the pixel data handed to the encoder.
    public var bytesPerPixel: Int {
        switch self { case .gray8: 1; case .gray16: 2; case .rgb8: 3; case .rgba8: 4 }
    }
    fileprivate var colorType: UInt8 {
        switch self { case .gray8, .gray16: 0; case .rgb8: 2; case .rgba8: 6 }
    }
    fileprivate var bitDepth: UInt8 { self == .gray16 ? 16 : 8 }
}

public nonisolated enum FormatoPNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The largest image this encoder takes: 64k pixels a side and 1 GiB of pixel bytes.
    public static let maximumSide = 65_535
    public static let maximumBytes = 1 << 30

    // MARK: Writing

    /// Encodes a PNG. `pixels` is row-major and tightly packed, `width * height * format.bytesPerPixel` bytes; for `.gray16`
    /// each sample is two bytes, little-endian (stored big-endian in the file, as PNG requires). `text` entries are written
    /// before the image data.
    public static func encode(width: Int, height: Int, format: PNGPixelFormat, pixels: Data,
                              text: [PNGTextEntry] = []) throws -> Data {
        try encode(width: width, height: height, format: format, pixels: pixels, text: text, zlib: zlibCompress)
    }

    /// `encode` with the zlib stage chosen by the caller (the tests drive the stored-block path through it).
    package static func encode(width: Int, height: Int, format: PNGPixelFormat, pixels: Data, text: [PNGTextEntry],
                               zlib: ([UInt8]) -> [UInt8]) throws -> Data {
        guard width >= 1, height >= 1, width <= maximumSide, height <= maximumSide else {
            throw PNGError.invalidImage("\(width) x \(height) is outside 1...\(maximumSide)")
        }
        let rowBytes = width * format.bytesPerPixel
        let (total, overflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !overflow, total <= maximumBytes else { throw PNGError.invalidImage("more than \(maximumBytes) bytes of pixels") }
        guard pixels.count == total else { throw PNGError.invalidImage("\(pixels.count) bytes for \(width) x \(height) \(format)") }
        let chunks = try text.map { try textChunk($0) }

        var raw = [UInt8](); raw.reserveCapacity(total + height)
        pixels.withUnsafeBytes { source in
            let bytes = source.bindMemory(to: UInt8.self)
            for row in 0..<height {
                raw.append(0)                                               // filter type: None
                let base = row * rowBytes
                if format == .gray16 {
                    for i in stride(from: 0, to: rowBytes, by: 2) { raw.append(bytes[base + i + 1]); raw.append(bytes[base + i]) }
                } else {
                    raw.append(contentsOf: bytes[base..<(base + rowBytes)])
                }
            }
        }
        var header = [UInt8]()
        header += be32(width); header += be32(height)
        header += [format.bitDepth, format.colorType, 0, 0, 0]               // compression, filter, no interlace
        var out = Data(signature)
        out.append(contentsOf: framed("IHDR", header))
        for chunk in chunks { out.append(contentsOf: chunk) }
        out.append(contentsOf: framed("IDAT", zlib(raw)))
        out.append(contentsOf: framed("IEND", []))
        return out
    }

    /// Returns `png` with `entries` inserted as text chunks before its first IDAT (the chunks the PNG already has are kept).
    public static func inserting(_ entries: [PNGTextEntry], into png: Data) throws -> Data {
        let chunks = try entries.map { try textChunk($0) }
        guard png.count >= 8, Array(png.prefix(8)) == signature else { throw PNGError.notPNG }
        var offset = 8
        while offset + 12 <= png.count {
            let length = Int(be32(png, offset))
            if png[(offset + 4)..<(offset + 8)].elementsEqual("IDAT".utf8) {
                var out = Data()
                out.reserveCapacity(png.count + chunks.reduce(0) { $0 + $1.count })
                out.append(png.prefix(offset))
                for chunk in chunks { out.append(contentsOf: chunk) }
                out.append(png.suffix(from: offset))
                return out
            }
            let (next, over) = (offset + 12).addingReportingOverflow(length)
            guard !over, length >= 0, next <= png.count else { throw PNGError.malformed("a chunk runs past the end") }
            offset = next
        }
        throw PNGError.malformed("no IDAT chunk")
    }

    // MARK: Reading

    /// The `tEXt` and uncompressed `iTXt` entries of a PNG, in file order, every chunk's CRC checked. Compressed text
    /// (`zTXt`, compressed `iTXt`) is skipped. `malformed` for a bad CRC, a truncated chunk or a missing IEND.
    public static func textEntries(in png: Data) throws -> [PNGTextEntry] {
        guard png.count >= 8, Array(png.prefix(8)) == signature else { throw PNGError.notPNG }
        var offset = 8, entries: [PNGTextEntry] = [], sawEnd = false
        while offset + 12 <= png.count, !sawEnd {
            let length = Int(be32(png, offset))
            let (end, over) = (offset + 12).addingReportingOverflow(length)
            guard !over, end <= png.count else { throw PNGError.malformed("a chunk runs past the end") }
            let type = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = png[(offset + 8)..<(offset + 8 + length)]
            let stored = be32(png, offset + 8 + length)
            guard crc32(png[(offset + 4)..<(offset + 8 + length)]) == stored else { throw PNGError.malformed("the \(type) chunk's CRC differs") }
            if type == "tEXt", let nul = body.firstIndex(of: 0) {
                entries.append(PNGTextEntry(keyword: latin1(body[body.startIndex..<nul]), value: latin1(body[(nul + 1)...])))
            } else if type == "iTXt", let nul = body.firstIndex(of: 0), nul + 2 < body.endIndex, body[nul + 1] == 0 {
                // compression flag 0: language tag and translated keyword (NUL-terminated each), then the UTF-8 text.
                var cursor = nul + 3
                for _ in 0..<2 {
                    guard cursor <= body.endIndex, let end = body[cursor...].firstIndex(of: 0) else { throw PNGError.malformed("an iTXt chunk is cut short") }
                    cursor = end + 1
                }
                entries.append(PNGTextEntry(keyword: latin1(body[body.startIndex..<nul]), value: String(decoding: body[cursor...], as: UTF8.self)))
            }
            if type == "IEND" { sawEnd = true }
            offset = end
        }
        guard sawEnd else { throw PNGError.malformed("no IEND chunk") }
        return entries
    }

    // MARK: Chunk bytes

    /// One text chunk: `tEXt` for printable ASCII values, else `iTXt` (UTF-8, uncompressed).
    static func textChunk(_ entry: PNGTextEntry) throws -> [UInt8] {
        try validate(keyword: entry.keyword)
        let printable = entry.value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        var body = entry.keyword.unicodeScalars.map { UInt8($0.value) } + [0]
        if printable {
            body += Array(entry.value.utf8)
        } else {
            body += [0, 0, 0, 0] + Array(entry.value.utf8)        // compression flag, method, empty language tag, empty translated keyword
        }
        return framed(printable ? "tEXt" : "iTXt", body)
    }

    private static func validate(keyword: String) throws {
        let scalars = Array(keyword.unicodeScalars)
        guard (1...79).contains(scalars.count), scalars.first != " ", scalars.last != " " else { throw PNGError.invalidKeyword(keyword) }
        var previousSpace = false
        for scalar in scalars {
            let v = scalar.value
            guard (v >= 32 && v <= 126) || (v >= 161 && v <= 255), !(scalar == " " && previousSpace) else { throw PNGError.invalidKeyword(keyword) }
            previousSpace = scalar == " "
        }
    }

    /// Length, type, body, CRC-32 of type and body.
    static func framed(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typeAndBody = Array(type.utf8) + body
        return be32(body.count) + typeAndBody + be32(Int(crc32(typeAndBody)))
    }

    private static func be32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[data.startIndex + offset + $1]) }
    }
    private static func latin1(_ bytes: some Sequence<UInt8>) -> String {
        String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
    }

    // MARK: CRC-32 and Adler-32

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// ISO 3309 / PNG CRC-32 (the one `zlib.crc32` computes).
    public static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Adler-32 (the one `zlib.adler32` computes).
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)                      // the longest run that cannot overflow 32 bits
            for i in index..<end { a &+= UInt32(bytes[i]); b &+= a }
            a %= 65521; b %= 65521
            index = end
        }
        return (b << 16) | a
    }

    // MARK: zlib

    /// A zlib stream: header 0x78 0x9C, raw deflate (Compression framework), Adler-32. Data it will not shrink goes in stored blocks.
    package static func zlibCompress(_ raw: [UInt8]) -> [UInt8] {
        var deflated = [UInt8]()
        if !raw.isEmpty {
            let capacity = raw.count + raw.count / 100 + 1024
            var buffer = [UInt8](repeating: 0, count: capacity)
            let written = raw.withUnsafeBufferPointer { source in
                buffer.withUnsafeMutableBufferPointer { target in
                    compression_encode_buffer(target.baseAddress!, capacity, source.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { deflated = Array(buffer[0..<written]) }
        }
        if deflated.isEmpty { deflated = storedBlocks(raw) }
        return [0x78, 0x9C] + deflated + be32(Int(adler32(raw)))
    }

    /// A zlib stream of stored blocks only: what `zlibCompress` falls back to when the Compression framework gives nothing.
    package static func zlibStored(_ raw: [UInt8]) -> [UInt8] { [0x78, 0x01] + storedBlocks(raw) + be32(Int(adler32(raw))) }

    /// Deflate stored blocks (no compression): 5 bytes of header per up-to-65535 bytes.
    static func storedBlocks(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(raw.count + raw.count / 65535 * 5 + 5)
        var index = 0
        repeat {
            let count = min(65535, raw.count - index)
            let final: UInt8 = index + count >= raw.count ? 1 : 0
            out += [final, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            out += raw[index..<(index + count)]
            index += count
        } while index < raw.count
        return out
    }
}
