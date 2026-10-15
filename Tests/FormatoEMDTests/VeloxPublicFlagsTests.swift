import Testing
import Foundation
import FormatoEMD

extension VeloxEMDSerialized {
    /// 0.0.3 (a consumer's request, 2026-10-15): `streamCount`, `energyCalibrationAgrees`, `VeloxStreamInfo.id`,
    /// `streamsAgreeOnCoverage` and `pixelCount` are public. Each flag is seen at both values, over EVERY stream:
    /// `velox-flags-planted.emd` (`tools/asks-0.0.3/make_velox_flags.py`; the truth is its layout) has two streams with one
    /// calibration whose second stops after pixel 1 of frame 1; `velox-tiny.emd` has two streams that end together with
    /// two calibrations. A flag computed from the head stream only reads true on both files.
    @Suite final class VeloxPublicFlagsTests {
        private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

        /// The second stream ends early: coverage disagrees; both detectors at 10 eV from -100 eV: calibration agrees.
        @Test func testASecondStreamThatStopsEarlyAndOneCalibration() throws {
            let si = try VeloxEMDReader(path: Self.fixtures.appendingPathComponent("velox-flags-planted.emd").path).readSpectrumImage()
            #expect(si.streamCount == 2)
            #expect(si.streams.map(\.id) == ["s0", "s1"])
            #expect(si.eventStore.pixelCount == 4)
            #expect(!si.eventStore.streamsAgreeOnCoverage, "s1 stops after pixel 1 of frame 1; s0 has both frames")
            #expect(si.energyCalibrationAgrees, "SuperXG21 and SuperXG22 are both 10 eV/channel from -100 eV")
            #expect(si.eventStore.totalCounts == 14, "8 events in s0, 6 in s1")
            #expect(si.eventStore.completeFrames == 2, "coverage is the head stream's")
            #expect(si.metadata.energyAxis == VeloxEnergyAxis(offsetKeV: -0.1, scaleKeV: 0.01))
        }

        /// The other value of each flag: two streams that end together, segments at 10 and 20 eV/channel.
        @Test func testStreamsThatEndTogetherAndTwoCalibrations() throws {
            let si = try VeloxEMDReader(path: Self.fixtures.appendingPathComponent("velox-tiny.emd").path).readSpectrumImage()
            #expect(si.streamCount == 2)
            #expect(si.streams.count == si.streamCount)
            #expect(si.eventStore.pixelCount == 6)
            #expect(si.eventStore.streamsAgreeOnCoverage)
            #expect(!si.energyCalibrationAgrees)
        }
    }
}
