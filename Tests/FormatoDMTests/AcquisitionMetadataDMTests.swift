//
//  AcquisitionMetadataDMTests.swift
//  AcquisitionMetadata.dm against RosettaSciIO 049e7d70 (the default convention) and the consumer's own readers
//  (`.app`), on synthetic DM4 files written byte by byte by tools/acq-metadata/generate.py. The pins are RosettaSciIO's
//  returned mapping applied as HyperSpy applies it, and the consumer's source (macTEM cb6e164) compiled unchanged.
//

import Foundation
import Testing
import FormatoAcquisitionPins
import FormatoCore
import FormatoDM

@Suite struct AcquisitionMetadataDMTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/acq-metadata")
    static let cases = (try? loadAcquisitionPins(fixtures.appendingPathComponent("pins.json"))) ?? []

    /// The generator hands the consumer's readers its own tag maps; they must be what the kit's walker returns for the file.
    @Test func testTheKitsTagMapsAreTheMapsThePinsWereMadeFrom() throws {
        #expect(Self.cases.count == 12)
        for c in Self.cases {
            let object = try #require(try DM4Experiment.list(path: Self.fixtures.appendingPathComponent(c.name + ".dm4").path).first)
            #expect(object.imageTagNumbers == c.numbers, "\(c.name)")
            #expect(object.imageTagStrings == c.strings, "\(c.name)")
        }
    }

    @Test func testAppConventionEqualsTheConsumersOutput() {
        for c in Self.cases {
            let m = AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings, convention: .app)
            #expect(appDifferences(m, c.app) == [], "\(c.name)")
        }
    }

    @Test func testDefaultConventionEqualsRosettaSciIO() throws {
        // dateutil guesses any layout; the kit reads the DM layouts only, so a form it does not read stays nil.
        let unreadByTheKit: Set<String> = ["unparseable-date"]
        for c in Self.cases {
            let m = AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings)
            var strict: Set<String> = ["beam_energy", "camera_length", "magnification", "dwell_time", "exposure", "acquisition_mode",
                                       "microscope"]
            var ref = c.reference
            if unreadByTheKit.contains(c.name) { ref["General.date"] = nil; ref["General.time"] = nil } else { strict.insert("stamp") }
            #expect(referenceDifferences(m, ref, strict: strict) == [], "\(c.name)")
        }
        let unparseable = try #require(Self.cases.first { $0.name == "unparseable-date" })
        #expect(AcquisitionMetadata.dm(numbers: unparseable.numbers, strings: unparseable.strings).acquired == nil)
    }

    @Test func testFromAnObjectEqualsFromItsMaps() throws {
        let object = try #require(try DM4Experiment.list(path: Self.fixtures.appendingPathComponent("stem.dm4").path).first)
        for convention in [AcquisitionMetadataConvention.rosettaSciIO, .app] {
            #expect(AcquisitionMetadata.dm(object, convention: convention)
                    == AcquisitionMetadata.dm(numbers: object.imageTagNumbers, strings: object.imageTagStrings, convention: convention))
        }
    }

    // MARK: Named differences, typed as literals

    @Test func testTheTwoConventionsDisagreeWhereDocumented() throws {
        func both(_ name: String) throws -> (reference: AcquisitionMetadata, app: AcquisitionMetadata) {
            let c = try #require(Self.cases.first { $0.name == name })
            return (AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings),
                    AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings, convention: .app))
        }
        // A stack-builder image is read from its copy instead of the direct tags (RosettaSciIO), or the copy fills gaps (app).
        let stack = try both("stack-builder")
        #expect(stack.reference.highTensionKV?.value == 200 && stack.app.highTensionKV?.value == 100)
        #expect(stack.reference.cameraLengthMM?.value == 100 && stack.app.cameraLengthMM == nil)
        // Zero and negative quantities are stored as read (RosettaSciIO) or not recorded (rule b).
        let zeros = try both("zeros")
        #expect(zeros.reference.highTensionKV?.value == 0 && zeros.app.highTensionKV == nil)
        #expect(zeros.reference.dwellUS?.value == 0 && zeros.app.dwellUS == nil)
        #expect(try both("negative-voltage").reference.highTensionKV?.value == -200)
        // A STEM camera length is mapped in any mode but TEM, SEM included; the mode is reduced to STEM / SEM / TEM.
        let sem = try both("sem")
        #expect(sem.reference.cameraLengthMM?.value == 0 && sem.app.cameraLengthMM == nil)
        #expect(sem.reference.mode?.value == "SEM")
        #expect(try both("stem").reference.mode?.value == "STEM" && (try both("stem")).app.mode?.value == "STEM NANOPROBE · IMAGING")
        // The exposure of a file with DigiScan tags is not read by RosettaSciIO; the app also keeps a second copy.
        let stem = try both("stem")
        #expect(stem.reference.exposureS == nil && stem.app.exposureS?.value == 0.5)
        let tem = try both("tem-image")
        #expect(tem.app.exposureS?.otherCopy == 0.26 && tem.reference.exposureS?.otherCopy == nil)
        // An instrument name is kept untrimmed by RosettaSciIO; the app trims it first (a blank one passes to the next location).
        let names = try both("whitespace-names")
        #expect(names.reference.instrument?.value == "  " && names.app.instrument?.value == "Titan")
        // The detector is mapped by neither RosettaSciIO nor the app's reference: labelled in both conventions' defaults.
        #expect(tem.reference.detector == MetadataReading("K2", note: AcquisitionMetadata.unvalidatedNote))
        // The ambiguous day/month order is named in the note.
        let ambiguous = try both("ambiguous-date")
        #expect(ambiguous.reference.acquired?.value == "2021-03-04 00:00:00")
        #expect(ambiguous.reference.acquired?.note == "local time, zone not stored; month-first order assumed")
    }
}
