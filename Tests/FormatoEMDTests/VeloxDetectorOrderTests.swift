import Testing
import Foundation
import FormatoEMD

extension VeloxEMDSerialized {
    /// 0.0.3 (SpectroKit's ask, 2026-10-15; registration step 1 A7): `VeloxMetadata.parse` keeps the `Detectors` entries
    /// in the order the metadata text writes them, as RosettaSciIO's `json.loads` does, where it sorted them by the
    /// `Detector-<n>` index. RosettaSciIO 049e7d70 takes the FIRST entry in that order whose name contains
    /// `BinaryResult.Detector` for the energy axis (`_emd_velox.py:866-876`), and the first whose name equals it for the
    /// detector metadata (`:51-57`, the rule `exposureTimeSeconds` applies).
    ///
    /// The planted file is SpectroKit's (`tools/edx-stages/make_velox_streams.py` case "axis-order", c5a9a5e), copied with
    /// its sha256; RosettaSciIO's reading of it is pinned in `velox-stream-axis-order.pin.json` by
    /// `tools/asks-0.0.3/pin_axis_order.py` before the fix. The inline cases are planted: their truth is the written order.
    @Suite final class VeloxDetectorOrderTests {
        private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

        private struct Pin: Decodable {
            let sha256: String
            let stream: String
            let dispersion_keV: Double
            let offset_keV: Double
            let detector_keys_file_order: [String]
        }

        /// Keys written Detector-0 (HAADF), Detector-10 (SuperXG11, 20 eV from -1900 eV), Detector-2 (SuperXG12, 10 eV from
        /// -500 eV), BinaryResult.Detector "SuperXG1": RosettaSciIO gives 0.02 keV per channel from -1.9 keV (Detector-10);
        /// the index order gave 0.01 from -0.5 (Detector-2).
        @Test func testThePlantedAxisOrderFileReadsAsRosettaSciIO() throws {
            let pin = try JSONDecoder().decode(Pin.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("velox-stream-axis-order.pin.json")))
            #expect(pin.sha256 == "5fb8100f76e030c83a0dd88e7df98c33ce70151e8a8b36469ce7f8ad094dae3b")
            let si = try VeloxEMDReader(path: Self.fixtures.appendingPathComponent("velox-stream-axis-order.emd").path).readSpectrumImage()
            #expect(si.streams.map(\.id) == [pin.stream])
            #expect(si.metadata.energyAxis == VeloxEnergyAxis(offsetKeV: pin.offset_keV, scaleKeV: pin.dispersion_keV))
            #expect(si.metadata.energyAxis == VeloxEnergyAxis(offsetKeV: -1.9, scaleKeV: 0.02), "the pin's literal values")
            #expect(si.metadata.detectors.map { "Detector-\($0.index)" } == pin.detector_keys_file_order)
            #expect(si.streams[0].segments.map(\.name) == ["SuperXG11", "SuperXG12"], "the segments in the written order")
            #expect(!si.energyCalibrationAgrees, "the two segments differ")
        }

        /// An escaped key is the key it decodes to, and a `Detectors` object nested elsewhere (here under CustomProperties,
        /// written first, in the other order) does not set the root's order.
        @Test func testAnEscapedKeyAndANestedDetectorsObjectKeepTheRootsWrittenOrder() throws {
            let json = #"""
            {"CustomProperties": {"Detectors": {"Detector-1": {"DetectorName": "SuperXG11"}, "Detector-3": {"DetectorName": "SuperXG13"}}},
             "BinaryResult": {"Detector": "SuperXG1"},
             "Detectors": {"Detector\u002d3": {"DetectorName": "SuperXG13", "DetectorType": "AnalyticalDetector", "Dispersion": "10", "OffsetEnergy": "-500"},
                           "Detector-1": {"DetectorName": "SuperXG11", "DetectorType": "AnalyticalDetector", "Dispersion": "20", "OffsetEnergy": "-1900"}}}
            """#
            let m = try VeloxMetadata.parse(jsonData: Data(json.utf8))
            #expect(m.detectors.map(\.index) == [3, 1])
            #expect(m.energyAxis == VeloxEnergyAxis(offsetKeV: -0.5, scaleKeV: 0.01), "Detector-3 is written first")
        }

        /// Strings holding braces, quotes and the word Detectors before the root's `Detectors`, and nested values inside
        /// the entries, do not disturb the scan of the written order.
        @Test func testStringsAndNestedValuesDoNotDisturbTheOrder() throws {
            let json = #"""
            {"Note": "a \"Detectors\": {\"Detector-0\": {}} [in text]", "List": [1, {"Detectors": {"Detector-0": {}}}, "}"],
             "BinaryResult": {"Detector": "BF"},
             "Detectors": {"Detector-7": {"DetectorName": "BF", "ExposureTime": "0.7", "Extra": {"a": [1, 2, {"b": "}"}]}},
                           "Detector-0": {"DetectorName": "BF", "ExposureTime": "0.1"}}, "Tail": true}
            """#
            let m = try VeloxMetadata.parse(jsonData: Data(json.utf8))
            #expect(m.detectors.map(\.index) == [7, 0])
            #expect(m.exposureTimeSeconds == 0.7, "the first BF written")
        }

        /// Gate B (refuter on 42f27e3): of two root `Detectors` objects `JSONSerialization` keeps the FIRST's values, so the
        /// order is the first's too (it listed the last's: indices [1, 0] and 2 eV, neither reading). Python keeps the last
        /// (rsciio: [5, 1], 5 eV): the registered repeated-key deviation, now at least one consistent reading.
        @Test func testTwoRootDetectorsObjectsReadTheFirstConsistently() throws {
            let json = #"{"BinaryResult":{"Detector":"SuperXG1"},"Detectors":{"Detector-0":{"DetectorName":"SuperXG11","Dispersion":"1","OffsetEnergy":"1"},"Detector-1":{"DetectorName":"SuperXG12","Dispersion":"2","OffsetEnergy":"2"}},"Detectors":{"Detector-5":{"DetectorName":"SuperXG15","Dispersion":"5","OffsetEnergy":"5"},"Detector-1":{"DetectorName":"SuperXG12","Dispersion":"2","OffsetEnergy":"2"}}}"#
            let m = try VeloxMetadata.parse(jsonData: Data(json.utf8))
            #expect(m.detectors.map(\.index) == [0, 1])
            #expect(m.energyAxis == VeloxEnergyAxis(offsetKeV: 0.001, scaleKeV: 0.001))
        }

        /// Gate B: a leading UTF-8 BOM, which `JSONSerialization` accepts, does not drop the written order.
        @Test func testALeadingByteOrderMarkKeepsTheWrittenOrder() throws {
            let json = #"{"BinaryResult": {"Detector": "BF"}, "Detectors": {"Detector-5": {"DetectorName": "BF", "ExposureTime": "5"}, "Detector-1": {"DetectorName": "BF", "ExposureTime": "1"}}}"#
            let m = try VeloxMetadata.parse(jsonData: Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8))
            #expect(m.detectors.map(\.index) == [5, 1])
            #expect(m.exposureTimeSeconds == 5)
        }
    }
}
