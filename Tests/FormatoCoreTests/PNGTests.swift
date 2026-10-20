//
//  PNGTests.swift
//  FormatoPNG: the text-chunk insertion pinned byte for byte to the first consumer's own (Fixtures/png/mactem-inserted.png,
//  tools/png/oracle.sh), and the encoder's files read by Pillow and zlib (tools/png/check.py -> check-result.json, pinned
//  here with each file's SHA-256). CRC-32 against the standard check value.
//
//  Regenerating the swift-*.png fixtures: FORMATO_PNG_FIXTURE_DIR=<this Fixtures/png folder> swift test -c release --filter
//  PNGTests, then tools/png/check.py (its docstring has the line) and commit with check-result.json.
//

import Foundation
import Testing
import CryptoKit
import Compression
import FormatoCore

@Suite(.serialized) struct PNGTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/png")
    }
    private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

    // The generators repeated in tools/png/check.py.
    private func b8(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { UInt8((x * 37 + y * 91 + c * 53 + 7) % 256) }
    private func g16(_ x: Int, _ y: Int) -> UInt16 { UInt16((x * 2579 + y * 7919 + 13) % 65536) }
    private func hashed(_ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: (UInt64(i) &* 0x9E37_79B9_7F4A_7C15) >> 56) }
    private func pixels(_ w: Int, _ h: Int, _ channels: Int, _ f: (Int, Int, Int) -> UInt8) -> Data {
        Data((0..<h).flatMap { y in (0..<w).flatMap { x in (0..<channels).map { f(x, y, $0) } } })
    }

    private let title = PNGTextEntry(keyword: "Title", value: "kit title")
    private let description = PNGTextEntry(keyword: "Description", value: "{\"unit\":\"nm\",\"scale\":0.25}")
    private let comment = PNGTextEntry(keyword: "Comment", value: "caf\u{E9} \u{B5}m \u{2713}")

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(FormatoPNG.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(FormatoPNG.crc32([UInt8]()) == 0)
        #expect(FormatoPNG.crc32(Array("IEND".utf8)) == 0xAE42_6082)       // the CRC every PNG's IEND chunk carries
    }

    @Test func insertionEqualsTheFirstConsumersBytes() throws {
        let entries = [PNGTextEntry(keyword: "Title", value: "oracle title"), PNGTextEntry(keyword: "Software", value: "macTEM oracle 1.0"),
                       PNGTextEntry(keyword: "Description", value: "{\"width\":4,\"height\":3,\"unit\":\"nm\"}"),
                       PNGTextEntry(keyword: "Comment", value: "caf\u{E9} \u{B5}m \u{2713}"), PNGTextEntry(keyword: "Empty", value: "")]
        let made = try FormatoPNG.inserting(entries, into: try fixture("input.png"))
        #expect(made == (try fixture("mactem-inserted.png")))
        #expect(try FormatoPNG.textEntries(in: made) == entries)
        // The input's own chunks are kept, in order, and nothing is added with no entries.
        #expect(try FormatoPNG.inserting([], into: try fixture("input.png")) == (try fixture("input.png")))
    }

    @Test func textRoundTripsAndKeywordsAreChecked() throws {
        let png = try FormatoPNG.encode(width: 2, height: 2, format: .gray8, pixels: Data([1, 2, 3, 4]),
                                        text: [title, comment, PNGTextEntry(keyword: "a b", value: "line\nbreak")])
        #expect(try FormatoPNG.textEntries(in: png) == [title, comment, PNGTextEntry(keyword: "a b", value: "line\nbreak")])
        for bad in ["", " lead", "trail ", "two  spaces", String(repeating: "k", count: 80), "nul\0", "t\u{E9}\u{263A}", "tab\t"] {
            #expect(throws: PNGError.invalidKeyword(bad)) {
                _ = try FormatoPNG.encode(width: 1, height: 1, format: .gray8, pixels: Data([0]), text: [PNGTextEntry(keyword: bad, value: "v")])
            }
        }
        // Latin-1 keywords are fine (the chunk stores one byte per character).
        let latin = try FormatoPNG.encode(width: 1, height: 1, format: .gray8, pixels: Data([0]), text: [PNGTextEntry(keyword: "caf\u{E9}", value: "v")])
        #expect(try FormatoPNG.textEntries(in: latin) == [PNGTextEntry(keyword: "caf\u{E9}", value: "v")])
    }

    @Test func malformedInputIsRefusedByName() throws {
        #expect(throws: PNGError.notPNG) { _ = try FormatoPNG.inserting([title], into: Data("not a png at all".utf8)) }
        #expect(throws: PNGError.notPNG) { _ = try FormatoPNG.textEntries(in: Data()) }
        let png = try fixture("input.png")
        #expect(throws: PNGError.self) { _ = try FormatoPNG.inserting([title], into: png.prefix(png.count - 40)) }       // IDAT cut off
        var corrupted = try FormatoPNG.inserting([title], into: png)
        corrupted[corrupted.count - 30] ^= 0xFF                                                                          // a byte inside a chunk
        #expect(throws: PNGError.self) { _ = try FormatoPNG.textEntries(in: corrupted) }
        #expect(throws: PNGError.self) { _ = try FormatoPNG.textEntries(in: png.prefix(png.count - 12)) }                 // no IEND
        #expect(throws: PNGError.invalidImage("3 bytes for 2 x 2 gray8")) {
            _ = try FormatoPNG.encode(width: 2, height: 2, format: .gray8, pixels: Data([1, 2, 3]))
        }
        #expect(throws: PNGError.self) { _ = try FormatoPNG.encode(width: 0, height: 2, format: .gray8, pixels: Data()) }
        #expect(throws: PNGError.self) { _ = try FormatoPNG.encode(width: 70_000, height: 1, format: .gray8, pixels: Data(count: 70_000)) }
    }

    @Test func slicesTruncationAndLargeStoredStreams() throws {
        let png = try fixture("input.png")
        // A slice that does not start at index 0 reads as the same PNG.
        let padded = Data(repeating: 7, count: 5) + png
        let slice = padded.dropFirst(5)
        #expect(slice.startIndex == 5)
        #expect(try FormatoPNG.inserting([title], into: slice) == (try FormatoPNG.inserting([title], into: png)))
        #expect(try FormatoPNG.textEntries(in: slice) == [])
        // A cut partway into the IDAT is refused, not inserted into.
        let idat = png.range(of: Data("IDAT".utf8))!.lowerBound
        #expect(throws: PNGError.self) { _ = try FormatoPNG.inserting([title], into: png.prefix(idat + 6)) }
        // A hostile chunk length is refused.
        var hostile = png
        hostile.replaceSubrange((idat - 4)..<idat, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: PNGError.self) { _ = try FormatoPNG.inserting([title], into: hostile) }
        #expect(throws: PNGError.self) { _ = try FormatoPNG.textEntries(in: hostile) }
        // A NUL in a value is refused.
        #expect(throws: PNGError.self) { _ = try FormatoPNG.inserting([PNGTextEntry(keyword: "K", value: "a\0b")], into: png) }
        // Stored blocks over 65 535 bytes decompress to the input (Compression's raw deflate inflates them).
        for count in [0, 1, 65_535, 65_536, 140_000] {
            let raw = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            let stream = FormatoPNG.zlibStored(raw)
            #expect(stream.prefix(2) == [0x78, 0x01])
            let body = Array(stream.dropFirst(2).dropLast(4))
            var out = [UInt8](repeating: 0, count: count + 16)
            let n = body.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB) } }
            #expect(n == count && Array(out.prefix(n)) == raw, "stored \(count)")
        }
    }

    @Test func encoderOutputIsStructurallyAPNG() throws {
        let png = try FormatoPNG.encode(width: 3, height: 2, format: .rgba8, pixels: pixels(3, 2, 4, b8), text: [title])
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(png.suffix(12)) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        // IHDR is the first chunk: 13 bytes, width 3, height 2, depth 8, colour type 6.
        #expect(Array(png[8..<29]) == [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 3, 0, 0, 0, 2, 8, 6, 0, 0, 0])
    }

    // MARK: Files for Pillow and zlib

    @Test func writtenFilesAreTheOnesPillowAndZlibChecked() throws {
        let folder = ProcessInfo.processInfo.environment["FORMATO_PNG_FIXTURE_DIR"]
        let dir = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if folder == nil { try? FileManager.default.removeItem(at: dir) } }
        let gray16 = Data((0..<3).flatMap { y in (0..<6).flatMap { x -> [UInt8] in let v = g16(x, y); return [UInt8(v & 0xFF), UInt8(v >> 8)] } })
        let hashedPixels = pixels(64, 48, 3) { x, y, c in hashed((y * 64 + x) * 3 + c) }
        let large = pixels(700, 300, 3) { x, y, c in b8(x / 3, y / 3, c) }
        let files: [(String, Data)] = [
            ("swift-gray8.png", try FormatoPNG.encode(width: 5, height: 4, format: .gray8, pixels: pixels(5, 4, 1) { x, y, _ in b8(x, y, 0) }, text: [title, description])),
            ("swift-gray16.png", try FormatoPNG.encode(width: 6, height: 3, format: .gray16, pixels: gray16)),
            ("swift-rgb8.png", try FormatoPNG.encode(width: 4, height: 3, format: .rgb8, pixels: pixels(4, 3, 3, b8), text: [title, description, comment])),
            ("swift-rgba8.png", try FormatoPNG.encode(width: 3, height: 2, format: .rgba8, pixels: pixels(3, 2, 4, b8), text: [PNGTextEntry(keyword: "Software", value: "FormatoKit test")])),
            ("swift-rgb8-hashed.png", try FormatoPNG.encode(width: 64, height: 48, format: .rgb8, pixels: hashedPixels)),
            ("swift-rgb8-stored.png", try FormatoPNG.encode(width: 64, height: 48, format: .rgb8, pixels: hashedPixels,
                                                             text: [PNGTextEntry(keyword: "Title", value: "stored blocks")], zlib: FormatoPNG.zlibStored)),
            ("swift-rgb8-large.png", try FormatoPNG.encode(width: 700, height: 300, format: .rgb8, pixels: large)),
        ]
        for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
        // Compressed where it can be; the stored form is bigger than the pixels, the compressed large image far smaller.
        #expect(files[6].1.count < large.count / 4)
        #expect(files[5].1.count > hashedPixels.count)
        // And the committed copy is what check.py read.
        if folder != nil { return }
        let result = try JSONSerialization.jsonObject(with: fixture("check-result.json")) as! [String: Any]
        #expect((result["pillow_version"] as? String) == "12.3.0")
        let entries = result["files"] as! [String: [String: Any]]
        #expect(Set(entries.keys) == Set(files.map(\.0)).union(["mactem-inserted.png"]))
        for (name, entry) in entries {
            let digest = SHA256.hash(data: try fixture(name)).map { String(format: "%02x", $0) }.joined()
            #expect(entry["sha256"] as? String == digest, "\(name) changed after check.py ran: rerun it")
            let checks = entry["checks"] as! [String: Bool]
            #expect(Set(checks.keys) == ["crc_valid", "ihdr_equal", "pixels_equal", "idat_equal", "text_equal"], "\(name)")
            for (key, value) in checks { #expect(value, "\(name): \(key)") }
        }
        // The stored-block file is deterministic (our own deflate framing), so today's output is the committed file byte for
        // byte. The compressed ones depend on the Compression framework's encoder and are pinned by their SHA-256 above only.
        #expect(try fixture("swift-rgb8-stored.png") == files[5].1)
    }
}
