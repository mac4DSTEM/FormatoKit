//
//  AcquisitionMetadataVeloxTests.swift
//  AcquisitionMetadata.velox against RosettaSciIO 049e7d70 `emd` mapping (the default convention) and the consumer's reader
//  (`.app`, compiled unchanged from macTEM cb6e164), on a Velox file written by tools/acq-metadata/generate.py.
//

import Foundation
import Testing
import FormatoKitTestSupport
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    @Suite struct AcquisitionMetadataVeloxTests {
        static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/acq-metadata")
        static let cases = (try? loadAcquisitionPins(fixtures.appendingPathComponent("acq-pins.json"))) ?? []
        static let utc = TimeZone(identifier: "UTC")!

        static func entries() throws -> [String: VeloxImageInfo] {
            let images = try VeloxEMDReader(path: fixtures.appendingPathComponent("velox-acquisition.emd").path).images()
            return Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        }

        @Test func testAppConventionEqualsTheConsumersOutput() throws {
            #expect(Self.cases.count == 4)
            let entries = try Self.entries()
            for c in Self.cases {
                let m = AcquisitionMetadata.velox(try #require(entries[c.name]), timeZone: Self.utc, convention: .app)
                #expect(appDifferences(m, c.app) == [], "\(c.name)")
            }
        }

        @Test func testDefaultConventionEqualsRosettaSciIO() throws {
            let entries = try Self.entries()
            for c in Self.cases {
                let m = AcquisitionMetadata.velox(try #require(entries[c.name]), timeZone: Self.utc)
                #expect(referenceDifferences(m, c.reference, strict: ["beam_energy", "camera_length", "magnification", "microscope"]) == [],
                        "\(c.name)")
                #expect(m.unread.isEmpty)
            }
        }

        @Test func testTheFieldsTheKitNowExposesAreRead() throws {
            let entries = try Self.entries()
            let ceta = AcquisitionMetadata.velox(try #require(entries["ceta"]), timeZone: Self.utc)
            // StemMagnification "0" is returned as stored (RosettaSciIO's float); the camera's exposure is the detector the image names.
            #expect(ceta.magnification == MetadataReading(0))
            #expect(ceta.exposureS == MetadataReading(0.5, note: "no published reader reads this field; read as stored in the Velox metadata"))
            #expect(ceta.mode?.value == "1")
            #expect(ceta.cameraLengthMM == MetadataReading(844.0))
            // RosettaSciIO's microscope is InstrumentClass ("Talos"); the stored model is kept beside it, labelled.
            #expect(ceta.instrument == MetadataReading("Talos"))
            #expect(ceta.instrumentModel == MetadataReading("Talos F200X", note: "no published reader reads this field; read as stored in the Velox metadata"))
            #expect(AcquisitionMetadata.velox(try #require(entries["ceta"]), timeZone: Self.utc, convention: .app).instrument
                    == MetadataReading("Talos F200X", note: "no published reader reads this field; read as stored in the Velox metadata"))
            #expect(ceta.dwellUS == nil)   // an ImagingDetector's image carries the scan settings too, but no dwell
            let haadf = AcquisitionMetadata.velox(try #require(entries["haadf"]), timeZone: Self.utc)
            #expect(haadf.dwellUS?.value == 10 && haadf.magnification == MetadataReading(225000.0))
            // Stored zeros: 0 in the reference, not recorded under rule (b).
            let zeros = try #require(entries["zeros"])
            #expect(AcquisitionMetadata.velox(zeros, timeZone: Self.utc).highTensionKV == MetadataReading(0))
            #expect(AcquisitionMetadata.velox(zeros, timeZone: Self.utc, convention: .app).highTensionKV == nil)
        }

        @Test func testTheStageIsReadAsRosettaSciIORoundsIt() throws {
            let entries = try Self.entries()
            let haadf = AcquisitionMetadata.velox(try #require(entries["haadf"]), timeZone: Self.utc)
            #expect(haadf.stageTiltAlphaDeg?.value == 5.0 && haadf.stageTiltBetaDeg?.value == -1.0)
            #expect(haadf.stageX?.value == 0.000123 && haadf.stageY?.value == -5.6e-05 && haadf.stageZ?.value == 2e-06)
            #expect(haadf.stageX?.note == "metres as stored, rounded to 6 decimals, as RosettaSciIO")
            // Each coordinate is read alone, as RosettaSciIO maps it.
            let partial = AcquisitionMetadata.velox(try #require(entries["partial-stage"]), timeZone: Self.utc)
            #expect(partial.stageX?.value == 2.5e-05 && partial.stageY == nil && partial.stageZ?.value == -1e-06)
            // An image with no Stage group reads none; the `.app` convention reads none of the 0.3.1 fields.
            let ceta = AcquisitionMetadata.velox(try #require(entries["ceta"]), timeZone: Self.utc)
            #expect(ceta.stageTiltAlphaDeg == nil && ceta.stageX == nil)
            let app = AcquisitionMetadata.velox(try #require(entries["haadf"]), timeZone: Self.utc, convention: .app)
            #expect(app.stageTiltAlphaDeg == nil && app.stageX == nil && app.instrumentModel == nil)
        }

        @Test func testTheDetectorTypeFollowsTheIndexAndTheImagesOwnName() throws {
            let entries = try Self.entries()
            #expect(entries["ceta"]?.detectorType == "ImagingDetector")
            #expect(entries["haadf"]?.detectorType == "ScanningDetector")
            #expect(entries["ceta"]?.resolvedDetector?.name == "BM-Ceta")
        }

        @Test func testPixelSizeWithoutPixelUnitXKeepsAnEmptyUnitLikeRosettaSciIO() throws {
            // RosettaSciIO reads `.get("PixelUnitX", "")`: the scale is kept and the unit is "" (tools/acq-metadata/no_unit.py).
            let path = Self.fixtures.appendingPathComponent("velox-no-unit.emd").path
            let pin = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("velox-no-unit.pin.json")))
            let axes = try #require((pin as? [String: Any])?["axes"] as? [[[String: Any]]])
            let images = try VeloxEMDReader(path: path).images()
            #expect(images.count == axes.count && !images.isEmpty)
            for image in images {
                let m = AcquisitionMetadata.velox(image, timeZone: Self.utc)
                let size = try #require(m.pixelSize?.value, Comment(rawValue: image.id))
                #expect(size == PixelSize(rows: 2e-10, columns: 2e-10, units: ""), Comment(rawValue: image.id))
            }
            for pair in axes {
                #expect(pair.allSatisfy { ($0["units"] as? String) == "" && ($0["scale"] as? Double) == 2e-10 })
            }
        }
    }
}
