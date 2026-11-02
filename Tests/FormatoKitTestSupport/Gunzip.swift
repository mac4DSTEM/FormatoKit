import Foundation
import FormatoCore

/// A committed `.gz` fixture inflated in this process (RFC 1952: one member, its CRC-32 and length checked).
///
/// The tests used to run `/usr/bin/gzip -dc` as a child process. A child started while another test thread had an HDF5 file
/// open for writing got a copy of that descriptor until it ran `exec`, so the file's `flock` outlived HDF5's close: the read that
/// followed failed with "unable to lock file, errno = 35" (FormatoKit#49). Inflating here starts no child.
package enum Gunzip {
    package struct Malformed: Error, CustomStringConvertible {
        package let description: String
    }

    package static func contents(of url: URL) throws -> Data {
        try inflate(Data(contentsOf: url))
    }

    package static func inflate(_ gz: Data) throws -> Data {
        let bytes = [UInt8](gz)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw Malformed(description: "not a deflate gzip member")
        }
        let flags = bytes[3]
        var at = 10
        if flags & 0x04 != 0 {                                    // FEXTRA
            guard at + 2 <= bytes.count else { throw Malformed(description: "truncated FEXTRA") }
            at += 2 + Int(bytes[at]) + Int(bytes[at + 1]) << 8
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // FNAME, FCOMMENT: zero-terminated
            guard let end = bytes[min(at, bytes.count)...].firstIndex(of: 0) else { throw Malformed(description: "truncated name") }
            at = end + 1
        }
        if flags & 0x02 != 0 { at += 2 }                          // FHCRC
        guard at <= bytes.count - 8 else { throw Malformed(description: "truncated member") }
        func le32(_ i: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i + $1]) << (8 * $1) } }
        let crc = le32(bytes.count - 8), size = le32(bytes.count - 4)
        // Compression's ZLIB is raw DEFLATE (RFC 1951), the body of a gzip member.
        let body = Data(bytes[at..<(bytes.count - 8)])
        let out: Data = size == 0 ? Data() : try (body as NSData).decompressed(using: .zlib) as Data
        guard UInt32(truncatingIfNeeded: out.count) == size else {
            throw Malformed(description: "inflated \(out.count) bytes, the trailer says \(size)")
        }
        guard FormatoPNG.crc32(out) == crc else { throw Malformed(description: "CRC-32 differs from the trailer") }
        return out
    }
}
