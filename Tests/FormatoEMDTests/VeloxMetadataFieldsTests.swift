//
//  VeloxMetadataFieldsTests.swift
//  Role: Pin the six `VeloxMetadata` fields SpectroKit 0.2.0 added (nominalMagnification, stemMagnification,
//        cameraLengthMeters, operatingMode, projectorMode, exposureTimeSeconds) and each `VeloxDetectorInfo`'s
//        `exposureTimeSeconds`: one rule per test, first on inline JSON (`VeloxMetadata.parse(jsonData:)`), then end
//        to end on a planted Velox file. The first five are macTEM's ask of 2026-10-13; `stemMagnification`, which is
//        `CustomProperties.StemMagnification.value` (what RosettaSciIO 049e7d70 maps as the magnification), is the
//        owner's sixth of 2026-10-14.
//
//  PUBLIC API ONLY, on purpose: this target shares package access, but macTEM is another package and sees only
//  `public`. Everything used below is `public` in SpectroCore (an external consumer compiles this file unchanged).
//
//  The expected values are literals typed here, from the rules (the doc comments on `VeloxMetadata`, RosettaSciIO
//  049e7d70 `_get_detector_metadata_dict`) and from tools/velox-metadata-parity/make_fixture.py, which plants them.
//  They are not read from velox-metadata-planted.truth.json and not computed by the reader.
//  Fixtures/velox-metadata-planted.emd is regenerated with
//  `References/python-venv/bin/python -I tools/velox-metadata-parity/make_fixture.py` (stdlib + h5py + numpy).
//
//  Each Data/Image group of the planted file has a 2-column Metadata. Column 0 holds the values below; column 1 is a
//  DECOY with a different value in every field, so a reader that takes the wrong column cannot pass.
//
//  Negative controls (SpectroKit 0.2.0): each edit below was applied alone to VeloxEMDReader.swift (49c6ef6) in a
//  scratch clone and turned at least one test red (M11 by a crash):
//    M1 exposure by `contains`; M2 exposure from `.last`; M3 the `!detectorName.isEmpty` guard removed; M4 `images()`
//    reading metadata column 1; M5 cameraLengthMeters reading NominalMagnification; M6 operatingMode via `jsonDouble`;
//    M7 stemMagnification reading Optics.NominalMagnification; M8 stemMagnification always nil; M9 the per-detector
//    exposureTimeSeconds dropped; M10 nominalMagnification reading the stem entry; M11 the `dict` helper force-casting
//    (a string CustomProperties crashes); M12 stem falling back to a bare-string entry; M13 stem `?? 0`; M14 stem from
//    strings only; M15 stem falling back to nominalMagnification; M16 stem 0 becoming nil; M17 stem string read as an
//    integer only; M18 exposure falling back to the first detector; M19 exposure from the first entry that has one;
//    M20 detector sort removed; M21 detector sort by index as text; M22 projectorMode reading OperatingMode; M23
//    `jsonDouble` ignoring JSON numbers; M24 `jsonDouble` reading 0 as nil; M25 stem read only when its "type" is
//    "double"; M26 stem falling back to a string CustomProperties; M27 nominalMagnification `?? 0`.
//  Gate B's findings (79295e8), each applied alone to VeloxEMDReader.swift:
//    M28 exposure by `BinaryResult.DetectorIndex` when present, else by name; M29 exposure falling back to the
//    DetectorIndex entry when no entry has the name; M30 the same when the named entry has no ExposureTime; M31
//    `jsonDouble` reading a JSON bool as nil; M32 the DetectorIndex fallback only when the named entry has no
//    ExposureTime; M33 the DetectorIndex entry's exposure preferred when it has one; M34 nil when the DetectorIndex
//    entry has no ExposureTime, else by name; M35 the DetectorIndex entry's exposure preferred when the named entry
//    has one too.
//

import Foundation
import XCTest
import FormatoCore
import FormatoEMD
import FormatoHDF5

final class VeloxMetadataFieldsTests: XCTestCase {

    private func parse(_ json: String) throws -> VeloxMetadata {
        try VeloxMetadata.parse(jsonData: Data(json.utf8))
    }

    // MARK: Inline JSON

    /// Velox stores every number as a string. All six, as stored, and each detector's own ExposureTime. A camera image
    /// carries both magnifications (RosettaSciIO's public '1854 Camera Ceta.emd': Nominal 8609.4, Stem "115000").
    func testStringsAsVeloxStoresThemAreRead() throws {
        let m = try parse(#"""
        {"Optics": {"AccelerationVoltage": "200000", "NominalMagnification": "8609.4279999999999",
                    "CameraLength": "0.125", "OperatingMode": "1", "ProjectorMode": "2"},
         "CustomProperties": {"StemMagnification": {"type": "double", "value": "115000"}},
         "BinaryResult": {"Detector": "BM-Ceta", "DetectorIndex": "1"},
         "Detectors": {
            "Detector-0": {"DetectorName": "BM-Ceta-2", "DetectorType": "ImagingDetector", "ExposureTime": "9"},
            "Detector-1": {"DetectorName": "BM-Ceta", "DetectorType": "ImagingDetector", "ExposureTime": "0.5"},
            "Detector-2": {"DetectorName": "BM-Ceta", "DetectorType": "ImagingDetector", "ExposureTime": "7"}}}
        """#)
        XCTAssertEqual(m.nominalMagnification, 8609.4279999999999)
        XCTAssertEqual(m.stemMagnification, 115000)
        XCTAssertEqual(m.cameraLengthMeters, 0.125, "metres as stored: no x1e3 to millimetres")
        XCTAssertEqual(m.operatingMode, "1", "the code as stored, a String")
        XCTAssertEqual(m.projectorMode, "2")
        XCTAssertEqual(m.exposureTimeSeconds, 0.5)
        XCTAssertEqual(m.binaryResultDetector, "BM-Ceta")
        XCTAssertEqual(m.detectors.map(\.exposureTimeSeconds), [9, 0.5, 7], "each entry keeps its own ExposureTime")
    }

    /// The two magnifications are different keys: each is read where it is, whether or not the other is there, and
    /// neither is a fallback for the other.
    func testNominalAndStemMagnificationAreReadIndependently() throws {
        let both = try parse(#"""
        {"Optics": {"NominalMagnification": "8609.4279999999999"},
         "CustomProperties": {"StemMagnification": {"type": "double", "value": "115000"}}}
        """#)
        XCTAssertEqual(both.nominalMagnification, 8609.4279999999999)
        XCTAssertEqual(both.stemMagnification, 115000)

        let onlyNominal = try parse(#"{"Optics": {"NominalMagnification": "8609.4279999999999"}}"#)
        XCTAssertEqual(onlyNominal.nominalMagnification, 8609.4279999999999)
        XCTAssertNil(onlyNominal.stemMagnification, "not a copy of the nominal magnification")

        let onlyStem = try parse(#"""
        {"Optics": {"CameraLength": "0.15"},
         "CustomProperties": {"StemMagnification": {"type": "double", "value": "225000"}}}
        """#)
        XCTAssertNil(onlyStem.nominalMagnification, "not a copy of the stem magnification")
        XCTAssertEqual(onlyStem.stemMagnification, 225000)
    }

    /// RosettaSciIO's `_get_detector_metadata_dict` compares with `==`. The energy axis uses `contains`; the exposure
    /// must not: "BM-Ceta-2" contains "BM-Ceta" and comes first (ExposureTime 9), and a later duplicate of the exact
    /// name has 7.
    func testExposureTakesTheFirstEqualNameNotTheFirstContainingName() throws {
        let m = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta-2", "ExposureTime": "9"},
                       "Detector-1": {"DetectorName": "BM-Ceta", "ExposureTime": "0.5"},
                       "Detector-2": {"DetectorName": "BM-Ceta", "ExposureTime": "7"}}}
        """#)
        XCTAssertEqual(m.exposureTimeSeconds, 0.5, "not 9 (contains), not 7 (the last duplicate)")

        let onlyContaining = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta-2", "ExposureTime": "9"}}}
        """#)
        XCTAssertNil(onlyContaining.exposureTimeSeconds, "a name that merely contains the detector's is not it")

        let wrongCase = try parse(#"""
        {"BinaryResult": {"Detector": "bm-ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "0.5"}}}
        """#)
        XCTAssertNil(wrongCase.exposureTimeSeconds, "== is case-sensitive, as rsciio's")
    }

    /// The exposure is looked up by NAME, never by `BinaryResult.DetectorIndex`. RosettaSciIO 049e7d70's public
    /// '1854 Camera Ceta.emd' has this shape: BinaryResult {"Detector": "BM-Ceta", "DetectorIndex": "0"}, Detector-0 is
    /// "BF" without an ExposureTime, and the camera is Detector-8 (ExposureTime "1").
    func testExposureIsByNameWhenTheDetectorIndexPointsAtAnEntryWithoutOne() throws {
        let m = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta", "DetectorIndex": "0"},
         "Detectors": {"Detector-0": {"DetectorName": "BF", "DetectorType": "ScanningDetector"},
                       "Detector-8": {"DetectorName": "BM-Ceta", "DetectorType": "ImagingDetector",
                                      "ExposureTime": "1"}}}
        """#)
        XCTAssertEqual(m.binaryResultDetectorIndex, 0, "the index is there, and it names BF")
        XCTAssertEqual(m.detectors.map(\.index), [0, 8])
        XCTAssertEqual(m.exposureTimeSeconds, 1, "the entry named BM-Ceta, not nil from Detector-0")
        XCTAssertEqual(m.detectors.map(\.exposureTimeSeconds), [nil, 1])
    }

    /// The same, where the indexed entry has an ExposureTime of its own: the named entry's value still wins.
    func testExposureIsByNameWhenTheDetectorIndexPointsAtAnEntryWithAnotherExposure() throws {
        let m = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta", "DetectorIndex": "0"},
         "Detectors": {"Detector-0": {"DetectorName": "BF", "DetectorType": "ImagingDetector", "ExposureTime": "7"},
                       "Detector-8": {"DetectorName": "BM-Ceta", "DetectorType": "ImagingDetector",
                                      "ExposureTime": "1"}}}
        """#)
        XCTAssertEqual(m.binaryResultDetectorIndex, 0)
        XCTAssertEqual(m.exposureTimeSeconds, 1, "not 7, the value of the entry the index names")
        XCTAssertEqual(m.detectors.map(\.exposureTimeSeconds), [7, 1])
    }

    /// `BinaryResult.DetectorIndex` is no fallback either: with no entry named BM-Ceta, or a named one without an
    /// ExposureTime, the exposure is nil though the indexed entry has one.
    func testTheDetectorIndexIsNoFallbackForTheExposure() throws {
        let noEntryNamed = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta", "DetectorIndex": "0"},
         "Detectors": {"Detector-0": {"DetectorName": "BF", "ExposureTime": "7"}}}
        """#)
        XCTAssertEqual(noEntryNamed.binaryResultDetectorIndex, 0)
        XCTAssertNil(noEntryNamed.exposureTimeSeconds, "no entry is named BM-Ceta; not 7 from Detector-0")

        let namedWithoutExposure = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta", "DetectorIndex": "0"},
         "Detectors": {"Detector-0": {"DetectorName": "BF", "ExposureTime": "7"},
                       "Detector-8": {"DetectorName": "BM-Ceta"}}}
        """#)
        XCTAssertNil(namedWithoutExposure.exposureTimeSeconds, "BM-Ceta has none; not 7 from Detector-0")
    }

    /// A STEM image: CameraLength and both modes, no Optics.NominalMagnification. CustomProperties.StemMagnification is
    /// its magnification and is NOT copied into nominalMagnification. The binary detector's entry (HAADF) has no
    /// ExposureTime, while another detector (BM-Ceta) has one: the exposure is nil.
    func testStemLikeImageHasStemMagnificationButNoNominalMagnificationAndNoExposure() throws {
        let m = try parse(#"""
        {"Optics": {"AccelerationVoltage": "200000", "CameraLength": "0.15", "OperatingMode": "1",
                    "ProjectorMode": "1"},
         "CustomProperties": {"StemMagnification": {"type": "double", "value": "225000"}},
         "BinaryResult": {"Detector": "HAADF", "DetectorIndex": "0"},
         "Detectors": {
            "Detector-0": {"DetectorName": "HAADF", "DetectorType": "ScanningDetector"},
            "Detector-1": {"DetectorName": "BM-Ceta", "DetectorType": "ImagingDetector", "ExposureTime": "0.5"}}}
        """#)
        XCTAssertEqual(m.stemMagnification, 225000)
        XCTAssertNil(m.nominalMagnification, "StemMagnification is another field and is not copied here")
        XCTAssertEqual(m.cameraLengthMeters, 0.15)
        XCTAssertEqual(m.operatingMode, "1")
        XCTAssertEqual(m.projectorMode, "1")
        XCTAssertNil(m.exposureTimeSeconds)
        XCTAssertEqual(m.detectors.map(\.exposureTimeSeconds), [nil, 0.5])
    }

    /// Numbers stored as JSON numbers are read, the stem magnification's value too. The two modes are strings as
    /// stored: a JSON number is nil, not "1". No CustomProperties: the stem magnification is nil beside a nominal one.
    func testJSONNumbersAreReadButTheModesMustBeStrings() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": 49000.5, "CameraLength": 0.0625, "OperatingMode": 1, "ProjectorMode": 2},
         "BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": 0.25}}}
        """#)
        XCTAssertEqual(m.nominalMagnification, 49000.5)
        XCTAssertNil(m.stemMagnification, "no CustomProperties, and not a copy of the nominal magnification")
        XCTAssertEqual(m.cameraLengthMeters, 0.0625)
        XCTAssertNil(m.operatingMode, "a JSON number is not a mode string")
        XCTAssertNil(m.projectorMode)
        XCTAssertEqual(m.exposureTimeSeconds, 0.25)
        XCTAssertEqual(m.detectors.first?.exposureTimeSeconds, 0.25)

        let stem = try parse(#"{"CustomProperties": {"StemMagnification": {"type": "double", "value": 62500.5}}}"#)
        XCTAssertEqual(stem.stemMagnification, 62500.5, "the value as a JSON number")
    }

    /// A JSON `true`/`false` is 1/0 in every numeric field, as Python's `float(True)` is 1.0 (RosettaSciIO's reading of
    /// a value stored as a bool); the string "true" is not a number.
    func testAJSONBoolIsOneOrZeroAsPythonsFloatReadsIt() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": true, "CameraLength": false},
         "CustomProperties": {"StemMagnification": {"type": "bool", "value": false}},
         "BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": true}}}
        """#)
        XCTAssertEqual(m.nominalMagnification, 1)
        XCTAssertEqual(m.cameraLengthMeters, 0)
        XCTAssertEqual(m.stemMagnification, 0)
        XCTAssertEqual(m.exposureTimeSeconds, 1)

        let text = try parse(#"{"Optics": {"CameraLength": "true"}}"#)
        XCTAssertNil(text.cameraLengthMeters, "the string \"true\" is not a number")
    }

    /// Not a number is nil ("", "abc", "n/a"); a JSON null is absent; a mode that is a string is kept as stored,
    /// whatever it says ("TEM", the name a Velox TIFF's XML holds).
    func testUnparsableValuesAreNilAndAModeStringIsKeptAsStored() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": "", "CameraLength": "abc", "OperatingMode": "TEM", "ProjectorMode": null},
         "CustomProperties": {"StemMagnification": {"type": "double", "value": "abc"}},
         "BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "n/a"}}}
        """#)
        XCTAssertNil(m.nominalMagnification)
        XCTAssertNil(m.stemMagnification)
        XCTAssertNil(m.cameraLengthMeters)
        XCTAssertEqual(m.operatingMode, "TEM")
        XCTAssertNil(m.projectorMode)
        XCTAssertNil(m.exposureTimeSeconds)

        let nullValue = try parse(#"{"CustomProperties": {"StemMagnification": {"type": "double", "value": null}}}"#)
        XCTAssertNil(nullValue.stemMagnification, "a JSON null is absent")
    }

    /// The exponent forms Velox files store are read, with the leading zeros a C runtime's `%e` writes: "1.3e+006" is
    /// 1300000, as RosettaSciIO's `float` reads it.
    func testScientificNotationAsStoredIsRead() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": "1e5", "CameraLength": "1.5e-1"},
         "CustomProperties": {"StemMagnification": {"type": "double", "value": "1.3e+006"}},
         "BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "2.5E-001"}}}
        """#)
        XCTAssertEqual(m.stemMagnification, 1300000)
        XCTAssertEqual(m.nominalMagnification, 100000)
        XCTAssertEqual(m.cameraLengthMeters, 0.15)
        XCTAssertEqual(m.exposureTimeSeconds, 0.25)
    }

    /// StemMagnification is there but has no "value" key: nil, though a nominal magnification is there to fall back on.
    func testStemMagnificationWithoutAValueKeyIsNil() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": "60000"}, "CustomProperties": {"StemMagnification": {"type": "double"}}}
        """#)
        XCTAssertNil(m.stemMagnification)
        XCTAssertEqual(m.nominalMagnification, 60000)
    }

    /// StemMagnification as a bare string, not the {"type", "value"} object Velox writes: nil, not 250000.
    func testStemMagnificationThatIsABareStringIsNil() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": "70000"}, "CustomProperties": {"StemMagnification": "250000"}}
        """#)
        XCTAssertNil(m.stemMagnification)
        XCTAssertEqual(m.nominalMagnification, 70000)
    }

    /// CustomProperties itself can be a string (RosettaSciIO checks `isinstance(om["CustomProperties"], str)`): then
    /// the stem magnification and the scan transformation are nil, a string is never read as the number, and the rest
    /// still parses.
    func testCustomPropertiesThatIsAStringReadsNothingAndBreaksNothing() throws {
        for custom in [#""""#, #""225000""#] {
            let m = try parse(#"""
            {"Optics": {"NominalMagnification": "80000", "CameraLength": "0.2", "OperatingMode": "2"},
             "CustomProperties": \#(custom),
             "BinaryResult": {"Detector": "BM-Ceta"},
             "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "1.25"}}}
            """#)
            XCTAssertNil(m.stemMagnification, "CustomProperties \(custom)")
            XCTAssertNil(m.scanTransformation, "CustomProperties \(custom)")
            XCTAssertEqual(m.nominalMagnification, 80000, "CustomProperties \(custom)")
            XCTAssertEqual(m.cameraLengthMeters, 0.2, "CustomProperties \(custom)")
            XCTAssertEqual(m.operatingMode, "2", "CustomProperties \(custom)")
            XCTAssertEqual(m.exposureTimeSeconds, 1.25, "CustomProperties \(custom)")
        }
    }

    /// A STEM file's CustomProperties holds many flat entries: the stem magnification and the scan transformation are
    /// each read from it, and an entry that is neither is ignored.
    func testStemMagnificationSitsBesideTheScanTransformationInCustomProperties() throws {
        let m = try parse(#"""
        {"CustomProperties": {"Detectors[BM-Ceta].TimeStamp": {"type": "double", "value": "1.6e+015"},
                              "Scan.ScanTransformation.A11": {"type": "double", "value": "1.5"},
                              "Scan.ScanTransformation.A12": {"type": "double", "value": "0.25"},
                              "Scan.ScanTransformation.A13": {"type": "double", "value": "2"},
                              "Scan.ScanTransformation.A21": {"type": "double", "value": "-0.25"},
                              "Scan.ScanTransformation.A22": {"type": "double", "value": "1.5"},
                              "Scan.ScanTransformation.A23": {"type": "double", "value": "-3"},
                              "StemMagnification": {"type": "double", "value": "225000"}}}
        """#)
        XCTAssertEqual(m.stemMagnification, 225000)
        let t = try XCTUnwrap(m.scanTransformation)
        XCTAssertEqual([t.a11, t.a12, t.a13, t.a21, t.a22, t.a23], [1.5, 0.25, 2, -0.25, 1.5, -3])
    }

    /// No BinaryResult.Detector, whether BinaryResult is there without it or absent altogether: nil, though a detector
    /// has an ExposureTime.
    func testExposureIsNilWhenBinaryResultNamesNoDetector() throws {
        let withoutKey = try parse(#"""
        {"BinaryResult": {"DetectorIndex": "0"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "0.5"}}}
        """#)
        XCTAssertNil(withoutKey.binaryResultDetector)
        XCTAssertNil(withoutKey.exposureTimeSeconds)

        let withoutSection = try parse(#"""
        {"Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "0.5"}}}
        """#)
        XCTAssertNil(withoutSection.exposureTimeSeconds)
        XCTAssertEqual(withoutSection.detectors.first?.exposureTimeSeconds, 0.5, "the entry still reports its own")
    }

    /// An empty BinaryResult.Detector names no detector. An entry without DetectorName is listed with the name "", so
    /// "" must not match it: its ExposureTime is not the binary detector's.
    func testAnEmptyBinaryDetectorMatchesNoEntryNotEvenAnUnnamedOne() throws {
        let m = try parse(#"""
        {"BinaryResult": {"Detector": ""},
         "Detectors": {"Detector-0": {"DetectorType": "ImagingDetector", "ExposureTime": "0.75"},
                       "Detector-1": {"DetectorName": "BM-Ceta", "ExposureTime": "0.5"}}}
        """#)
        XCTAssertEqual(m.binaryResultDetector, "")
        XCTAssertEqual(m.detectors.first?.name, "", "the unnamed entry is listed with an empty name")
        XCTAssertEqual(m.detectors.first?.exposureTimeSeconds, 0.75)
        XCTAssertNil(m.exposureTimeSeconds)
    }

    /// The FIRST entry of that name decides, as rsciio's loop returns it: it has no ExposureTime, so nil, though a
    /// later entry of the same name has one.
    func testTheFirstEntryOfTheNameDecidesEvenWithoutAnExposure() throws {
        let m = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta"},
                       "Detector-1": {"DetectorName": "BM-Ceta", "ExposureTime": "2"}}}
        """#)
        XCTAssertNil(m.exposureTimeSeconds, "not 2")
        XCTAssertEqual(m.detectors.map(\.exposureTimeSeconds), [nil, 2])
    }

    /// A JSON object has no order in Swift; "file order" is the Detector-<n> index, numerically. The keys are written
    /// in DESCENDING order here (11 ... 0): the first BM-Ceta is Detector-1 (ExposureTime 10), not the first key
    /// written.
    func testFirstMeansLowestDetectorIndexWhateverTheKeyOrder() throws {
        // Detector-0 is HAADF; Detector-1 ... Detector-11 are BM-Ceta with ExposureTime = index * 10.
        let entries = (0...11).reversed().map { i in
            i == 0 ? #""Detector-0": {"DetectorName": "HAADF"}"#
                   : #""Detector-\#(i)": {"DetectorName": "BM-Ceta", "ExposureTime": "\#(i * 10)"}"#
        }
        let detectors = entries.joined(separator: ", ")
        let m = try parse(#"{"BinaryResult": {"Detector": "BM-Ceta"}, "Detectors": {"# + detectors + "}}")
        XCTAssertEqual(m.detectors.map(\.index), Array(0...11), "sorted by index")
        XCTAssertEqual(m.exposureTimeSeconds, 10)
    }

    /// The index is a number, not text: Detector-10 comes after Detector-9 (text order would put "Detector-10" first).
    func testDetectorIndexOrderIsNumericNotTextual() throws {
        let m = try parse(#"""
        {"BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-11": {"DetectorName": "BM-Ceta", "ExposureTime": "11"},
                       "Detector-10": {"DetectorName": "BM-Ceta", "ExposureTime": "10"},
                       "Detector-9": {"DetectorName": "BM-Ceta", "ExposureTime": "9"},
                       "Detector-2": {"DetectorName": "HAADF"}}}
        """#)
        XCTAssertEqual(m.detectors.map(\.index), [2, 9, 10, 11])
        XCTAssertEqual(m.exposureTimeSeconds, 9)
    }

    /// Without an Optics section, a CustomProperties section or a Detectors section every new field is nil.
    func testNoOpticsSectionLeavesEveryNewFieldNil() throws {
        let m = try parse(#"{"BinaryResult": {"Detector": "BM-Ceta"}}"#)
        XCTAssertNil(m.nominalMagnification)
        XCTAssertNil(m.stemMagnification)
        XCTAssertNil(m.cameraLengthMeters)
        XCTAssertNil(m.operatingMode)
        XCTAssertNil(m.projectorMode)
        XCTAssertNil(m.exposureTimeSeconds, "no Detectors section")
    }

    /// Zero is a value, not an absence: "0" is 0.0 in every numeric field, and the mode "0" is the string "0". The stem
    /// magnification is stored as three of the four public camera images store it, {"type": "bool", "value": "0"}: the
    /// "type" is not consulted, the value is read as RosettaSciIO's `float` reads it.
    func testZeroIsAValueNotAnAbsence() throws {
        let m = try parse(#"""
        {"Optics": {"NominalMagnification": "0", "CameraLength": "0", "OperatingMode": "0", "ProjectorMode": "0"},
         "CustomProperties": {"StemMagnification": {"type": "bool", "value": "0"}},
         "BinaryResult": {"Detector": "BM-Ceta"},
         "Detectors": {"Detector-0": {"DetectorName": "BM-Ceta", "ExposureTime": "0"}}}
        """#)
        XCTAssertEqual(m.nominalMagnification, 0)
        XCTAssertEqual(m.stemMagnification, 0)
        XCTAssertEqual(m.cameraLengthMeters, 0)
        XCTAssertEqual(m.operatingMode, "0")
        XCTAssertEqual(m.projectorMode, "0")
        XCTAssertEqual(m.exposureTimeSeconds, 0)
    }

    // MARK: The planted file

    /// What column 0 of each planted image must give, typed by hand (make_fixture.py plants it).
    private struct Planted: Sendable {
        let id: String
        let binaryDetector: String?
        let magnification: Double?
        let stemMagnification: Double?
        let cameraLength: Double?
        let operatingMode: String?
        let projectorMode: String?
        let exposure: Double?
        /// `metadata.detectors[n].exposureTimeSeconds`, in Detector-<n> index order.
        let detectorExposures: [Double?]
        /// What column 1 (the decoy) holds: a different value in every field.
        let decoy: Decoy
    }

    private struct Decoy: Sendable {
        let magnification: Double
        let stemMagnification: Double
        let cameraLength: Double
        let operatingMode: String
        let projectorMode: String
        let exposure: Double
    }

    private static let planted: [Planted] = [
        // a: all six as strings, a camera image with both magnifications; the exact-name match is the FIRST of two
        // BM-Ceta, and "BM-Ceta-2" (contains) is before it.
        Planted(id: "case-a-ceta-strings", binaryDetector: "BM-Ceta", magnification: 8609.4279999999999,
                stemMagnification: 115000, cameraLength: 0.125, operatingMode: "1", projectorMode: "2", exposure: 0.5,
                detectorExposures: [9, 0.5, 7],
                decoy: Decoy(magnification: 1111.25, stemMagnification: 222000, cameraLength: 9.75, operatingMode: "3",
                             projectorMode: "4", exposure: 3.25)),
        // b: STEM-like. The stem magnification is 225000 and is not copied to the nominal one; the binary detector
        // HAADF has no ExposureTime.
        Planted(id: "case-b-stem-like", binaryDetector: "HAADF", magnification: nil,
                stemMagnification: 225000, cameraLength: 0.15, operatingMode: "1", projectorMode: "1", exposure: nil,
                detectorExposures: [nil, 0.5],
                decoy: Decoy(magnification: 777, stemMagnification: 450000, cameraLength: 0.3, operatingMode: "2",
                             projectorMode: "3", exposure: 1.5)),
        // c1: JSON numbers are read, the stem magnification's value too; the modes, stored as JSON numbers, are nil.
        Planted(id: "case-c1-json-numbers", binaryDetector: "BM-Ceta", magnification: 49000.5,
                stemMagnification: 62500.5, cameraLength: 0.0625, operatingMode: nil, projectorMode: nil,
                exposure: 0.25, detectorExposures: [0.25],
                decoy: Decoy(magnification: 5, stemMagnification: 41, cameraLength: 6, operatingMode: "7",
                             projectorMode: "8", exposure: 9)),
        // c2: "", "abc", "n/a" and null are nil; the mode string "TEM" is kept as stored.
        Planted(id: "case-c2-unparsable", binaryDetector: "BM-Ceta", magnification: nil,
                stemMagnification: nil, cameraLength: nil, operatingMode: "TEM", projectorMode: nil, exposure: nil,
                detectorExposures: [nil],
                decoy: Decoy(magnification: 10, stemMagnification: 42, cameraLength: 11, operatingMode: "12",
                             projectorMode: "13", exposure: 14)),
        // d1: BinaryResult has no Detector; no CustomProperties.
        Planted(id: "case-d1-no-binary-detector", binaryDetector: nil, magnification: nil,
                stemMagnification: nil, cameraLength: nil, operatingMode: nil, projectorMode: "2", exposure: nil,
                detectorExposures: [0.5],
                decoy: Decoy(magnification: 15, stemMagnification: 43, cameraLength: 16, operatingMode: "17",
                             projectorMode: "18", exposure: 19)),
        // d2: BinaryResult.Detector is "" and an unnamed entry has an ExposureTime; no Optics section.
        Planted(id: "case-d2-empty-binary-detector", binaryDetector: "", magnification: nil,
                stemMagnification: nil, cameraLength: nil, operatingMode: nil, projectorMode: nil, exposure: nil,
                detectorExposures: [0.75, 0.5],
                decoy: Decoy(magnification: 20, stemMagnification: 44, cameraLength: 21, operatingMode: "22",
                             projectorMode: "23", exposure: 24)),
        // e: the first BM-Ceta has no ExposureTime, a later one has 2. Scientific notation: "1e5", "1.5e-1",
        // "1.3e+006".
        Planted(id: "case-e-first-entry-no-exposure", binaryDetector: "BM-Ceta", magnification: 100000,
                stemMagnification: 1300000, cameraLength: 0.15, operatingMode: "1", projectorMode: "1", exposure: nil,
                detectorExposures: [nil, 2],
                decoy: Decoy(magnification: 25, stemMagnification: 45, cameraLength: 26, operatingMode: "27",
                             projectorMode: "28", exposure: 29)),
        // f: the Detectors keys are written 4, 2, 5, 1, 3, 0; the first BM-Ceta by index is Detector-1. No
        // CustomProperties.
        Planted(id: "case-f-key-order", binaryDetector: "BM-Ceta", magnification: 20000,
                stemMagnification: nil, cameraLength: 0.5, operatingMode: "2", projectorMode: "1", exposure: 0.5,
                detectorExposures: [nil, 0.5, 7, 3, 4, 5],
                decoy: Decoy(magnification: 31, stemMagnification: 46, cameraLength: 32, operatingMode: "33",
                             projectorMode: "34", exposure: 35)),
        // g: "0" is a value, the stem magnification's as {"type": "bool", "value": "0"}.
        Planted(id: "case-g-zeros", binaryDetector: "BM-Ceta", magnification: 0,
                stemMagnification: 0, cameraLength: 0, operatingMode: "0", projectorMode: "0", exposure: 0,
                detectorExposures: [0],
                decoy: Decoy(magnification: 36, stemMagnification: 47, cameraLength: 37, operatingMode: "38",
                             projectorMode: "39", exposure: 40)),
        // h: StemMagnification has no "value" key; the nominal magnification (60000) is not a fallback.
        Planted(id: "case-h-stem-without-value", binaryDetector: "BM-Ceta", magnification: 60000,
                stemMagnification: nil, cameraLength: 0.3, operatingMode: "1", projectorMode: "1", exposure: 0.1,
                detectorExposures: [0.1],
                decoy: Decoy(magnification: 61, stemMagnification: 48, cameraLength: 62, operatingMode: "63",
                             projectorMode: "64", exposure: 52)),
        // i: StemMagnification is a bare string, not an object.
        Planted(id: "case-i-stem-bare-string", binaryDetector: "BM-Ceta", magnification: 70000,
                stemMagnification: nil, cameraLength: 0.4, operatingMode: "2", projectorMode: "1", exposure: 0.2,
                detectorExposures: [0.2],
                decoy: Decoy(magnification: 65, stemMagnification: 49, cameraLength: 66, operatingMode: "67",
                             projectorMode: "68", exposure: 53)),
        // j: CustomProperties is the string "": the stem magnification is nil and the rest is read as usual.
        Planted(id: "case-j-custom-properties-string", binaryDetector: "BM-Ceta", magnification: 80000,
                stemMagnification: nil, cameraLength: 0.2, operatingMode: "2", projectorMode: "2", exposure: 1.25,
                detectorExposures: [1.25],
                decoy: Decoy(magnification: 69, stemMagnification: 50, cameraLength: 70, operatingMode: "71",
                             projectorMode: "72", exposure: 54)),
    ]

    private static let plantedPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/velox-metadata-planted.emd").path

    private func plantedImages() throws -> [VeloxImageInfo] {
        try VeloxEMDReader(path: Self.plantedPath).images()
    }

    /// The file is a Velox file with every planted image listed, in name order, each (2, 2, 2) uint16.
    func testThePlantedFileListsEveryImage() throws {
        XCTAssertTrue(VeloxEMDReader.isVeloxFile(path: Self.plantedPath))
        let images = try plantedImages()
        XCTAssertEqual(images.map(\.id), Self.planted.map(\.id))
        for image in images {
            XCTAssertEqual([image.height, image.width, image.frameCount], [2, 2, 2], image.id)
            XCTAssertEqual(image.elementType, .uint16, image.id)
        }
        XCTAssertEqual(images.map(\.detectorName), Self.planted.map { $0.binaryDetector ?? "" })
    }

    /// Every image: the six fields, as column 0 holds them. Exact Double equality to the literals above. No planted
    /// CustomProperties carries a scan transformation.
    func testPlantedImagesCarryTheSixFieldsOfColumnZero() throws {
        let images = try plantedImages()
        XCTAssertEqual(images.count, Self.planted.count)
        for (image, want) in zip(images, Self.planted) {
            XCTAssertEqual(image.id, want.id)
            let m = image.metadata
            XCTAssertEqual(m.binaryResultDetector, want.binaryDetector, "\(want.id) BinaryResult.Detector")
            XCTAssertEqual(m.nominalMagnification, want.magnification, "\(want.id) nominalMagnification")
            XCTAssertEqual(m.stemMagnification, want.stemMagnification, "\(want.id) stemMagnification")
            XCTAssertEqual(m.cameraLengthMeters, want.cameraLength, "\(want.id) cameraLengthMeters")
            XCTAssertEqual(m.operatingMode, want.operatingMode, "\(want.id) operatingMode")
            XCTAssertEqual(m.projectorMode, want.projectorMode, "\(want.id) projectorMode")
            XCTAssertEqual(m.exposureTimeSeconds, want.exposure, "\(want.id) exposureTimeSeconds")
            XCTAssertNil(m.scanTransformation, "\(want.id) scanTransformation")
        }
    }

    /// Each detector entry's own ExposureTime, in Detector-<n> index order (the written key order does not show).
    func testPlantedDetectorsCarryTheirOwnExposureTimeInIndexOrder() throws {
        for (image, want) in zip(try plantedImages(), Self.planted) {
            let detectors = image.metadata.detectors
            XCTAssertEqual(detectors.map(\.index), Array(0..<want.detectorExposures.count), "\(want.id) indices")
            XCTAssertEqual(detectors.map(\.exposureTimeSeconds), want.detectorExposures, "\(want.id) exposures")
        }
    }

    /// Column 1 differs from column 0 in every field: none of its values may appear (images() reads column 0).
    func testNoPlantedFieldComesFromTheDecoyColumn() throws {
        for (image, want) in zip(try plantedImages(), Self.planted) {
            let m = image.metadata
            XCTAssertNotEqual(m.nominalMagnification, want.decoy.magnification, "\(want.id) nominalMagnification")
            XCTAssertNotEqual(m.stemMagnification, want.decoy.stemMagnification, "\(want.id) stemMagnification")
            XCTAssertNotEqual(m.cameraLengthMeters, want.decoy.cameraLength, "\(want.id) cameraLengthMeters")
            XCTAssertNotEqual(m.operatingMode, want.decoy.operatingMode, "\(want.id) operatingMode")
            XCTAssertNotEqual(m.projectorMode, want.decoy.projectorMode, "\(want.id) projectorMode")
            XCTAssertNotEqual(m.exposureTimeSeconds, want.decoy.exposure, "\(want.id) exposureTimeSeconds")
        }
    }
}
