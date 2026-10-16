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
        #expect(Self.cases.count == 31)
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

    @Test func testTheStageBeamCurrentOperatorAndEELSAnglesAreRead() throws {
        func ref(_ name: String) throws -> AcquisitionMetadata {
            let c = try #require(Self.cases.first { $0.name == name })
            return AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings)
        }
        let full = try ref("stage-beam-operator")
        #expect(full.stageTiltAlphaDeg == MetadataReading(12.5) && full.stageTiltBetaDeg == MetadataReading(-3.25))
        #expect(full.stageX?.value == 1.2345 && full.stageY?.value == -0.06725 && full.stageZ?.value == 0.008125)
        #expect(full.stageX?.note == "stored value × 1e-3, as RosettaSciIO")
        #expect(full.beamCurrentNA == MetadataReading(0.125))
        #expect(full.sampleDescription == MetadataReading("FIB lamella 3"))
        #expect(full.operatorName == MetadataReading("P. Operator "))   // untrimmed, as RosettaSciIO
        let sem = try ref("sem-stage")
        #expect(sem.stageTiltAlphaDeg?.value == 30 && sem.operatorName == nil)   // an empty operator maps nothing
        // EELS angles need an EELS signal; the angle tags alone map nothing.
        #expect(try ref("eels-angles").collectionAngleMrad?.value == 20 && (try ref("eels-angles")).convergenceAngleMrad?.value == 30)
        #expect(try ref("eels-orsay").collectionAngleMrad?.value == 25)
        #expect(try ref("angles-without-eels-signal").collectionAngleMrad == nil)
        // A stack-builder image: the values come from the copy, the EELS gate from the direct tags.
        let stack = try ref("stack-stage")
        #expect(stack.stageTiltAlphaDeg?.value == 7.5 && stack.operatorName?.value == "Stack Op" && stack.collectionAngleMrad?.value == 11)
        // The consumer's convention reads none of them.
        let c = try #require(Self.cases.first { $0.name == "stage-beam-operator" })
        let app = AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings, convention: .app)
        #expect(app.stageX == nil && app.beamCurrentNA == nil && app.operatorName == nil)
    }

    @Test func testTheEELSGroupIsReadAndItsDateOverridesTheDataBar() throws {
        let c = try #require(Self.cases.first { $0.name == "eels-full" })
        let m = AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings)
        #expect(m.signalNumbers["Detector.EELS.frame_number"]?.value == 4 && m.signalNumbers["Detector.EELS.aperture_size"]?.value == 2.5)
        #expect(m.signalTexts["Detector.EELS.spectrometer"]?.value == "GIF Quantum")
        #expect(m.acquired?.value == "2016-08-08 16:26:37")   // the EELS stamp wins over the DataBar one, as the mapping order has it
        let bad = try #require(Self.cases.first { $0.name == "eels-aperture-unparseable" })
        let b = AcquisitionMetadata.dm(numbers: bad.numbers, strings: bad.strings)
        #expect(b.signalNumbers["Detector.EELS.aperture_size"] == nil && b.signalTexts["Detector.EELS.spectrometer"]?.value == "")
    }

    @Test func testTheEDSGroupIsReadOnlyForAnXraySignal() throws {
        let c = try #require(Self.cases.first { $0.name == "eds-full" })
        let m = AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings)
        #expect(m.signalNumbers["Detector.EDS.live_time"]?.value == 118.5 && m.signalNumbers["Detector.EDS.real_time"]?.value == 120.25)
        #expect(m.signalNumbers["Detector.EDS.azimuth_angle"]?.value == 45 && m.signalNumbers["Detector.EDS.solid_angle"]?.value == 0.7)
        #expect(m.acquired?.value == "2016-08-27 20:54:33" && m.dwellUS == nil)
        // A text value is kept as a text, as RosettaSciIO's `None` mapping keeps it.
        let t = try #require(Self.cases.first { $0.name == "eds-text-values" })
        let text = AcquisitionMetadata.dm(numbers: t.numbers, strings: t.strings)
        #expect(text.signalTexts["Detector.EDS.live_time"]?.value == "12 s" && text.signalTexts["Detector.EDS.solid_angle"]?.value == "")
        // The same tags in an image (no X-ray signal) map nothing.
        var strings = c.strings; strings["Meta Data.Signal"] = nil
        #expect(AcquisitionMetadata.dm(numbers: c.numbers, strings: strings).signalNumbers.isEmpty)
    }

    @Test func testTheCLAndSIGroupsAreRead() throws {
        func ref(_ name: String) throws -> AcquisitionMetadata {
            let c = try #require(Self.cases.first { $0.name == name })
            return AcquisitionMetadata.dm(numbers: c.numbers, strings: c.strings)
        }
        let p = try ref("cl-parallel")
        #expect(p.signalTexts["Detector.detector_type"]?.value == "CCD" && p.signalTexts["Signal.format"]?.value == "Spectrum")
        // The CL dispersion grating replaces Monarc's text grating; the integration time is the exposure times the frames.
        #expect(p.signalNumbers["Spectrometer.Grating.groove_density"]?.value == 300 && p.signalNumbers["Detector.integration_time"]?.value == 4)
        #expect(p.acquired?.value == "2016-08-27 20:54:33")
        let s = try ref("cl-serial")
        #expect(s.signalTexts["Detector.detector_type"]?.value == "PMT" && s.signalNumbers["Detector.integration_time"]?.value == 0.002)
        #expect(s.signalNumbers["Spectrometer.Grating.groove_density"] == nil)   // "bad" does not parse
        #expect(s.dwellUS?.value == 15)   // CL maps the DigiScan sample time as the dwell
        #expect(try ref("cl-other-mode").signalTexts["Detector.detector_type"] == nil)
        let si = try ref("si-group")
        #expect(si.signalTexts.isEmpty && si.acquired?.value == "2021-01-02 10:11:12")   // the SI group maps its date and time for any image
        #expect(p.signalTexts["Spectrum_image.mode"]?.value == "Spectrum Imaging")
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
