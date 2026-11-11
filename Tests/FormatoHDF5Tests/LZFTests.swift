//
//  LZFTests.swift
//  h5py's LZF filter (HDF5 filter 32000), which the shipped libhdf5 lacks and the loader registers (LZFFilter.swift,
//  FormatoKit#86). The h5py-written fixture (tools/hdf5-lzf/generate.py, Fixtures/lzf) reads exactly as h5py reads it, whole and
//  as a slab: EBSD-like patterns, partial edge chunks, shuffle, Fletcher-32, a constant chunk (the longest back references,
//  overlapping their own output) and a chunk h5py stored uncompressed. The planted Velox file with an LZF stream reads to
//  RosettaSciIO's pinned data. The decoder on hand-made streams, with liblzf's refusals; the filter callback's buffer rules
//  (h5py's lzf_filter.c).
//  Red before: every read of an LZF dataset ("required filter 'lzf' is not registered"), and LZF and LZFFilter, which did not
//  exist.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD
import FormatoHDF5

struct LZFTests {
    struct Pins: Decodable {
        struct Slab: Decodable { var start: [Int]; var count: [Int]; var sha256: String }
        struct Dataset: Decodable {
            var shape: [Int]; var dtype: String; var sha256: String; var slab: Slab
            var filters: [Int]; var lzfValues: [Int]; var chunks: Int; var rawChunks: Int
        }
        var datasets: [String: Dataset]
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lzf")

    @Test func testTheH5pyLZFFileReadsAsH5pyReadsIt() throws {
        let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: Self.folder.appendingPathComponent("pins.json")))
        #expect(pins.datasets.count == 6)
        #expect(pins.datasets.values.allSatisfy { $0.filters.contains(Int(LZFFilter.id)) })
        #expect(pins.datasets.values.map(\.rawChunks).reduce(0, +) == 1, "one chunk h5py stored as is: HDF5 skips the filter for it")
        let reader = try HDF5Reader(url: Self.folder.appendingPathComponent("lzf.h5"))
        for (path, pin) in pins.datasets.sorted(by: { $0.key < $1.key }) {
            let info = try reader.datasetInfo(path)
            #expect(info.shape == pin.shape, "\(path): shape")
            #expect(try reader.chunkShape(of: path) != nil, "\(path): chunked")
            let whole = try reader.readDataset(path)
            #expect(whole.dataType.rawValue == pin.dtype, "\(path): type")
            #expect(whole.shape == pin.shape, "\(path): shape read")
            #expect(sha256Hex(whole.bytes) == pin.sha256, "\(path): data")
            let slab = try reader.readDataset(path, start: pin.slab.start, count: pin.slab.count)
            #expect(slab.shape == pin.slab.count, "\(path): slab shape")
            #expect(sha256Hex(slab.bytes) == pin.slab.sha256, "\(path): slab data")
        }
    }

    /// The step-4 review file `stream-lzf.emd` (tools/velox-spectrum-image/refuter_pins.py), whose spectrum stream h5py wrote
    /// with LZF: the signal RosettaSciIO reads through h5py, by type, shape and data (the parity pins compare every field).
    @Test func testTheVeloxFileWithAnLZFStreamReadsAsRosettaSciIOReadsIt() throws {
        let url = Self.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FormatoEMDTests/Fixtures/velox-spectrum-image/refuter/stream-lzf.emd")
        let signals = try VeloxSpectrumImageSignals(path: url.path).signals
        #expect(signals.count == 1)
        let eds = try #require(signals.first)
        #expect(eds.signalType == "EDS_TEM")
        #expect(eds.data.dataType == .uint16)
        #expect(eds.data.shape == [3, 4, 16])
        #expect(sha256Hex(eds.data.bytes) == "dcd035dce06bf3b601d23d14478031bdf1fa393c2285929ecd31100f3617b520")
    }

    // MARK: The decoder

    static func decode(_ stream: [UInt8], capacity: Int) -> (LZF.Outcome, [UInt8]) {
        var output = [UInt8](repeating: 0, count: capacity)
        let outcome = stream.withUnsafeBytes { input in output.withUnsafeMutableBytes { LZF.decompress(input, into: $0) } }
        guard case .decoded(let count) = outcome else { return (outcome, []) }
        return (outcome, Array(output[..<count]))
    }

    /// Decodes `stream` into `capacity` bytes and expects `expected`.
    static func expectDecoded(_ stream: [UInt8], capacity: Int, _ expected: [UInt8], _ comment: Comment) {
        let (outcome, bytes) = decode(stream, capacity: capacity)
        #expect(outcome == .decoded(expected.count), comment)
        #expect(bytes == expected, comment)
        #expect(stream.withUnsafeBytes { LZF.decodedSize($0) } == expected.count, comment)
    }

    @Test func testTheDecoderReadsLiteralRunsAndBackReferences() {
        let abc: [UInt8] = Array("abc".utf8)
        Self.expectDecoded([2] + abc, capacity: 3, abc, "a literal run of three")
        Self.expectDecoded([2] + abc, capacity: 64, abc, "a larger output keeps its tail")
        Self.expectDecoded([2] + abc + [0x80, 2], capacity: 9, Array("abcabcabc".utf8), "a reference of six bytes three back")
        Self.expectDecoded([0, 0x61, 0xE0, 90, 0], capacity: 100, [UInt8](repeating: 0x61, count: 100),
                           "a long reference (7 + 90 + 2 bytes) one back, overlapping its own output")
        Self.expectDecoded([1, 0x61, 0x62, 0xE0, 255, 1], capacity: 300, Array(String(repeating: "ab", count: 133).utf8),
                           "the longest reference, 264 bytes two back")
    }

    @Test func testTheDecoderRefusesWhatLiblzfRefuses() {
        #expect(Self.decode([2, 0x61, 0x62, 0x63], capacity: 2).0 == .outputTooSmall, "E2BIG on a literal run")
        #expect(Self.decode([0, 0x61, 0x80, 0], capacity: 5).0 == .outputTooSmall, "E2BIG on a reference")
        let invalid: [(stream: [UInt8], comment: Comment)] = [
            ([0x80, 0], "a reference before the output's start"),
            ([5, 0x61], "a literal run past the input's end"),
            ([0, 0x61, 0x80], "a reference without its distance byte"),
            ([0, 0x61, 0xE0, 5], "a long reference without its distance byte"),
            ([], "nothing to decode"),
        ]
        for (stream, comment) in invalid {
            #expect(Self.decode(stream, capacity: 99).0 == .invalid, comment)
            #expect(stream.withUnsafeBytes { LZF.decodedSize($0) } == nil, comment)
        }
    }

    // MARK: The filter callback

    /// Runs the callback as HDF5 does: a `malloc`ed input buffer of `allocated` bytes holding `stream`.
    static func filter(_ stream: [UInt8], chunkBytes: Int?, allocated: Int? = nil, flags: UInt32 = LZFFilter.reverse)
        -> (returned: Int, size: Int, bytes: [UInt8]) {
        let allocated = allocated ?? stream.count
        let input = malloc(allocated)!
        stream.withUnsafeBytes { input.copyMemory(from: $0.baseAddress!, byteCount: stream.count) }
        var buffer: UnsafeMutableRawPointer? = input
        var size = allocated
        let returned = LZFFilter.decode(flags: flags, values: chunkBytes, inputCount: stream.count, bufferSize: &size, buffer: &buffer)
        defer { free(buffer) }
        let bytes = returned > 0 ? Array(UnsafeRawBufferPointer(start: buffer, count: returned)) : []
        if returned == 0 { #expect(buffer == input && size == allocated, "a failure leaves HDF5's buffer as it was") }
        return (returned, size, bytes)
    }

    @Test func testTheCallbackSizesItsOutputAsH5pyDoes() {
        let a100 = [UInt8](repeating: 0x61, count: 100), stream: [UInt8] = [0, 0x61, 0xE0, 90, 0]
        let exact = Self.filter(stream, chunkBytes: 100)
        #expect(exact.returned == 100 && exact.size == 100 && exact.bytes == a100, "cd_values[2], the chunk's size")
        let small = Self.filter(stream, chunkBytes: 10)
        #expect(small.returned == 100 && small.size == 100 && small.bytes == a100, "a guess too small: measured, then decoded")
        let none = Self.filter(stream, chunkBytes: nil, allocated: 64)
        #expect(none.returned == 100 && none.bytes == a100, "no cd_values[2]: the input buffer's size, then measured")
        let zero = Self.filter(stream, chunkBytes: 0, allocated: 128)
        #expect(zero.returned == 100 && zero.size == 128 && zero.bytes == a100, "a zero cd_values[2] is no guess")
        #expect(Self.filter([0x80, 0], chunkBytes: 100).returned == 0, "not an LZF stream")
        #expect(Self.filter(stream, chunkBytes: 100, flags: 0).returned == 0, "never encodes")
    }
}
