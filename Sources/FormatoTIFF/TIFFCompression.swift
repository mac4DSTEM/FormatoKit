//
//  TIFFCompression.swift
//  Role: the compressed strips this kit decodes, and the predictors it undoes, so a compressed page reads as the uncompressed
//        one would. LZW (TIFF Compression 5) is the scheme Gatan DigitalMicrograph and many SEMs write: TIFF 6.0 section 13,
//        codes MSB first, 9 to 12 bits, ClearCode 256, EndOfInformation 257, the code width growing one code early (as
//        libtiff writes and reads it; tifffile reads through imagecodecs' `lzw_decode`, the same code stream). Predictor 2
//        (horizontal differencing, section 14) on integer samples and Predictor 3 (floating point, Adobe Photoshop TIFF
//        Technical Note 3, libtiff's `fpAcc`) are undone row by row. The old-style (pre-6.0, LSB-first) LZW stream, every
//        other scheme, and a predictor on a sample type it does not apply to are refused in words.
//

import Foundation

nonisolated enum TIFFCompression {

    /// Why a compressed page is not read: one plain sentence (the callers put the file in front).
    nonisolated struct Failure: Error, Equatable {
        let reason: String
    }

    /// The schemes read: 1 (none) and 5 (LZW).
    static func isRead(_ compression: Int) -> Bool { compression == 1 || compression == 5 }

    /// The predictors read for a sample of `format` (1 unsigned, 2 signed, 3 float) and `bytes` bytes: 1 always, 2 for
    /// integers, 3 for 16, 32 and 64-bit floats. Nil when read, else the reason.
    static func predictorRefusal(_ predictor: Int, format: Int, bytes: Int) -> String? {
        switch predictor {
        case 1: return nil
        case 2: return format == 3 ? "it sets the horizontal predictor on floating-point samples" : nil
        case 3: return format == 3 && [2, 4, 8].contains(bytes) ? nil : "it sets the floating-point predictor on integer samples"
        default: return "it sets Predictor \(predictor), which is not read"
        }
    }

    /// The page's pixels as little-endian bytes, `rows` rows of `rowBytes`: each strip decoded and cut to its rows, the
    /// predictor undone. `strip(i)` returns strip `i`'s stored bytes.
    static func decodePage(compression: Int, predictor: Int, rows: Int, rowsPerStrip: Int, width: Int, samples: Int,
                           bytesPerSample: Int, bigEndian: Bool, strips: Int, strip: (Int) throws -> Data) throws -> Data {
        let rowBytes = width * samples * bytesPerSample
        let stripCount = (rows + rowsPerStrip - 1) / rowsPerStrip
        guard strips >= stripCount else { throw Failure(reason: "it has fewer strips than its rows need") }
        var page = Data(capacity: rows * rowBytes)
        for s in 0..<stripCount {
            let stripRows = min(rowsPerStrip, rows - s * rowsPerStrip)
            let need = stripRows * rowBytes
            let stored = try strip(s)
            var decoded: Data
            switch compression {
            case 1: decoded = stored
            case 5: decoded = try lzwDecode(stored, expected: need)
            default: throw Failure(reason: "its pixels are compressed with scheme \(compression), which is not read")
            }
            guard decoded.count >= need else {
                throw Failure(reason: "a strip of its LZW-compressed pixels decodes to \(decoded.count) bytes where its rows need \(need)")
            }
            if decoded.count > need { decoded = decoded.prefix(need) }
            if predictor == 3 {
                // The floating-point predictor yields host-order (little-endian) values whatever the file's byte order.
                floatingPointUndo(&decoded, rows: stripRows, width: width, samples: samples, bytes: bytesPerSample)
            } else {
                if bigEndian && bytesPerSample > 1 { swapElements(&decoded, bytes: bytesPerSample) }
                if predictor == 2 { horizontalUndo(&decoded, rows: stripRows, width: width, samples: samples, bytes: bytesPerSample) }
            }
            page.append(decoded)
        }
        return page
    }

    // MARK: - LZW

    /// Decodes one LZW strip (TIFF 6.0 §13). Decoding stops at EndOfInformation, at the end of the input (libtiff tolerates
    /// a missing EOI), or once `expected` bytes are out. A code that is not yet in the table is a corrupt stream.
    static func lzwDecode(_ input: Data, expected: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        // A stream that opens with 0x00 and an odd second byte is the old-style (LSB-first) LZW libtiff still reads for
        // compatibility; a new-style stream always opens with ClearCode (256 as 9 bits MSB first: 0x80).
        if input.count >= 2, input[input.startIndex] == 0, input[input.startIndex + 1] & 1 == 1 {
            throw Failure(reason: "its pixels use the old-style LZW of TIFF before 6.0, which is not read")
        }
        let clear = 256, eoi = 257
        var prefix = [Int32](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var first = [UInt8](repeating: 0, count: 4096)
        var length = [Int32](repeating: 0, count: 4096)
        for i in 0..<256 { suffix[i] = UInt8(i); first[i] = UInt8(i); length[i] = 1 }
        var out = [UInt8]()
        out.reserveCapacity(expected)
        var next = 258, width = 9, previous = -1
        var bitBuffer: UInt32 = 0, bitCount = 0

        func emit(_ code: Int) {
            let n = Int(length[code])
            let start = out.count
            out.append(contentsOf: repeatElement(0, count: n))
            var c = code, k = start + n - 1
            while k >= start { out[k] = suffix[c]; c = Int(prefix[c]); k -= 1 }
        }

        try input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var position = 0
            while out.count < expected {
                while bitCount < width {
                    guard position < bytes.count else { return }
                    bitBuffer = (bitBuffer << 8) | UInt32(bytes[position])
                    position += 1
                    bitCount += 8
                }
                let code = Int((bitBuffer >> UInt32(bitCount - width)) & UInt32((1 << width) - 1))
                bitCount -= width
                if code == eoi { return }
                if code == clear { next = 258; width = 9; previous = -1; continue }
                if previous < 0 {
                    guard code < 256 else { throw Failure(reason: "its LZW-compressed pixels are corrupt (a strip opens with code \(code))") }
                    emit(code)
                    previous = code
                    continue
                }
                guard code <= next, code < 4096 else { throw Failure(reason: "its LZW-compressed pixels are corrupt (code \(code) before it is defined)") }
                if next < 4096 {
                    prefix[next] = Int32(previous)
                    first[next] = first[previous]
                    suffix[next] = code < next ? first[code] : first[previous]
                    length[next] = length[previous] + 1
                }
                emit(code)
                if next < 4096 { next += 1 }
                // The width grows one code early (libtiff, tifffile and every TIFF writer since 6.0).
                if next >= 511 && width == 9 { width = 10 } else if next >= 1023 && width == 10 { width = 11 }
                else if next >= 2047 && width == 11 { width = 12 }
                previous = code
            }
        }
        return Data(out)
    }

    // MARK: - Predictors

    /// Byte-swaps every `bytes`-byte element in place (big-endian samples to little-endian).
    static func swapElements(_ data: inout Data, bytes: Int) {
        data.withUnsafeMutableBytes { p in
            var i = 0
            while i + bytes <= p.count {
                for k in 0..<(bytes / 2) { p.swapAt(i + k, i + bytes - 1 - k) }
                i += bytes
            }
        }
    }

    /// Predictor 2 undone: along each row every sample adds the same sample of the pixel before it, wrapping in the
    /// sample's own width (libtiff's `horAcc8/16/32/64`). The data are little-endian.
    static func horizontalUndo(_ data: inout Data, rows: Int, width: Int, samples: Int, bytes: Int) {
        let rowElements = width * samples
        data.withUnsafeMutableBytes { p in
            func run<T: FixedWidthInteger>(_: T.Type) {
                let size = MemoryLayout<T>.size
                guard rowElements > samples else { return }
                for r in 0..<rows {
                    let base = r * rowElements
                    for i in samples..<rowElements {
                        let at = (base + i) * size
                        let value = T(littleEndian: p.loadUnaligned(fromByteOffset: at, as: T.self))
                        let before = T(littleEndian: p.loadUnaligned(fromByteOffset: at - samples * size, as: T.self))
                        p.storeBytes(of: (value &+ before).littleEndian, toByteOffset: at, as: T.self)
                    }
                }
            }
            switch bytes {
            case 1: run(UInt8.self)
            case 2: run(UInt16.self)
            case 4: run(UInt32.self)
            default: run(UInt64.self)
            }
        }
    }

    /// Predictor 3 undone (libtiff's `fpAcc`): the bytes of a row are differenced byte by byte across samples, and stored
    /// as planes, most significant byte first. The row is summed back, then each element's bytes are gathered from the
    /// planes into little-endian order.
    static func floatingPointUndo(_ data: inout Data, rows: Int, width: Int, samples: Int, bytes: Int) {
        let elements = width * samples
        let rowBytes = elements * bytes
        data.withUnsafeMutableBytes { p in
            var row = [UInt8](repeating: 0, count: rowBytes)
            for r in 0..<rows {
                let base = r * rowBytes
                for i in 0..<rowBytes { row[i] = p[base + i] }
                if rowBytes > samples { for i in samples..<rowBytes { row[i] = row[i] &+ row[i - samples] } }
                for e in 0..<elements {
                    for b in 0..<bytes { p[base + e * bytes + b] = row[(bytes - b - 1) * elements + e] }
                }
            }
        }
    }
}
