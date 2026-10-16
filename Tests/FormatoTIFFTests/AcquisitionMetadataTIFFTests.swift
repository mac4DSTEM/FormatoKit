//
//  AcquisitionMetadataTIFFTests.swift
//  AcquisitionMetadata.tiff: the FEI SEM INI against RosettaSciIO 049e7d70 `tiff` (`mapping_fei`), the Velox XML of tag
//  34683 against the Velox EMD mapping's lambdas (no RosettaSciIO plugin reads the tag), the DM tag stream of tag 65027
//  through `AcquisitionMetadata.dm`, and every convention against the consumer's reader (`.app`), compiled unchanged from
//  macTEM cb6e164. Files and pins: tools/acq-metadata/generate.py.
//

import Foundation
import Testing
import FormatoAcquisitionPins
import FormatoCore
import FormatoDM
import FormatoTIFF

@Suite struct AcquisitionMetadataTIFFTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/acq-metadata")
    static let cases = (try? loadAcquisitionPins(fixtures.appendingPathComponent("pins.json"))) ?? []
    static func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".tif")) }
    static func pin(_ name: String) throws -> AcquisitionPinCase { try #require(cases.first { $0.name == name }) }

    @Test func testAppConventionEqualsTheConsumersOutput() throws {
        #expect(Self.cases.count == 9)
        for c in Self.cases where c.name != "dm-tag-65027" {   // the harness has no DM walker: see the DM tag stream test
            let m = try AcquisitionMetadata.tiff(data: Self.data(c.name), convention: .app)
            #expect(appDifferences(m, c.app) == [], "\(c.name)")
        }
    }

    @Test func testDefaultConventionEqualsRosettaSciIOOnTheFEIIni() throws {
        for name in ["fei-helios", "fei-sfeg-zero", "fei-first-field-day"] {
            let c = try Self.pin(name)
            let m = try AcquisitionMetadata.tiff(data: Self.data(name))
            #expect(referenceDifferences(m, c.reference, strict: ["beam_energy", "dwell_time", "microscope", "stamp"]) == [], "\(name)")
            // [Detectors] Name is mapped by neither: labelled.
            #expect(m.detector == MetadataReading("ETD", note: AcquisitionMetadata.unvalidatedNote))
        }
        // A stored zero is 0 (RosettaSciIO), not recorded (rule b).
        let zero = try AcquisitionMetadata.tiff(data: Self.data("fei-sfeg-zero"))
        #expect(zero.highTensionKV?.value == 0 && zero.dwellUS?.value == 0)
        #expect(try AcquisitionMetadata.tiff(data: Self.data("fei-sfeg-zero"), convention: .app).highTensionKV == nil)
    }

    @Test func testDefaultConventionEqualsTheVeloxMappingOnTheXML() throws {
        for name in ["velox-ceta-imaging", "velox-diffraction-zero-voltage", "velox-stem", "velox-zone-designator"] {
            let c = try Self.pin(name)
            let m = try AcquisitionMetadata.tiff(data: Self.data(name))
            #expect(referenceDifferences(m, c.reference, strict: ["beam_energy", "camera_length"]) == [], "\(name)")
        }
        // Camera length: every mode (the mapping), against only a diffraction projector mode or STEM (rule c).
        let imaging = try Self.data("velox-ceta-imaging")
        #expect(try AcquisitionMetadata.tiff(data: imaging).cameraLengthMM?.value == 844)
        #expect(try AcquisitionMetadata.tiff(data: imaging, convention: .app).cameraLengthMM == nil)
        // The values RosettaSciIO does not map are read by the app's rules, labelled.
        let m = try AcquisitionMetadata.tiff(data: imaging)
        #expect(m.detector == MetadataReading("BM-Ceta", note: AcquisitionMetadata.unvalidatedNote))
        #expect(m.exposureS == MetadataReading(0.5, note: AcquisitionMetadata.unvalidatedNote))
        #expect(m.acquired?.value == "2026-06-05 13:05:07")
        // A zone designator is another quantity: not recorded.
        #expect(try AcquisitionMetadata.tiff(data: Self.data("velox-zone-designator")).acquired == nil)
    }

    @Test func testTheDMTagStreamGoesThroughTheDMReaderWithTheSameConvention() throws {
        let data = try Self.data("dm-tag-65027")
        let file = try TIFFFile(data: data)
        let stream = try #require(file.directories.first?[65027]).raw
        let tree = try DM4Experiment.tagTree(data: stream)
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            let viaTIFF = try AcquisitionMetadata.tiff(data: data, convention: convention)
            #expect(viaTIFF == AcquisitionMetadata.dm(numbers: tree.numbers, strings: tree.strings, convention: convention))
            #expect(viaTIFF.highTensionKV?.value == 300 && viaTIFF.magnification?.value == 50000)
        }
    }

    @Test func testAFileWithNoneOfTheConventionsIsEmptyAndANonTIFFThrows() throws {
        #expect(try AcquisitionMetadata.tiff(data: Self.data("plain")).isEmpty)
        #expect(throws: TIFFError.self) { try AcquisitionMetadata.tiff(data: Data(count: 64)) }
        #expect(try AcquisitionMetadata.tiff(path: Self.fixtures.appendingPathComponent("plain.tif").path).isEmpty)
    }
}
