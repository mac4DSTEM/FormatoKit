//
//  TIFFLZWTests.swift
//  LZW-compressed TIFF (Compression 5), as Gatan DigitalMicrograph and many SEMs write it (TIFFCompression.swift,
//  FormatoKit#90). The tifffile-written fixtures (tools/tiff-lzw/generate.py, Fixtures/lzw) read exactly as tifffile reads
//  them, through `TIFFSignals` and, for one grey page, `TIFFAppImage`: float32 over several strips, the horizontal predictor
//  on 8, 16 (both byte orders, signed) and 32-bit integers and on RGB, the floating-point predictor on float32 (both byte
//  orders) and float64, a noise image whose stream clears the code table seven times, a three-page stack. The decoder on
//  hand-made streams, and the refusals that stay.
//  Red before: every fixture ("The page is compressed (Compression 5); only uncompressed TIFF is read."), and
//  TIFFCompression, which did not exist.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

struct TIFFLZWTests {
    struct Pins: Decodable {
        struct File: Decodable {
            var shape: [Int]; var dtype: String; var sha256: String; var predictor: Int; var strips: Int
            var appFloat32Sha256: String?
        }
        var tifffile: String
        var files: [String: File]
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lzw")

    private func pins() throws -> Pins {
        try JSONDecoder().decode(Pins.self, from: Data(contentsOf: Self.folder.appendingPathComponent("pins.json")))
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static let types: [String: FormatoDataType] = [
        "uint8": .uint8, "uint16": .uint16, "uint32": .uint32, "int16": .int16, "float32": .float32, "float64": .float64,
    ]

    @Test func testEveryFixtureReadsAsTifffileReadsIt() throws {
        let pins = try pins()
        #expect(pins.tifffile == "2026.9.20")
        #expect(pins.files.count == 12)
        #expect(Set(pins.files.values.map(\.predictor)) == [1, 2, 3])
        for (name, pin) in pins.files.sorted(by: { $0.key < $1.key }) {
            let path = Self.folder.appendingPathComponent("\(name).tif").path
            let signal = try TIFFSignals(path: path).signal(series: 0).load()
            let data = signal.data
            if name.hasPrefix("rgb8") {
                // tifffile's (rows, columns, 3) uint8 is one rgb8 element a pixel here.
                #expect(data.dataType == .rgb8, "\(name)")
                #expect(data.shape + [3] == pin.shape, "\(name): shape")
            } else {
                #expect(data.dataType == Self.types[pin.dtype], "\(name): type")
                #expect(data.shape == pin.shape, "\(name): shape")
            }
            #expect(sha(data.bytes) == pin.sha256, "\(name): pixels")
        }
    }

    @Test func testAStackReadsSlabBySlab() throws {
        let path = Self.folder.appendingPathComponent("u16-stack.tif").path
        let tiff = try TIFFSignals(path: path)
        let whole = try tiff.signal(series: 0).load().data
        #expect(whole.shape == [3, 37, 53])
        // The written values: page k, row y, column x holds 100 x + y + 5000 k.
        let lazy = TIFFSeriesArray(path: path, series: tiff.series[0], shape: tiff.series[0].shape)
        let slab = try lazy.read(start: [1, 5, 10], count: [2, 3, 4])
        var want: [Double] = []
        for k in 1...2 { for y in 5..<8 { for x in 10..<14 { want.append(Double(100 * x + y + 5000 * k)) } } }
        #expect(slab.doubles() == want)
    }

    @Test func testOneGreyPageReadsThroughTIFFAppImageAsTifffileReadsIt() throws {
        for (name, pin) in try pins().files.sorted(by: { $0.key < $1.key }) {
            guard let want = pin.appFloat32Sha256 else { continue }
            let image = try TIFFAppImage.read(path: Self.folder.appendingPathComponent("\(name).tif").path)
            #expect([image.height, image.width] == pin.shape, "\(name): shape")
            let bytes = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            #expect(sha(bytes) == want, "\(name): pixels as float32")
        }
    }

    // MARK: - The decoder on hand-made streams

    /// Codes packed MSB first at the given widths.
    private func pack(_ codes: [(Int, Int)]) -> Data {
        var bits: [Bool] = []
        for (code, width) in codes {
            for k in stride(from: width - 1, through: 0, by: -1) { bits.append((code >> k) & 1 == 1) }
        }
        while bits.count % 8 != 0 { bits.append(false) }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for bit in bits[i..<(i + 8)] { byte = byte << 1 | (bit ? 1 : 0) }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    @Test func testTheDecoderBuildsItsTableAndReadsTheCodeNotYetInIt() throws {
        // Clear, 'a', 'b', 258 ("ab"), then 260, the code being defined by this very step ("ab" + its own first byte: the
        // KwKwK case), EOI: "a" "b" "ab" "aba".
        let stream = pack([(256, 9), (97, 9), (98, 9), (258, 9), (260, 9), (257, 9)])
        #expect(Array(try TIFFCompression.lzwDecode(stream, expected: 100)) == Array("abababa".utf8))
    }

    @Test func testTheDecoderStopsAtTheEndOfItsInputAndAtEOI() throws {
        let stream = pack([(256, 9), (65, 9), (66, 9), (257, 9), (67, 9)])
        #expect(Array(try TIFFCompression.lzwDecode(stream, expected: 10)) == Array("AB".utf8))
        let noEOI = pack([(256, 9), (65, 9), (66, 9)])
        #expect(Array(try TIFFCompression.lzwDecode(noEOI, expected: 10)) == Array("AB".utf8))
    }

    @Test func testACorruptOrOldStyleStreamIsRefusedInWords() {
        let undefined = pack([(256, 9), (65, 9), (300, 9)])
        let error = #expect(throws: TIFFCompression.Failure.self) { _ = try TIFFCompression.lzwDecode(undefined, expected: 10) }
        #expect(error?.reason.contains("corrupt") == true)
        let oldStyle = Data([0x00, 0x01, 0x02, 0x03])
        let old = #expect(throws: TIFFCompression.Failure.self) { _ = try TIFFCompression.lzwDecode(oldStyle, expected: 10) }
        #expect(old?.reason.contains("old-style") == true)
    }

    @Test func testPredictorsAreReadOnlyOnTheSamplesTheyApplyTo() {
        #expect(TIFFCompression.predictorRefusal(1, format: 3, bytes: 4) == nil)
        #expect(TIFFCompression.predictorRefusal(2, format: 1, bytes: 2) == nil)
        #expect(TIFFCompression.predictorRefusal(2, format: 3, bytes: 4) != nil)
        #expect(TIFFCompression.predictorRefusal(3, format: 3, bytes: 4) == nil)
        #expect(TIFFCompression.predictorRefusal(3, format: 1, bytes: 2) != nil)
        #expect(TIFFCompression.predictorRefusal(4, format: 1, bytes: 1) != nil)
    }
}
