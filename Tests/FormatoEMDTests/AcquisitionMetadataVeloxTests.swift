//
//  AcquisitionMetadataVeloxTests.swift
//  AcquisitionMetadata.velox against RosettaSciIO 049e7d70 `emd` mapping (the default convention) and the consumer's reader
//  (`.app`, compiled unchanged from macTEM cb6e164), on a Velox file written by tools/acq-metadata/generate.py.
//

import Foundation
import Testing
import FormatoAcquisitionPins
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
            #expect(Self.cases.count == 3)
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
                var ref = c.reference
                ref["microscope"] = nil   // InstrumentClass: not exposed by VeloxMetadata (see parity.md)
                #expect(referenceDifferences(m, ref, strict: ["beam_energy", "camera_length", "magnification"]) == [],
                        "\(c.name)")
                #expect(m.unread.isEmpty)
            }
        }

        @Test func testTheFieldsTheKitNowExposesAreRead() throws {
            let entries = try Self.entries()
            let ceta = AcquisitionMetadata.velox(try #require(entries["ceta"]), timeZone: Self.utc)
            // StemMagnification "0" is returned as stored (RosettaSciIO's float); the camera's exposure is the detector the image names.
            #expect(ceta.magnification == MetadataReading(0))
            #expect(ceta.exposureS == MetadataReading(0.5, note: AcquisitionMetadata.unvalidatedNote))
            #expect(ceta.mode?.value == "1")
            #expect(ceta.cameraLengthMM == MetadataReading(844.0))
            #expect(ceta.instrument == MetadataReading("Talos F200X", note: "unvalidated: no published reader reads it"))   // RosettaSciIO maps InstrumentClass ("Talos")
            #expect(ceta.dwellUS == nil)   // an ImagingDetector's image carries the scan settings too, but no dwell
            let haadf = AcquisitionMetadata.velox(try #require(entries["haadf"]), timeZone: Self.utc)
            #expect(haadf.dwellUS?.value == 10 && haadf.magnification == MetadataReading(225000.0))
            // Stored zeros: 0 in the reference, not recorded under rule (b).
            let zeros = try #require(entries["zeros"])
            #expect(AcquisitionMetadata.velox(zeros, timeZone: Self.utc).highTensionKV == MetadataReading(0))
            #expect(AcquisitionMetadata.velox(zeros, timeZone: Self.utc, convention: .app).highTensionKV == nil)
        }

        @Test func testTheDetectorTypeFollowsTheIndexAndTheImagesOwnName() throws {
            let entries = try Self.entries()
            #expect(entries["ceta"]?.detectorType == "ImagingDetector")
            #expect(entries["haadf"]?.detectorType == "ScanningDetector")
            #expect(entries["ceta"]?.resolvedDetector?.name == "BM-Ceta")
        }
    }
}
