//
//  TIFFCameraPixelPitchTests.swift
//  `AcquisitionMetadata.cameraPixelPitch` from a GMS-saved TIFF: the DM tag stream of private tag 65027 carries the same
//  `Acquisition.Device.CCD.Pixel Size (um)` struct as a .dm3/.dm4 image object, and the TIFF reader reads it by the same
//  rules as `AcquisitionMetadata.dm(_:)`.
//
//  PUBLIC API ONLY (no @testable): a consumer sees only `public`.
//
//  TRUTH.
//   - `FormatoDMTests/Fixtures/dm-tag65027-saved-with-DM.dm4` is tag 65027 of RosettaSciIO's public
//     `tiff/test_loading_image_saved_with_DM.tif` (a Gatan UltraScan, BM-UltraScan), sliced out byte for byte. It stores
//     the device pixel size as (14.0, 14.0). RosettaSciIO 049e7d70 `tiff/_api.py` does not parse tag 65027 at all (it reads
//     only the DM scale, unit and intensity tags 65003-65025), so no published reader gives this value for a TIFF: the reading is
//     "the pitch when the file records it", the same field and rules as the DM reader.
//   - Planted bare streams, built byte by byte below: a CL signal (RosettaSciIO's `Detector.pixel_size` rule), an unequal
//     pair, the frame pixel alone.
//   - Each TIFF is a minimal 1 x 1 uint8 page built here with the stream as a BYTE tag 65027.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM
import FormatoTIFF

@Suite struct TIFFCameraPixelPitchTests {
    private static let stream = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FormatoDMTests/Fixtures/dm-tag65027-saved-with-DM.dm4")

    private static let um14 = PixelSize(rows: 14, columns: 14, units: "um")

    // MARK: A minimal TIFF

    /// A little-endian TIFF with one 1 x 1 uint8 page whose tag 65027 is `stream` (type 1, BYTE).
    private static func tiff(stream: Data) -> Data {
        // Entries, sorted by code: width, length, bits, strip offsets, rows per strip, strip byte counts, 65027.
        let entryCount = 7
        let ifdEnd = 8 + 2 + entryCount * 12 + 4
        let pixelAt = ifdEnd, streamAt = ifdEnd + 4
        var d = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func short(_ code: Int, _ v: Int) { u16(code); u16(3); u32(1); u16(v); u16(0) }
        func long(_ code: Int, _ v: Int) { u16(code); u16(4); u32(1); u32(v) }
        u16(entryCount)
        long(256, 1); long(257, 1); short(258, 8); long(273, pixelAt); long(278, 1); long(279, 1)
        u16(65027); u16(1); u32(stream.count); u32(streamAt)
        u32(0)
        d.append(contentsOf: [7, 0, 0, 0])   // the pixel, padded to a word
        d.append(stream)
        return d
    }

    // MARK: A planted bare DM stream (root group = the image's ImageTags)

    private enum Node {
        case floats(String, [Float])          // a struct (type 15) of float32 fields
        case text(String, String)             // a ushort (UTF-16) array
        case group(String, [Node])
    }

    private static func u16be(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u64be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }
    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] { [tag] + u16be(label.utf8.count) + Array(label.utf8) + u64be(0) }
    private static let delim: [UInt8] = [37, 37, 37, 37]

    private static func encode(_ node: Node) -> [UInt8] {
        switch node {
        case .floats(let l, let values):
            var info: [UInt64] = [15, 0, UInt64(values.count)]
            for _ in values { info += [0, 6] }
            return head(21, l) + delim + u64be(UInt64(info.count)) + info.flatMap { u64be($0) }
                + values.flatMap { le(UInt64($0.bitPattern), 4) }
        case .text(let l, let s):
            let units = Array(s.utf16)
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(4) + u64be(UInt64(units.count))
                + units.flatMap { le(UInt64($0), 2) }
        case .group(let l, let kids):
            return head(20, l) + [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        }
    }

    /// A version-4 bare tag stream whose root group holds `tags`.
    private static func bareStream(_ tags: [Node]) -> Data {
        Data([0, 0, 0, 4] + u64be(0) + [0, 0, 0, 1] + [1, 0] + u64be(UInt64(tags.count)) + tags.flatMap(encode))
    }

    private static func ccd(_ group: String, _ values: [Float]) -> Node {
        .group("Acquisition", [.group(group, [.group("CCD", [.floats("Pixel Size (um)", values)])])])
    }

    private static func signal(_ s: String) -> Node { .group("Meta Data", [.text("Signal", s)]) }

    // MARK: Tests

    @Test func theDMSavedTIFFRecords14Micrometres() throws {
        let data = Self.tiff(stream: try Data(contentsOf: Self.stream))
        let reference = try AcquisitionMetadata.tiff(data: data)
        #expect(reference.cameraPixelPitch?.value == Self.um14)
        // Not a CL signal: RosettaSciIO maps the tag for CL only (and reads no tag 65027), so `.rosettaSciIO` labels it.
        #expect(reference.cameraPixelPitch?.note == "no published reader reads this field; read as stored in the DM image tags")
        #expect(reference.signalNumbers["Detector.pixel_size"] == nil)
        let app = try AcquisitionMetadata.tiff(data: data, convention: .app)
        #expect(app.cameraPixelPitch?.value == Self.um14)
        #expect(app.cameraPixelPitch?.note == nil)
        // The other values of the stream are unchanged by the pitch: the TIFF still reads its 200 kV.
        #expect(reference.highTensionKV?.value == 200)
    }

    @Test func aCLStreamGivesTheReferenceKeyAndAnUnlabelledPitch() throws {
        let data = Self.tiff(stream: Self.bareStream([Self.ccd("Device", [20, 20]), Self.signal("CL")]))
        let reference = try AcquisitionMetadata.tiff(data: data)
        #expect(reference.cameraPixelPitch == MetadataReading(PixelSize(rows: 20, columns: 20, units: "um")))
        #expect(reference.signalNumbers["Detector.pixel_size"]?.value == 20)
        let app = try AcquisitionMetadata.tiff(data: data, convention: .app)
        #expect(app.cameraPixelPitch == MetadataReading(PixelSize(rows: 20, columns: 20, units: "um")))
        #expect(app.signalNumbers["Detector.pixel_size"] == nil)
    }

    @Test func anUnequalPairIsColumnsThenRowsAndSaysSo() throws {
        let data = Self.tiff(stream: Self.bareStream([Self.ccd("Device", [20, 25])]))
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            let meta = try AcquisitionMetadata.tiff(data: data, convention: convention)
            #expect(meta.cameraPixelPitch?.value == PixelSize(rows: 25, columns: 20, units: "um"), "\(convention)")
            #expect(meta.cameraPixelPitch?.note?.hasPrefix(AcquisitionMetadata.unequalPitchNote) == true, "\(convention)")
        }
    }

    @Test func theFramePixelAloneIsNoPitch() throws {
        let data = Self.tiff(stream: Self.bareStream([Self.ccd("Frame", [2000, 20])]))
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            #expect(try AcquisitionMetadata.tiff(data: data, convention: convention).cameraPixelPitch == nil)
        }
    }

    /// The TIFF path and the DM path agree field for field on the same stream.
    @Test func theTIFFReadingEqualsTheDMReadingOfTheSameStream() throws {
        let stream = try Data(contentsOf: Self.stream)
        let tree = try DM4Experiment.tagTree(data: stream)
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            var expected = AcquisitionMetadata.dm(numbers: tree.numbers, strings: tree.strings, convention: convention)
            expected.cameraPixelPitch = convention == .app ? MetadataReading(Self.um14)
                                                           : MetadataReading(Self.um14, note: "no published reader reads this field; read as stored in the DM image tags")
            #expect(try AcquisitionMetadata.tiff(data: Self.tiff(stream: stream), convention: convention) == expected)
        }
    }
}
