//
//  CameraPixelPitchTests.swift
//  `AcquisitionMetadata.cameraPixelPitch` from a DM image object: the camera's own pixel pitch as GMS records it in
//  `Acquisition.Device.CCD.Pixel Size (um)`, a struct of two numbers (x, y). Not the binned frame pixel
//  (`Acquisition.Frame.CCD.Pixel Size (um)`, 2000 x 20 on the MonoCL file, 364 x 14 on EELS_SI), not the specimen pixel.
//
//  PUBLIC API ONLY (no @testable): a consumer sees only `public`.
//
//  TRUTH.
//   - rsciio-MonoCL_spectrum-ccd.dm4 and rsciio-MonarcCL_spectrum-ccd.dm4 are RosettaSciIO's public
//     digitalmicrograph/1D/test-MonoCL_spectrum-ccd.dm4 and test-MonarcCL_spectrum-ccd.dm4, copied unchanged (fetched at
//     8363d24; the same bytes and mapping line at the pinned 049e7d70). RosettaSciIO's
//     own tests (test_read_MonoCL_ccd_metadata, test_read_MonarcCL_ccd_metadata) assert
//     `Acquisition_instrument.Detector.pixel_size == 20.0`, which its mapping takes from that tag (x[0] when x[0] == x[1]).
//   - rsciio-EELS_SI.dm4 (a Gatan US1000 behind an EELS spectrometer) stores (14.0, 14.0): RosettaSciIO maps the tag for CL
//     only, so the value here is the tag as stored, read by RosettaSciIO 049e7d70's parser.
//   - Planted streams, built byte by byte below: an unequal pair, an absent tag, a zero, and a struct of three numbers.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM

@Suite struct CameraPixelPitchTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// The first object of `file` that is not a thumbnail.
    private static func object(_ file: String) throws -> DM4ImageObject {
        let objects = try DM4Experiment.list(path: fixtures.appendingPathComponent(file).path)
        return try #require(objects.first { $0.role != .thumbnail })
    }

    private static let um20 = PixelSize(rows: 20, columns: 20, units: "um")

    @Test(arguments: ["rsciio-MonoCL_spectrum-ccd.dm4", "rsciio-MonarcCL_spectrum-ccd.dm4"])
    func theCLFilesRecord20Micrometres(file: String) throws {
        let object = try Self.object(file)
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            let meta = AcquisitionMetadata.dm(object, convention: convention)
            #expect(meta.cameraPixelPitch?.value == Self.um20, "\(file) \(convention)")
            #expect(meta.cameraPixelPitch?.note == nil)
        }
        // RosettaSciIO's own assertion: Detector.pixel_size == 20.0 for a CL signal.
        let reference = AcquisitionMetadata.dm(object, convention: .rosettaSciIO)
        #expect(reference.signalNumbers["Detector.pixel_size"]?.value == 20.0, "\(file)")
        #expect(reference.signalTexts["Detector.pixel_size"] == nil)
        // The scalar maps do not carry the two-number tag.
        let scalarOnly = AcquisitionMetadata.dm(numbers: object.imageTagNumbers, strings: object.imageTagStrings)
        #expect(scalarOnly.cameraPixelPitch == nil)
    }

    @Test func theEELSCameraRecords14MicrometresAndNoCLKey() throws {
        let object = try Self.object("rsciio-EELS_SI.dm4")
        let meta = AcquisitionMetadata.dm(object)
        #expect(meta.cameraPixelPitch?.value == PixelSize(rows: 14, columns: 14, units: "um"))
        #expect(meta.cameraPixelPitch?.note == AcquisitionMetadata.unvalidatedNote, "not mapped by RosettaSciIO outside CL")
        #expect(meta.signalNumbers["Detector.pixel_size"] == nil, "RosettaSciIO maps the tag for CL only")
        let app = AcquisitionMetadata.dm(object, convention: .app)
        #expect(app.cameraPixelPitch?.value == PixelSize(rows: 14, columns: 14, units: "um"))
        #expect(app.cameraPixelPitch?.note == nil)
    }

    // MARK: Planted

    private enum Node {
        case floats(String, [Float])          // a struct (type 15) of float32 fields
        case int(String, Int32)
        case text(String, String)             // a ushort (UTF-16) array
        case group(String, [Node])
        case blob(String, bytes: [UInt8])
    }

    private static func u16be(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u64be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }
    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] { [tag] + u16be(label.utf8.count) + Array(label.utf8) + u64be(0) }
    private static let delim: [UInt8] = [37, 37, 37, 37]

    private static func encode(_ node: Node) -> [UInt8] {
        switch node {
        case .floats(let l, let values):
            // [15, name length 0, field count, (field name length 0, type 6) per field], then the float32 values.
            var info: [UInt64] = [15, 0, UInt64(values.count)]
            for _ in values { info += [0, 6] }
            let infoBytes: [UInt8] = info.flatMap { u64be($0) }
            let valueBytes: [UInt8] = values.flatMap { le(UInt64($0.bitPattern), 4) }
            return head(21, l) + delim + u64be(UInt64(info.count)) + infoBytes + valueBytes
        case .int(let l, let v):
            return head(21, l) + delim + u64be(1) + u64be(3) + le(UInt64(UInt32(bitPattern: v)), 4)
        case .text(let l, let s):
            let units = Array(s.utf16)
            let unitBytes: [UInt8] = units.flatMap { le(UInt64($0), 2) }
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(4) + u64be(UInt64(units.count)) + unitBytes
        case .group(let l, let kids):
            return head(20, l) + [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        case .blob(let l, let bytes):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(10) + u64be(UInt64(bytes.count)) + bytes
        }
    }

    /// A version-4 file with one 2 x 2 uint8 image whose ImageTags are `tags`.
    private static func file(tags: [Node]) throws -> DM4ImageObject {
        let dims: [Node] = [.int("", 2), .int("", 2)]
        let image: [Node] = [.group("ImageData", [.blob("Data", bytes: [1, 2, 3, 4]), .int("DataType", 6), .group("Dimensions", dims)]),
                             .group("ImageTags", tags)]
        let root: [Node] = [.group("ImageList", [.group("", image)])]
        let body: [UInt8] = [1, 0] + u64be(UInt64(root.count)) + root.flatMap(encode)
        let objects = try DM4Experiment.list(data: Data([0, 0, 0, 4] + u64be(0) + [0, 0, 0, 1] + body))
        return try #require(objects.first)
    }

    private static func device(_ values: [Float], signal: String? = nil) -> [Node] {
        var tags: [Node] = [.group("Acquisition", [.group("Device", [.group("CCD", [.floats("Pixel Size (um)", values)])])])]
        if let signal { tags.append(.group("Meta Data", [.text("Signal", signal)])) }
        return tags
    }

    @Test func anUnequalPairIsColumnsThenRowsAndSaysSo() throws {
        let object = try Self.file(tags: Self.device([20, 25], signal: "CL"))
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            let meta = AcquisitionMetadata.dm(object, convention: convention)
            #expect(meta.cameraPixelPitch?.value == PixelSize(rows: 25, columns: 20, units: "um"), "\(convention)")
            #expect(meta.cameraPixelPitch?.note == AcquisitionMetadata.unequalPitchNote, "\(convention)")
            // RosettaSciIO keeps an unequal pair as a tuple, which a number cannot hold.
            #expect(meta.signalNumbers["Detector.pixel_size"] == nil)
        }
    }

    /// RosettaSciIO compares only the first two of a longer tuple (`x[0] == x[1]`); a pitch needs exactly two.
    @Test func aThreeNumberStructGivesTheCLKeyButNoPitch() throws {
        let meta = AcquisitionMetadata.dm(try Self.file(tags: Self.device([15, 15, 7], signal: "CL")))
        #expect(meta.signalNumbers["Detector.pixel_size"]?.value == 15)
        #expect(meta.cameraPixelPitch == nil)
    }

    /// A stack-builder image: `.rosettaSciIO` reads the `source.Tags at creation` copy INSTEAD of the direct tags; `.app` reads
    /// the direct key, else the copy, and never replaces a present key from the copy.
    @Test func theStackBuilderCopyFollowsEachConvention() throws {
        func pitch(_ values: [Float]) -> Node {
            .group("Acquisition", [.group("Device", [.group("CCD", [.floats("Pixel Size (um)", values)])])])
        }
        func copy(_ values: [Float]) -> Node {
            .group("source", [.group("Tags at creation", [.int("Marker", 1), pitch(values)])])
        }
        let um15 = PixelSize(rows: 15, columns: 15, units: "um"), um20 = PixelSize(rows: 20, columns: 20, units: "um")
        let signal: Node = .group("Meta Data", [.text("Signal", "CL")])

        let both = try Self.file(tags: [pitch([20, 20]), copy([15, 15]), signal])
        let reference = AcquisitionMetadata.dm(both, convention: .rosettaSciIO)
        #expect(reference.cameraPixelPitch?.value == um15)
        #expect(reference.signalNumbers["Detector.pixel_size"]?.value == 15)
        #expect(AcquisitionMetadata.dm(both, convention: .app).cameraPixelPitch?.value == um20)

        let copyOnly = try Self.file(tags: [copy([15, 15])])
        #expect(AcquisitionMetadata.dm(copyOnly, convention: .app).cameraPixelPitch?.value == um15)
        #expect(AcquisitionMetadata.dm(copyOnly, convention: .rosettaSciIO).cameraPixelPitch?.value == um15)

        let invalidDirect = try Self.file(tags: [pitch([0, 0]), copy([15, 15])])
        #expect(AcquisitionMetadata.dm(invalidDirect, convention: .app).cameraPixelPitch == nil)

        let directOnly = try Self.file(tags: [pitch([20, 20]), .group("source", [.group("Tags at creation", [.int("Marker", 1)])])])
        #expect(AcquisitionMetadata.dm(directOnly, convention: .rosettaSciIO).cameraPixelPitch == nil)
    }

    @Test func theFramePixelIsNotThePitch() throws {
        let frame: [Node] = [.group("Acquisition", [.group("Frame", [.group("CCD", [.floats("Pixel Size (um)", [2000, 20])])])])]
        #expect(AcquisitionMetadata.dm(try Self.file(tags: frame)).cameraPixelPitch == nil)
    }

    @Test func absentZeroAndMalformedAreNil() throws {
        #expect(AcquisitionMetadata.dm(try Self.file(tags: [.int("Other", 1)])).cameraPixelPitch == nil)
        for values: [Float] in [[0, 0], [20, -1], [.nan, 20], [.infinity, 20], [20], [20, 20, 20]] {
            let meta = AcquisitionMetadata.dm(try Self.file(tags: Self.device(values)))
            #expect(meta.cameraPixelPitch == nil, "\(values)")
        }
    }

    @Test func aPlantedSquarePitchOutsideCLHasNoCLKey() throws {
        let meta = AcquisitionMetadata.dm(try Self.file(tags: Self.device([15, 15])))
        #expect(meta.cameraPixelPitch?.value == PixelSize(rows: 15, columns: 15, units: "um"))
        #expect(meta.cameraPixelPitch?.note == AcquisitionMetadata.unvalidatedNote)
        #expect(meta.signalNumbers["Detector.pixel_size"] == nil)
        let cl = AcquisitionMetadata.dm(try Self.file(tags: Self.device([15, 15], signal: "CL")))
        #expect(cl.signalNumbers["Detector.pixel_size"]?.value == 15)
    }
}
