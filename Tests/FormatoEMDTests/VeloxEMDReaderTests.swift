import Testing
import Foundation
import FormatoCore
import FormatoEMD
import FormatoHDF5

extension VeloxEMDSerialized {
    /// v5.0 WP1: the Velox EMD spectrum-image reader. None of these needs References data: the
    /// decode is tested on synthetic streams, the metadata parser on a JSON literal, and the file
    /// path on a 3 KB synthetic Velox EMD embedded below (`tools/velox-parity/make-tiny-fixture.py`
    /// writes it). The count-for-count comparison with rosettasciio on the public files is
    /// `tools/velox-parity`.
    @Suite(.serialized) final class VeloxEMDReaderTests {
        /// XCTest's `addTeardownBlock`, kept: blocks run in reverse order when the test's suite instance goes away.
        private var teardownBlocks: [() -> Void] = []
        private func addTeardownBlock(_ block: @escaping () -> Void) { teardownBlocks.append(block) }
        deinit { for block in teardownBlocks.reversed() { block() } }

        private let M = VeloxStreamDecoder.pixelMarker

        private func store(_ streams: [[UInt16]], ny: Int, nx: Int, channels: Int = 8, frames: Range<Int>) throws -> VeloxEventStore {
            try VeloxStreamDecoder.buildEventStore(
                arrays: streams, geometry: VeloxStreamGeometry(ny: ny, nx: nx, channels: channels), frames: frames)
        }

        // MARK: Decode

        /// A marker ends a pixel and is never a channel; two markers in a row are an EMPTY pixel,
        /// which must not shift the pixels after it. 1 x 2 grid, two frames.
        @Test func testMarkersEndPixelsAndAnEmptyPixelIsTwoMarkersInARow() throws {
            let stream: [UInt16] = [3, 3, M, M,   1, M, 5, M]      // frame 0: p0 = 2 x ch3, p1 empty; frame 1: p0 = ch1, p1 = ch5
            let s = try store([stream], ny: 1, nx: 2, frames: 0..<2)
            #expect(s.spectrum(pixel: 0) == [0, 1, 0, 2, 0, 0, 0, 0])
            #expect(s.spectrum(pixel: 1) == [0, 0, 0, 0, 0, 1, 0, 0])
            #expect(s.totalCounts == 4, "the marker is not a count")
            #expect(s.completeFrames == 2)
            #expect(s.partialFramePixels == 0)
            #expect(s.outOfRangeValues == 0)
        }

        /// A frame range sums only those frames: frames 1..<2 of a 3-frame stream, and frames 0..<2.
        @Test func testFrameRangeSumsOnlyThoseFrames() throws {
            // 1 x 1 grid: one marker per frame.
            let stream: [UInt16] = [2, M,   4, 4, M,   6, M]
            let middle = try store([stream], ny: 1, nx: 1, frames: 1..<2)
            #expect(middle.spectrum(pixel: 0) == [0, 0, 0, 0, 2, 0, 0, 0])
            #expect(middle.completeFrames == 1)
            let head = try store([stream], ny: 1, nx: 1, frames: 0..<2)
            #expect(head.spectrum(pixel: 0) == [0, 0, 1, 0, 2, 0, 0, 0])
            #expect(head.totalCounts == 3)
            let all = try store([stream], ny: 1, nx: 1, frames: 0..<3)
            #expect(all.totalCounts == 4)
            #expect(throws: (any Error).self) { try store([stream], ny: 1, nx: 1, frames: 2..<2) }
        }

        /// A sub-area raster (2 rows x 3 columns) is row-major, and a stopped acquisition leaves a
        /// partial last frame that is reported, not hidden.
        @Test func testSubAreaRasterIsRowMajorAndAPartialFrameIsReported() throws {
            // frame 0: p0..p5 each one count of channel = pixel index (0 is ch0); frame 1 stops after 2 pixels.
            var stream: [UInt16] = []
            for p in 0..<6 { stream += [UInt16(p), M] }
            stream += [7, M, 7, M]
            let s = try store([stream], ny: 2, nx: 3, frames: 0..<2)
            #expect(s.geometry.pixelsPerFrame == 6)
            #expect(s.spectrum(pixel: 4)[4] == 1, "pixel 4 is row 1, column 1")
            #expect(s.spectrum(pixel: 0)[7] == 1, "frame 1's first pixel")
            #expect(s.spectrum(pixel: 1)[7] == 1)
            #expect(s.spectrum(pixel: 2)[7] == 0)
            #expect(s.completeFrames == 1)
            #expect(s.partialFramePixels == 2)
            #expect(s.framesCovering(pixel: 1) == 2)
            #expect(s.framesCovering(pixel: 2) == 1)
            // A stream that ends on its last marker opens no further frame.
            let exact = try store([Array(stream[0..<12])], ny: 2, nx: 3, frames: 0..<2)
            #expect(exact.completeFrames == 1)
            #expect(exact.partialFramePixels == 0)
        }

        /// The streams of a Super-X are summed; a channel the spectrum does not have is skipped and counted.
        @Test func testDetectorsSumAndOutOfRangeChannelsAreCounted() throws {
            let a: [UInt16] = [1, M, 2, M]
            let b: [UInt16] = [1, M, 8, M]      // 8 is outside 8 channels
            let s = try store([a, b], ny: 1, nx: 2, frames: 0..<1)
            #expect(s.spectrum(pixel: 0)[1] == 2)
            #expect(s.spectrum(pixel: 1)[2] == 1)
            #expect(s.outOfRangeValues == 1)
            #expect(s.totalCounts == 3)
            #expect(s.denseCounts().count == 2 * 8)
        }

        // MARK: Metadata

        private let superXJSON = """
        {"Detectors": {
           "Detector-5": {"DetectorName": "HAADF", "DetectorType": "ScanningDetector", "Enabled": "true"},
           "Detector-6": {"DetectorName": "SuperXG11", "DetectorType": "AnalyticalDetector", "Enabled": "true",
                          "ElevationAngle": "0.38397244", "AzimuthAngle": "0.78539816339744828", "CollectionAngle": "0.225",
                          "Dispersion": "20", "OffsetEnergy": "-1932.21348"},
           "Detector-7": {"DetectorName": "SuperXG12", "DetectorType": "AnalyticalDetector", "Enabled": "true",
                          "ElevationAngle": "0.38397244", "AzimuthAngle": "2.3561944901923448",
                          "Dispersion": "20", "OffsetEnergy": "-1932.21348"},
           "Detector-8": {"DetectorName": "SuperXG13", "DetectorType": "AnalyticalDetector", "Enabled": "false",
                          "ElevationAngle": "0.38397244", "AzimuthAngle": "3.9269908169872414"},
           "Detector-9": {"DetectorName": "SuperXG14", "DetectorType": "AnalyticalDetector", "Enabled": "true",
                          "ElevationAngle": "0.38397244", "AzimuthAngle": "5.497787143782138"}},
         "BinaryResult": {"Detector": "SuperXG1", "PixelSize": {"width": "1.26953125e-09", "height": "1.26953125e-09"}, "PixelUnitX": "m"},
         "Scan": {"ScanSize": {"width": "1024", "height": "1024"}, "DwellTime": "6.25e-06", "FrameTime": "2.63910625",
                  "ScanArea": {"left": "0.400390625", "top": "0.0615234375", "right": "0.6103515625", "bottom": "0.9658203125"},
                  "ScanRotation": "-3.1066860685499069"},
         "Optics": {"AccelerationVoltage": "200000", "ScreenCurrent": "1.8299768652603883e-09"},
         "Stage": {"AlphaTilt": "-0.29458", "BetaTilt": "0", "HolderType": "FEI Double Tilt", "Position": {"x": "1", "y": "2", "z": "3"}},
         "CustomProperties": {"Scan.ScanTransformation.A11": {"type": "double", "value": "1"}, "Scan.ScanTransformation.A12": {"type": "double", "value": "0"},
           "Scan.ScanTransformation.A13": {"type": "double", "value": "-0.0002788"}, "Scan.ScanTransformation.A21": {"type": "double", "value": "0"},
           "Scan.ScanTransformation.A22": {"type": "double", "value": "1"}, "Scan.ScanTransformation.A23": {"type": "double", "value": "-0.0005182"}}}
        """

        /// The owner's Super-X: four segments at 45/135/225/315 degrees and 22 degrees elevation,
        /// read in radians as stored. Swapping azimuth and elevation, or losing the enabled flag, fails.
        @Test func testSuperXGeometryAndTheEnergyAxisAreParsed() throws {
            let m = try VeloxMetadata.parse(jsonData: Data(superXJSON.utf8))
            let x = m.superXDetectors
            #expect(x.map(\.name) == ["SuperXG11", "SuperXG12", "SuperXG13", "SuperXG14"], "the HAADF scanning detector is not an X-ray segment")
            for (d, azimuth) in zip(x, [45.0, 135, 225, 315]) { #expect(abs((d.azimuthDegrees!) - (azimuth)) <= 1e-9) }
            for d in x { #expect(abs((d.elevationDegrees!) - (22.0)) <= 1e-4) }
            #expect(x.map(\.enabled) == [true, true, false, true])
            // rsciio: the first detector whose name CONTAINS BinaryResult.Detector ("SuperXG1" is in "SuperXG11"); eV -> keV.
            #expect(m.energyAxis == VeloxEnergyAxis(offsetKeV: -1.93221348, scaleKeV: 0.02))
            #expect(abs((m.alphaDegrees!) - (-16.87)) <= 0.01)
            #expect(m.betaDegrees == 0)
            #expect(m.holderType == "FEI Double Tilt")
            #expect(m.dwellTimeSeconds == 6.25e-06)
            #expect(abs((m.screenCurrentAmperes!) - (1.83e-9)) <= 1e-11)
            #expect(m.accelerationVoltageVolts == 200_000)
            #expect(m.scanSizeWidth == 1024)
            #expect(m.scanArea?.left == 0.400390625)
            #expect(abs((m.scanRotationRadians!) - (-3.1066860685499069)) <= 1e-15)
            #expect(m.scanTransformation == VeloxScanTransformation(a11: 1, a12: 0, a13: -0.0002788, a21: 0, a22: 1, a23: -0.0005182), "Velox writes FLAT dotted keys under CustomProperties")
            #expect(x[0].solidAngleSteradians == 0.225)
            // The spectrum image is ScanSize x ScanArea (215 columns, 926 rows), not the 1024 raster.
            #expect(m.derivedGrid?.ny == 926)
            #expect(m.derivedGrid?.nx == 215)
        }

        /// With no matching detector there is NO axis, not rsciio's silent 1 channel = 1 unit.
        @Test func testAMissingEnergyCalibrationIsNilNotUnity() throws {
            let m = try VeloxMetadata.parse(jsonData: Data(#"{"BinaryResult": {"Detector": "SuperXG9"}, "Detectors": {"Detector-0": {"DetectorName": "SuperXG1", "Dispersion": "10", "OffsetEnergy": "0"}}}"#.utf8))
            #expect(m.energyAxis == nil)
            #expect(m.derivedGrid == nil)
        }

        /// The same affine under the nested layout is accepted as a fallback.
        @Test func testNestedScanTransformationIsAFallback() throws {
            let json = #"{"CustomProperties": {"Scan": {"ScanTransformation": {"A11": {"value": "1"}, "A12": {"value": "0"}, "A13": {"value": "0.5"}, "A21": {"value": "0"}, "A22": {"value": "1"}, "A23": {"value": "0.25"}}}}}"#
            let m = try VeloxMetadata.parse(jsonData: Data(json.utf8))
            #expect(m.scanTransformation?.a13 == 0.5)
            #expect(m.scanTransformation?.a23 == 0.25)
        }

        // MARK: Synthetic files (tools/velox-parity/make-tiny-fixture.py)

        /// The main file: a NON-SQUARE 3-row x 2-column spectrum image, 8 channels, 2 frames, two streams with a
        /// FrameLocationTable, a (3, 2, 2) HAADF, Super-X segments with different elevations and dispersions.
        private static let mainBase64 = "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"
        /// The main file without ScanArea, and with ScanSize height 4 (`--no-scan-area`, `--wrong-height`).
        private static let noScanAreaBase64 = "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"
        private static let wrongHeightBase64 = "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"
        /// The bare file with ScanSize height 6000 (`--bare-huge-grid`): 3000 x 2 pixels per frame against 8 pixel ends.
        private static let hugeGridBase64 = "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"
        /// The main file with every stream lacking its final pixel marker (`--no-last-marker`), as in example_velox_EELS_EDS.emd.
        private static let noLastMarkerBase64 = "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"
        /// No FrameLocationTable, no SpectrumImage group, one stream stopped mid-frame (8 pixel ends of 6 per frame).
        private static let bareBase64 = "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"
        /// A Velox image file with no stream.
        private static let imageOnlyBase64 = "7ZkxTwIxFMfbHsQLifHcEAmejYODA2zGSeOhmBgxaoijNyCSiBAkhsSYOOLmR3BkdHR0ZOQb4dW2R1tBiJBIwvstj9c+2uPuf3+S15ecd7AYS8QQw7ZRBDlIpSfoUj2X81ciYhFbIraJHMffc3ExvizWN+suzrJZVt0zkPukIzzaCJhHctm9UxYvRS711CF6XaFYvy9X75DnN3xVl7t/3BejKF8Dy5zvjDHWdC+jFcyzzyvBPFO6E85x5UaDyHJC+LAt1rOwlLZjXEFrpp7D+Unew4iEV9mM6r//TeROXH9fXQs0rOtqsC+a92+UL7qr4IugowH/r2Kgnfj9+xtMa3b/HT7czx9jxYawUsd4pA/cYemOSzMZuuXS62q94jdYXijeVpv0SV3/YwmeEQAAAAAAAAAAAADMGmafVfb50nG97qjil4pKfyA34b6j+lybazxCnwt0qeqyY/S3ypVSGk1Rl7zfHTbn0ecCj+F515h9tnlnWJ/yNcnz99R4PvC8Dj4APvDTB7opvc48/5u2D9wkdR8wdQwM8wHzPHWbR4sPyONcgvT7O2zcChSAhQ6Iooj+OSsxzlk7dLCD1P7lfpi6qrmgkUn4Ag=="
        /// A Version dataset of three elements.
        private static let multiVersionBase64 = "6/RwcePlkuJiAAEODgYWBgEGZPAfCjpkUPkw+QQozQilO6D0CiaYOCNYTgIqLgg1H11dSJCrK0j1fzQAs8eABUJzMIyCkQg8XB0DQHQElA9LTyeYUNWFpRYVZ+bnMbgkliQip0sHMu1lZGCFmMEI40NsZmSECDBD1SFoCbBSSaA8KKULwLVCUi4rkAbxmZggwhxQ85gZYUnbAM0FHYMqHoL9/F0YGZjgpUQFK2r+XwDlG0ig5lcF5tE0jJqusJeL6OFHqFx0kB4tF0fTEWY6WgEVOCGFX78KKK1xIMowZD4TGh9kj7uzvw84rwug5nsVKF2tVAYpgZWsFJQMDZV0FJTS8otyE0tA/LDUnPwKpVqY2eToYyZTH7we4R9NM6NgFIyCUTAKRsEoGAWjYBSMglEwCkYBIYBrHDZAAlVdcEFqcklRaW5wSVFqYi7l47CQcTAGnONgo2A0XSKnS9h46Au08S9YOgygkr2Q8XD44D3DAXZUe4gdhxvpAAA="
        /// An image-only Velox file (`--image-typed`): three (3 rows, 5 columns, 2 frames) stacks, int16 / uint16 / float32, each with its own
        /// detector, anisotropic pixel size and offset. The arrays and axes asserted below are what rsciio 049e7d70 reads from it (`--rsciio-truth`).
        private static let typedImageBase64 = "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"
        /// An image-only Velox file (`--image-wide`): one (3, 5, 1) stack of each stored type the typed file lacks, from uint8 to float64.
        private static let wideImagesBase64 = "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"
        /// An image-only Velox file (`--image-refused`) with two images the reader lists but refuses to read: a compound real/imaginary
        /// float type (as Velox stores an FFT) and a 17000 x 17000 uint8 (289 M pixels, over the 2^28 it accepts; no chunk is written).
        private static let refusedImagesBase64 = "7ZvPb9s2FMcl2caMAsPSy5p1RasJO/gwd/JvO+iwObM9F9jqoMmC7tTSMh0LUORUVlpnQbAeu9v+hBx73HHHHXvcn9E/YbdOFEVHUuQ4y4o2q78fwKHe49MjRT1SNl/0a7fV+fDK9SsSI5uV0tKKFOZ1QO5hVBb1j4JSDsrnQflCEXrZr1sN9FcD/3G7rfvtNrN+HUO0o6d5mZXAMtJtNzdY+SCQRTy9VKJ229SZmGNbahGXhOPymwu2K0sZ7kMWMm9ZluVI3Isy5dWz40+8ehbpK7M6HrkZr2SyonB1NvCXkkVor8R68PxS3YfNe72WLCmzXk4z0es/DuSV1eh8VVOI4WhcJa+L8fFbtC6qn2JdRBwlPF8DxYvrZ5//OYu17Mkc/u7b3vdyaBmSQ3aMQ+0JX2G1NVUrFLQvVG04dnaJy+Rtao2n2lHY/x8f4R4BAAAAAAAAAACXjfg+q9jn01ejdnd3yQ4N7Q90/2O7i/a5creCfuAWIS5Dcfcytr/VoIV+eVAjRaM6LNf1Ur9CGgOdloY1o1jvF6rCblgiNd0o0Pqg0i83itUqLQ77OikbjUGtQCt1Ycf3u2eb89KfH0TbP+8+27Izb5/ytxtc/v3m+daB48+i6xJY7nVADcq/bkbtRP7vB+qSQXAcnrf1f9muyHuJdWB0I+ovHsfiOVWvR+0eBfKztWVdB9L+WKizfCofEDnFFSJNmIndr/n6Y//4Y4XnwBxKrI41Jm6XWMP2E2qfs19X1VtSOoioa1np2i/ekel9x0nylb6Ar1neNyXyvjxyU0r6lXZyiZng0rLz4m5PPbttsS7malgr4t8v5YTnyvSc5+e+jMrz4hF5WAAAAAAAAAAAAAAA/n+cfg8ox0slUMT+Xz4upzyFLJ31PpASex8o93XUk+DZJRmP5HxePL+xKJ+XvZN4kWBJmJfPO47lx950Pu/0fI7moUbrUqQU7czTL5zfp/M+Yiq8SkkS+8jh5cNr4a3eh3ie6e8F+UkxXze+Qgy/4+dE7zI/J94XDrUWdanhjp2JtqaeSPlSRLxHdil7E67bbLY67OU4UbF1sOdXbBrEtk17R+iZTdsmfYsOWLXr7FPtKHRevpzov9UpvxHvlUTv6xfvOvO+btrEObhPJ/uWG/GfODJ37QGdspoS026YU2ptmj9T/8Sn5sAdsbri7QrN6w1mMaLmzsh/3bDsq47EWT/apvuA6Xe1sOqnmao3HE4o75HfYE24PGBSvsTdMX/sUn07dnC6N2W9UY11hWn8kX1KLWvL5ONYoHnfruN4AyuU+u2Kb9nbc02DB1PTMKhFHeKaY3t7bLlkx7cs6gzfuGk83jcnpstfvDwMy5sucVzv8Uhd3oA33J4w60KtVq3WG94f78qOMI8BAAAAAAAAAL//8fsfv/8BAAAAAAAAAPwD"

        private func rawBytes(_ base64: String) throws -> Data {
            let compressed = try #require(Data(base64Encoded: base64))
            return try (compressed as NSData).decompressed(using: .zlib) as Data
        }

        private func write(_ raw: Data) throws -> String {
            let path = NSTemporaryDirectory() + "velox-tiny-\(UUID().uuidString).emd"
            try raw.write(to: URL(fileURLWithPath: path))
            addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
            return path
        }

        private func writeFile(_ base64: String? = nil) throws -> String { try write(rawBytes(base64 ?? Self.mainBase64)) }

        /// A same-length byte patch of the file's variable-length JSON strings (stored contiguously; the Metadata columns are strided, so they get their own fixtures).
        private func patched(_ old: String, _ new: String) throws -> String {
            #expect(old.utf8.count == new.utf8.count)
            var raw = try rawBytes(Self.mainBase64)
            let needle = Data(old.utf8), replacement = Data(new.utf8)
            var hits = 0
            var from = raw.startIndex
            while let r = raw.range(of: needle, in: from..<raw.endIndex) {
                raw.replaceSubrange(r, with: replacement)
                from = r.upperBound
                hits += 1
            }
            #expect(hits > 0, "\(old) not found")
            return try write(raw)
        }

        /// Detection looks at the file's own markers: the Version JSON and the stream groups.
        @Test func testDetectionRecognisesAVeloxEMDAndNothingElse() throws {
            #expect(VeloxEMDReader.isVeloxEMD(path: try writeFile()))
            let text = NSTemporaryDirectory() + "velox-not-\(UUID().uuidString).emd"
            try Data("not hdf5".utf8).write(to: URL(fileURLWithPath: text))
            addTeardownBlock { try? FileManager.default.removeItem(atPath: text) }
            #expect(!VeloxEMDReader.isVeloxEMD(path: text))
            #expect(!VeloxEMDReader.isVeloxEMD(path: NSTemporaryDirectory() + "velox-missing-file.emd"))
        }

        /// A Velox file that holds only images is a Velox file but not a spectrum image.
        @Test func testAVeloxImageFileWithNoStreamIsNotASpectrumImage() throws {
            let path = try writeFile(Self.imageOnlyBase64)
            #expect(!VeloxEMDReader.isVeloxEMD(path: path))
            let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: path).readSpectrumImage() }
            if let error {
                if case VeloxEMDError.noSpectrumStream = error {} else { Issue.record("\(error)") }
            }
        }

        /// `isVeloxEMD` is asked about ARBITRARY HDF5 files: a Version dataset of several elements must be
        /// answered "no", not read into a one-pointer buffer.
        @Test func testAVersionDatasetOfSeveralElementsIsNotVelox() throws {
            #expect(!VeloxEMDReader.isVeloxEMD(path: try writeFile(Self.multiVersionBase64)))
        }

        /// Both detectors' streams, both frames, on a 3 x 2 grid (rows != columns), HAADF on the same grid.
        /// Counts cross-checked by hand and with rsciio's own stream function (11 counts, 7 cells).
        @Test func testMainFileDecodesEndToEnd() throws {
            let result = try VeloxEMDReader(path: try writeFile()).readSpectrumImage()
            let s = result.eventStore
            #expect(s.geometry == VeloxStreamGeometry(ny: 3, nx: 2, channels: 8), "ScanSize 4 x 6 over ScanArea .25-.75 x 0-.5")
            #expect(s.frameRange == 0..<2)
            #expect(s.totalCounts == 11)
            #expect(s.distinctEntries == 7)
            #expect(s.spectrum(pixel: 0) == [0, 3, 0, 0, 0, 0, 0, 0])
            #expect(s.spectrum(pixel: 1) == [0, 0, 0, 2, 0, 0, 0, 0])
            #expect(s.spectrum(pixel: 2) == [0, 0, 1, 0, 0, 1, 0, 0])
            #expect(s.spectrum(pixel: 3) == [0, 0, 0, 0, 1, 0, 0, 0])
            #expect(s.spectrum(pixel: 4) == [UInt32](repeating: 0, count: 8))
            #expect(s.spectrum(pixel: 5) == [1, 0, 0, 0, 0, 0, 0, 2])
            #expect(s.completeFrames == 2)
            #expect(s.partialFramePixels == 0)
            #expect(result.streamCount == 2)
            #expect(result.version == "11")
            #expect(result.settingsFrames.end == 2)
            let image = try #require(result.scanImage)
            #expect(image.detectorName == "HAADF")
            #expect([image.ny, image.nx] == [3, 2] as [Int])
            #expect(image.sum == [11, 22, 33, 44, 55, 66], "(y, x, frame) summed over both frames")
            #expect(image.framesSummed == 2)
            #expect(image.framesInFile == 2)
        }

        /// Per-stream detector, the segments it resolves to (with their own elevations), and the calibration check:
        /// segment G22 has 20 eV/channel against 10 for G21, so the summed spectrum mixes scales and says so.
        @Test func testStreamsSegmentsAndTheEnergyCalibrationCheck() throws {
            let result = try VeloxEMDReader(path: try writeFile()).readSpectrumImage()
            #expect(result.streams.map(\.detectorName) == ["SuperXG21", "SuperXG22"])
            #expect(result.streams.map(\.detectorIndex) == [8, 8])
            #expect(result.streams.map { $0.segments.map(\.name) } == [["SuperXG21"], ["SuperXG22"]])
            #expect(abs((result.streams[0].segments[0].elevationDegrees!) - (18.0)) <= 1e-4)
            #expect(abs((result.streams[1].segments[0].elevationDegrees!) - (30.0)) <= 1e-4)
            #expect(abs((result.streams[1].segments[0].azimuthDegrees!) - (135.0)) <= 1e-9)
            #expect(!result.energyCalibrationAgrees)
            // The axis is the first stream's segment: 10 eV/channel from -250 eV.
            #expect(result.metadata.energyAxis == VeloxEnergyAxis(offsetKeV: -0.25, scaleKeV: 0.01))
            #expect(result.metadata.superXDetectors.map(\.enabled) == [true, true, true, false])
        }

        /// Frames 1..<2 only, by the reader's own range argument; the HAADF is summed over the same range.
        @Test func testMainFileFrameRange() throws {
            let path = try writeFile()
            let result = try VeloxEMDReader(path: path).readSpectrumImage(frames: .range(1..<2))
            #expect(result.eventStore.totalCounts == 4)
            #expect(result.eventStore.spectrum(pixel: 5) == [1, 0, 0, 0, 0, 0, 0, 0])
            #expect(result.scanImage?.sum == [10, 20, 30, 40, 50, 60], "frame 1 of the HAADF only")
            #expect(throws: (any Error).self, "rsciio refuses a last_frame past the file's frames") { try VeloxEMDReader(path: path).readSpectrumImage(frames: .range(0..<3)) }
        }

        /// The per-frame drift-correction affine (flat keys), recorded and never applied; and the frame windows.
        @Test func testMainFileFrameTransformationsAndMarkerWindows() throws {
            let reader = VeloxEMDReader(path: try writeFile())
            let t = try reader.readFrameTransformations()
            #expect(t.count == 2)
            #expect(abs((try #require(t[1]).a13) - (0.001)) <= 1e-12)
            #expect(abs((try #require(t[1]).a23) - (-0.002)) <= 1e-12)
            #expect(try reader.markersPerFrame() == [6, 6])
            let times = try reader.readFrameDetectorTimes()
            #expect(times.count == 2)
            #expect(times[0].map(\.name) == ["SuperXG21", "SuperXG22", "SuperXG23", "SuperXG24"])
            #expect(times[0][0].realTime == 0.5)
        }

        /// No FrameLocationTable and no SpectrumImage group: the frame count is ceil(markers / pixels) = ceil(8 / 6) = 2,
        /// and the stopped acquisition shows as a partial last frame, reported, not refused.
        @Test func testTheCeilPathWithNoTableAndNoSettings() throws {
            let result = try VeloxEMDReader(path: try writeFile(Self.bareBase64)).readSpectrumImage()
            let s = result.eventStore
            #expect(s.frameRange == 0..<2)
            #expect(s.completeFrames == 1)
            #expect(s.partialFramePixels == 2)
            #expect(s.totalCounts == 6)
            #expect(s.spectrum(pixel: 0) == [0, 3, 0, 0, 0, 0, 0, 0])
            #expect(s.spectrum(pixel: 1) == [0, 0, 0, 1, 0, 0, 0, 0])
            #expect(s.framesCovering(pixel: 1) == 2)
            #expect(s.framesCovering(pixel: 2) == 1)
            #expect(result.settingsFrames.end == nil)
            #expect(try #require(result.scanImage).framesInFile == 2)
        }

        /// A frame whose last pixel's marker is absent is a COMPLETE frame (rsciio stores the trailing pixel): 11 markers of 12,
        /// two frames of dose for every pixel, nothing partial, and the same counts as the file with its markers.
        @Test func testAFrameEndingWithoutItsLastMarkerIsComplete() throws {
            let s = try VeloxEMDReader(path: try writeFile(Self.noLastMarkerBase64)).readSpectrumImage().eventStore
            #expect(s.frameRange == 0..<2)
            #expect(s.completeFrames == 2)
            #expect(s.partialFramePixels == 0)
            #expect(s.framesCovering(pixel: 5) == 2)
            #expect(s.totalCounts == 11)
        }

        /// Without a ScanArea the grid falls back to rsciio's last-image rule (3 x 2 here), and says nothing else.
        @Test func testTheLastImageGridFallback() throws {
            let path = try writeFile(Self.noScanAreaBase64)
            let result = try VeloxEMDReader(path: path).readSpectrumImage()
            #expect(result.eventStore.geometry == VeloxStreamGeometry(ny: 3, nx: 2, channels: 8))
            #expect(result.eventStore.totalCounts == 11)
        }

        /// A grid the stream cannot fill is refused by name, before anything is allocated from it:
        /// ScanSize height 4 makes 2 x 2 pixels, the FrameLocationTable's 2 frames then disagree with 12 pixel ends.
        @Test func testAGridInconsistentWithTheStreamIsRefused() throws {
            let path = try writeFile(Self.wrongHeightBase64)
            let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: path).readSpectrumImage() }
            if let error {
                if case VeloxEMDError.gridInconsistent = error {} else { Issue.record("\(error)") }
            }
        }

        /// With no FrameLocationTable to catch it, a corrupt ScanSize still throws before pixels + 1 slots are allocated.
        @Test func testAGridLargerThanTheStreamIsRefusedWithoutATable() throws {
            let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: try writeFile(Self.hugeGridBase64)).readSpectrumImage() }
            if let error {
                if case VeloxEMDError.gridInconsistent = error {} else { Issue.record("\(error)") }
            }
        }

        /// Corrupt or unexplained frame positions throw a named error; they never trap.
        @Test func testBadFramePositionsThrow() throws {
            let zeroEnd = try patched("\"endFramePosition\": \"2\"", "\"endFramePosition\": \"0\"")
            let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: zeroEnd).readSpectrumImage() }
            if let error {
                if case VeloxEMDError.frameRangeInvalid = error {} else { Issue.record("\(error)") }
            }
            let start = try patched("\"startFramePosition\": \"1\"", "\"startFramePosition\": \"2\"")
            do {
                let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: start).readSpectrumImage() }
                if let error {
                    if case VeloxEMDError.unsupportedFramePosition = error {} else { Issue.record("\(error)") }
                }
            }
        }

        /// A file cut in half is not a file: detection says no and a read throws.
        @Test func testATruncatedFileThrows() throws {
            let raw = try rawBytes(Self.mainBase64)
            let path = try write(raw.prefix(raw.count / 2))
            #expect(!VeloxEMDReader.isVeloxEMD(path: path))
            #expect(throws: (any Error).self) { try VeloxEMDReader(path: path).readSpectrumImage() }
        }

        // MARK: Image API (2026-10-12: one Velox parser for every consumer; image readers read plain images through it)

        /// What `make-tiny-fixture.py --rsciio-truth` prints for the typed file (rsciio 049e7d70): per image the frames as (y, x) rows
        /// flattened, and the y/x axes in the unit rsciio compacted to (nm, um, pm from the image's own field of view). The values are
        /// exact in the file's type, so the frames compare equal as Float32, not within a tolerance.
        private struct RsciioImage {
            let id: String, detector: String, type: VeloxImageElementType
            let frames: [[Float]]
            let unit: String, scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double
        }

        private static let metersPerUnit: [String: Double] = ["nm": 1e-9, "µm": 1e-6, "pm": 1e-12]

        private static let int16Frames: [[Float]] = [
            [-1, -32768, 32767, 300, 0, 17, -300, 42, -7, 1000, -12345, 256, -256, 5, -99],
            [2, 32767, -32768, -300, 123, -18, 301, -43, 8, -1000, 12346, -257, 257, -6, 100]]
        private static let uint16Frames: [[Float]] = [
            [65535, 40000, 300, 0, 1, 32768, 32767, 65534, 256, 12, 511, 4096, 61000, 7, 40001],
            [2, 300, 40000, 65535, 99, 32769, 1, 255, 65533, 13, 512, 4097, 2, 8, 40002]]
        private static let float32Frames: [[Float]] = [
            [-2.25, 0.5, 1000000.5, 3.0, -0.125, 1.5, -1000000.5, 0.0, 2.75, 123456.5, 0.25, -7.5, 65536.5, 0.0009765625, 8.0],
            [7.5, -0.25, 2.0, -3.5, 0.0625, -1.5, 999999.5, -4.0, 0.125, -123456.5, -0.5, 7.25, -65536.5, 1.0, 0.5]]

        private static let rsciioTruth: [RsciioImage] = [
            RsciioImage(id: "0c5f3e9a7b1d4c2e8a6f1b0d9e7c5a32", detector: "HAADF", type: .int16, frames: int16Frames, unit: "nm",
                        scaleX: 2.4999999999999996, scaleY: 3.9999999999999996, offsetX: 6.999999999999999, offsetY: -2.9999999999999996),
            RsciioImage(id: "5b2178d0c4e94f3a9d17e6a2b8c05f41", detector: "DF4", type: .uint16, frames: uint16Frames, unit: "µm",
                        scaleX: 1.25, scaleY: 2.0, offsetX: 0.39999999999999997, offsetY: -1.5),
            RsciioImage(id: "d94a60b3e1f2478c95a0d3c7b6e18f29", detector: "BF", type: .float32, frames: float32Frames, unit: "pm",
                        scaleX: 300.0, scaleY: 500.00000000000006, offsetX: -200.0, offsetY: 600.0)]

        private func assertClose(_ value: Double, _ expected: Double, _ what: String, fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
            #expect(abs(value - expected) <= 1e-12 * abs(expected), "\(what): \(value) against \(expected)", sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
        }

        private func writeTyped() throws -> String { try writeFile(Self.typedImageBase64) }

        /// Three groups under Data/Image, listed in name order with their detector, shape (rows x columns, then frames) and stored type.
        /// The 3 x 5 shape is not square, so a swapped height and width fails.
        @Test func testImagesListsTheTypedFilesThreeStacks() throws {
            let images = try VeloxEMDReader(path: try writeTyped()).images()
            #expect(images.map(\.id) == Self.rsciioTruth.map(\.id))
            #expect(images.map(\.detectorName) == ["HAADF", "DF4", "BF"])
            #expect(images.map(\.height) == [3, 3, 3], "Data dimension 0 is y")
            #expect(images.map(\.width) == [5, 5, 5], "Data dimension 1 is x")
            #expect(images.map(\.frameCount) == [2, 2, 2])
            #expect(images.map { $0.elementType } == Self.rsciioTruth.map { Optional($0.type) })
        }

        /// Both frames of each type equal rsciio's arrays exactly: a signed read of the unsigned stack, an unsigned read of the signed
        /// one, an integer read of the float one, a frame index ignored, or rows and columns swapped, each changes a value.
        @Test func testEveryFrameOfEveryTypeEqualsRsciio() throws {
            let reader = VeloxEMDReader(path: try writeTyped())
            for image in Self.rsciioTruth {
                #expect(image.frames.count == 2)
                for (frame, expected) in image.frames.enumerated() {
                    #expect(try reader.readImageFrame(id: image.id, frame: frame) == expected, "\(image.detector) frame \(frame)")
                }
            }
        }

        private static let wideUInt8: [UInt8] = [0, 255, 128, 1, 127, 254, 2, 100, 200, 50, 255, 0, 17, 34, 51]
        private static let wideInt8: [Int8] = [-128, 127, -1, 0, 1, -127, 126, -2, 64, -64, 100, -100, 5, -5, 42]
        private static let wideUInt32: [UInt32] = [0, 4294967295, 2147483648, 16777216, 16777217, 1, 4278190080, 65535, 65536, 4294901760,
                                                   123456789, 3000000000, 7, 255, 256]
        private static let wideInt32: [Int32] = [-2147483648, 2147483647, -1, 16777217, -16777217, 0, 1, -65536, 65535, 100000,
                                                 -123456789, 2000000000, -2000000000, 7, -7]
        private static let wideUInt64: [UInt64] = [0, 1, 9223372036854775808, 18446744073709551615, 4294967296, 16777217, 1099511627776,
                                                   281474976710656, 65535, 255, 123456789012, 9007199254740993, 3, 4611686018427387904, 12]
        private static let wideInt64: [Int64] = [-9223372036854775808, 9223372036854775807, -1, 4294967296, -4294967296, 0, 1, -16777217,
                                                 16777217, 1099511627776, -123456789012, 9007199254740993, -3, 4611686018427387904, -12]
        private static let wideFloat64: [Double] = [0.5, -2.25, 1e10, 0.1, 123456789.123, -0.1, 3.4e38, 1e-30, 1.0000000001, -7.5,
                                                    2.5, 1e-3, -1e5, 16777217.0, 0.3333333333333333]

        /// The seven stored types the typed file lacks, each named and read. The values come from `--rsciio-truth` (rsciio keeps the stored
        /// dtype); the reader returns Float32, so the expected arrays are those values rounded to the nearest Float32 (`Float(_:)`), which is
        /// what HDF5's conversion must also do for 16777217, 2^64 - 1 and 0.1: a truncating conversion fails here.
        @Test func testTheOtherStoredTypesAreNamedAndReadRoundedToFloat32() throws {
            let reader = VeloxEMDReader(path: try writeFile(Self.wideImagesBase64))
            let images = try reader.images()
            #expect(images.map(\.id) == ["0-uint8", "1-int8", "2-uint32", "3-int32", "4-uint64", "5-int64", "6-float64"])
            let types: [VeloxImageElementType?] = [.uint8, .int8, .uint32, .int32, .uint64, .int64, .float64]
            #expect(images.map { $0.elementType } == types)
            #expect(images.map(\.frameCount) == [Int](repeating: 1, count: 7))
            let expected: [[Float]] = [
                Self.wideUInt8.map { Float($0) }, Self.wideInt8.map { Float($0) }, Self.wideUInt32.map { Float($0) },
                Self.wideInt32.map { Float($0) }, Self.wideUInt64.map { Float($0) }, Self.wideInt64.map { Float($0) },
                Self.wideFloat64.map { Float($0) }]
            for (image, values) in zip(images, expected) {
                #expect(try reader.readImageFrame(id: image.id, frame: 0) == values, Comment(rawValue: image.id))
            }
        }

        /// The pixel size and Offset the metadata reports are rsciio's axes: scale_x from the width, scale_y from the height, the
        /// offsets from Offset.x / Offset.y, each through the unit rsciio compacted to. Widths differ from heights and x offsets from
        /// y offsets, so a swap or a copy fails; column 1 of each Metadata carries another width, so any other column fails.
        @Test func testImageMetadataEqualsRsciiosAxesAfterUnitConversion() throws {
            let images = try VeloxEMDReader(path: try writeTyped()).images()
            for (image, truth) in zip(images, Self.rsciioTruth) {
                let toMeters = try #require(Self.metersPerUnit[truth.unit], Comment(rawValue: truth.unit))
                let m = image.metadata
                #expect(m.binaryResultDetector == truth.detector)
                let size = try #require(m.pixelSizeMeters, Comment(rawValue: truth.detector))
                assertClose(size.width, truth.scaleX * toMeters, "\(truth.detector) pixel width")
                assertClose(size.height, truth.scaleY * toMeters, "\(truth.detector) pixel height")
                let offset = try #require(m.offset, Comment(rawValue: truth.detector))
                assertClose(offset.x, truth.offsetX * toMeters, "\(truth.detector) offset x")
                assertClose(offset.y, truth.offsetY * toMeters, "\(truth.detector) offset y")
                #expect(m.pixelUnit == "m")
                #expect(m.pixelUnitY == "m")
            }
        }

        /// rsciio reads the X unit for both axes, so its image path cannot tell the two apart; Velox writes both, and this parser
        /// reports both: a Y unit read from the X key, or an Offset y read from x, fails here.
        @Test func testMetadataReportsBothPixelUnitsAndBothOffsets() throws {
            let json = #"{"BinaryResult": {"Detector": "BF", "PixelSize": {"width": "2e-9", "height": "3"}, "PixelUnitX": "m", "PixelUnitY": "nm", "Offset": {"x": "1.5e-9", "y": "-4"}}}"#
            let m = try VeloxMetadata.parse(jsonData: Data(json.utf8))
            #expect(m.pixelUnit == "m")
            #expect(m.pixelUnitY == "nm")
            #expect(m.offset?.x == 1.5e-9)
            #expect(m.offset?.y == -4)
            #expect(m.pixelSizeMeters?.height == 3, "recorded as stored, in pixelUnitY")
            // An Offset needs both coordinates, and a file that names no Y unit has none.
            let half = try VeloxMetadata.parse(jsonData: Data(#"{"BinaryResult": {"PixelUnitX": "m", "Offset": {"x": "1"}}}"#.utf8))
            #expect(half.offset == nil)
            #expect(half.pixelUnitY == nil)
        }

        /// `contents` counts what the file holds from its group names, with nothing decoded: the planted main file holds an image, a
        /// spectrum stream and no EELS; with its image group renamed away it holds none; a file that is not HDF5 has no contents.
        @Test func testContentsCountsTheGroupsAFileHolds() throws {
            let main = try #require(VeloxEMDReader.contents(path: try writeFile()))
            #expect(main == VeloxContents(images: 1, spectra: 0, edsSpectrumImages: 2, eelsSpectrumImages: 0), "the planted main file: one image, two streams")
            #expect(main.hasSpectrumImage)
            let noImages = try #require(VeloxEMDReader.contents(path: try patched("\0Image\0", "\0Imagx\0")))
            #expect(noImages.images == 0, "the rename took")
            #expect(noImages.edsSpectrumImages == main.edsSpectrumImages)
            // Without its Data/SpectrumImage group the streams are a spot spectrum (the FEI single-spectrum layout), not a scan.
            let spot = try #require(VeloxEMDReader.contents(path: try patched("\0SpectrumImage\0", "\0SpectrumImagx\0")))
            #expect(spot.edsSpectrumImages == 0 && !spot.hasSpectrumImage)
            let text = NSTemporaryDirectory() + "velox-contents-\(UUID().uuidString).emd"
            try Data("not hdf5".utf8).write(to: URL(fileURLWithPath: text))
            #expect(VeloxEMDReader.contents(path: text) == nil)
        }

        /// `isVeloxFile` is "a Velox file that holds something to read": a spectrum stream or image, or an image group with Data AND
        /// Metadata. `isVeloxEMD` keeps meaning a spectrum image (the app routes `.emd` on it), so it stays false for image-only files.
        @Test func testIsVeloxFileAcceptsStreamAndImageFilesAndNothingElse() throws {
            let typed = try writeTyped(), refused = try writeFile(Self.refusedImagesBase64)
            #expect(VeloxEMDReader.isVeloxFile(path: typed))
            #expect(VeloxEMDReader.isVeloxFile(path: refused))
            #expect(VeloxEMDReader.isVeloxFile(path: try writeFile()), "the main file: stream, spectrum image and image")
            // The main file with its Data/Image group renamed away (a heap name, same length): a stream and a spectrum image remain.
            let noImages = try patched("\0Image\0", "\0Imagx\0")
            #expect(try VeloxEMDReader(path: noImages).images().count == 0, "the rename took")
            #expect(VeloxEMDReader.isVeloxFile(path: noImages), "no image group, still a spectrum image")
            #expect(!VeloxEMDReader.isVeloxFile(path: try writeFile(Self.imageOnlyBase64)), "an image group with Data and no Metadata")
            let text = NSTemporaryDirectory() + "velox-not-\(UUID().uuidString).emd"
            try Data("not hdf5".utf8).write(to: URL(fileURLWithPath: text))
            addTeardownBlock { try? FileManager.default.removeItem(atPath: text) }
            #expect(!VeloxEMDReader.isVeloxFile(path: text))
            #expect(!VeloxEMDReader.isVeloxFile(path: NSTemporaryDirectory() + "velox-missing-file.emd"))
            #expect(!VeloxEMDReader.isVeloxFile(path: try writeFile(Self.multiVersionBase64)))
            let raw = try rawBytes(Self.mainBase64), rawTyped = try rawBytes(Self.typedImageBase64)
            #expect(!VeloxEMDReader.isVeloxFile(path: try write(raw.prefix(raw.count / 2))))
            #expect(!VeloxEMDReader.isVeloxFile(path: try write(rawTyped.prefix(rawTyped.count / 2))))
            // The spectrum-image question is unchanged: no image-only file answers yes.
            #expect(!VeloxEMDReader.isVeloxEMD(path: typed))
            #expect(!VeloxEMDReader.isVeloxEMD(path: refused))
            #expect(!VeloxEMDReader.isVeloxEMD(path: try writeFile(Self.imageOnlyBase64)))
        }

        /// An id the file does not list and a frame it does not hold are refused by name, never read.
        @Test func testReadImageFrameRefusesAnUnknownIdAndAFrameOutOfRange() throws {
            let reader = VeloxEMDReader(path: try writeTyped())
            let id = Self.rsciioTruth[0].id
            // HDF5 resolves "<id>/." to the group itself: only the ids images() lists are images.
            for bad in ["no-such-image", "", "../SpectrumStream/aaaa", id + "/Data", id + "/."] {
                let error = #expect(throws: (any Error).self, "id \(bad)") { try reader.readImageFrame(id: bad, frame: 0) }
                if let error {
                    if case VeloxEMDError.unknownImage = error {} else { Issue.record("\(error)") }
                }
            }
            for frame in [2, -1, 100] {
                do {
                    let error = #expect(throws: (any Error).self, "frame \(frame)") { try reader.readImageFrame(id: id, frame: frame) }
                    if let error {
                        if case VeloxEMDError.frameRangeInvalid = error {} else { Issue.record("\(error)") }
                    }
                }
            }
            #expect(throws: Never.self) { try reader.readImageFrame(id: id, frame: 1) }
        }

        /// A compound (FFT) image is listed with no element type and refused by name when read: no float read can take it. An image of
        /// more pixels than the reader accepts is listed with its true shape and refused before anything is allocated from it.
        @Test func testAnImageWithNoFloatReadOrTooManyPixelsIsRefusedByName() throws {
            let reader = VeloxEMDReader(path: try writeFile(Self.refusedImagesBase64))
            let images = try reader.images()
            #expect(images.map(\.id) == ["9e1b4d7a2c6f4803b5a9d0e3f7c28b16", "f3a70c1e8d5b49266e2fb0a4c9d71e58"])
            #expect(images.map(\.height) == [3, 17000])
            #expect(images.map(\.width) == [5, 17000])
            #expect(images.map(\.frameCount) == [1, 1])
            #expect(images[0].elementType == nil)
            #expect(images[1].elementType == .uint8)
            let error = #expect(throws: (any Error).self) { try reader.readImageFrame(id: images[0].id, frame: 0) }
            if let error {
                if case VeloxEMDError.unsupportedImageType = error {} else { Issue.record("\(error)") }
            }
            do {
                let error = #expect(throws: (any Error).self) { try reader.readImageFrame(id: images[1].id, frame: 0) }
                if let error {
                    if case VeloxEMDError.readFailed = error {} else { Issue.record("\(error)") }
                }
            }
        }

        /// The spectrum image's own HAADF is an image too: (3, 2, 2) uint16, and frame 1 is the 10 x 1...6 the end-to-end test sums.
        @Test func testImagesOfTheMainFileAndOfFilesThatAreNotVelox() throws {
            let reader = VeloxEMDReader(path: try writeFile())
            let images = try reader.images()
            #expect(images.map(\.id) == ["img0"])
            #expect(images[0].detectorName == "HAADF")
            #expect([images[0].height, images[0].width, images[0].frameCount] == [3, 2, 2] as [Int])
            #expect(images[0].elementType == .uint16)
            #expect(try reader.readImageFrame(id: "img0", frame: 0) == [1, 2, 3, 4, 5, 6])
            #expect(try reader.readImageFrame(id: "img0", frame: 1) == [10, 20, 30, 40, 50, 60])
            // A group with Data and no Metadata is not an image this reader can describe.
            #expect(try VeloxEMDReader(path: try writeFile(Self.imageOnlyBase64)).images().count == 0)
            let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: try writeFile(Self.multiVersionBase64)).images() }
            if let error {
                if case VeloxEMDError.notVeloxFile = error {} else { Issue.record("\(error)") }
            }
            do {
                let error = #expect(throws: (any Error).self) { try VeloxEMDReader(path: NSTemporaryDirectory() + "velox-missing-file.emd").images() }
                if let error {
                    if case VeloxEMDError.cannotOpen = error {} else { Issue.record("\(error)") }
                }
            }
        }
    }
}
