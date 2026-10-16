//
//  AcquisitionMetadataMRCTests.swift
//  AcquisitionMetadata.mrc against RosettaSciIO 049e7d70 `mrc` (the default convention: the 128-byte per-section FEI header)
//  and the consumer's reader of the FEI1/FEI2 extended-header record (`.app`), on files written by tools/acq-metadata/generate.py.
//

import Foundation
import Testing
import FormatoAcquisitionPins
import FormatoCore
import FormatoMRC

@Suite struct AcquisitionMetadataMRCTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/acq-metadata")
    static let cases = (try? loadAcquisitionPins(fixtures.appendingPathComponent("pins.json"))) ?? []
    static func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".mrc")) }

    @Test func testAppConventionEqualsTheConsumersOutput() throws {
        #expect(Self.cases.count == 5)
        for c in Self.cases {
            let m = try AcquisitionMetadata.mrc(data: Self.data(c.name), convention: .app)
            #expect(appDifferences(m, c.app) == [], "\(c.name)")
        }
    }

    @Test func testDefaultConventionEqualsRosettaSciIO() throws {
        for c in Self.cases {
            let m = try AcquisitionMetadata.mrc(data: Self.data(c.name))
            #expect(referenceDifferences(m, c.reference, strict: ["magnification", "exposure"]) == [], "\(c.name)")
            // RosettaSciIO maps nothing else: no other field is read.
            var rest = m
            rest.magnification = nil; rest.exposureS = nil
            rest.stageTiltAlphaDeg = nil; rest.stageTiltBetaDeg = nil; rest.stageX = nil; rest.stageY = nil; rest.stageZ = nil
            #expect(rest.isEmpty, "\(c.name)")
        }
    }

    @Test func testTheFirstSectionOfAnFEI128HeaderIsRead() throws {
        // Section 0 holds exp_time 0.3 f4 and magnification 14500 f4; section 1 holds 9 and 99 (RosettaSciIO keeps both as arrays).
        let m = try AcquisitionMetadata.mrc(data: Self.data("fei-128-sections"))
        #expect(m.magnification == MetadataReading(14500.0))
        #expect(m.exposureS == MetadataReading(Double(Float(0.3))))
        // The stage of section 0 (float32 as stored): the tilts in degrees, the position unconverted.
        #expect(m.stageTiltAlphaDeg?.value == 12.5 && m.stageTiltBetaDeg?.value == -3.25)
        #expect(m.stageX?.value == 0x1p-13 && m.stageY?.value == -0x1p-12 && m.stageZ?.value == 0x1p-15)
        // The machine stamp is ignored, as RosettaSciIO ignores it (little-endian default).
        #expect(try AcquisitionMetadata.mrc(data: Self.data("fei-128-big-endian-stamp")) == m)
    }

    @Test func testAnFEI2RecordIsReadOnlyUnderTheAppConvention() throws {
        let data = try Self.data("fei2-all-set")
        #expect(try AcquisitionMetadata.mrc(data: data).isEmpty)
        let m = try AcquisitionMetadata.mrc(data: data, convention: .app)
        #expect(m.highTensionKV == MetadataReading(300.0))
        #expect(m.cameraLengthMM?.value == 844 && m.cameraLengthMM?.note == "unvalidated: the mode is not checked")
        #expect(m.detector?.value == "Ceta" && m.instrument?.value == "Talos F200X" && m.dwellUS?.value == 10)
        #expect(m.acquired?.value == "2022-12-05 13:13:07")
    }

    @Test func testNotAnMRCHeaderThrows() {
        #expect(throws: MRCError.self) { try AcquisitionMetadata.mrc(data: Data(count: 100)) }
        #expect(throws: MRCError.self) { try AcquisitionMetadata.mrc(data: Data(count: 100), convention: .app) }
        #expect(throws: MRCError.self) { try AcquisitionMetadata.mrc(data: Data(count: 2048), convention: .app) }
        #expect(throws: FormatoReadError.self) { try AcquisitionMetadata.mrc(path: "/nonexistent/none.mrc") }
    }
}
