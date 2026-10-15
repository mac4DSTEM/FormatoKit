import Testing
import Foundation
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    /// Step 4 (docs/registration-step-4.md §5, "planted literals"): values typed here by hand from the planted counts and the
    /// rules, without the pins: the type wraps, the frame rules, rebinning, the energy axis choice, the EELS layout and the
    /// refusals of the registered deviations.
    @Suite final class VeloxSpectrumImageTests {
        private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/step4")

        private func read(_ name: String, _ options: VeloxSpectrumImageOptions = .init()) throws -> [FormatoSignal] {
            try VeloxSpectrumImageSignals(path: Self.fixtures.appendingPathComponent(name).path, options: options).signals
        }

        private func value(_ a: FormatoArray, _ index: [Int]) -> Double {
            var flat = 0
            for (i, n) in zip(index, a.shape) { flat = flat * n + i }
            return a.doubleAt(flat)
        }

        /// SpectroKit's 1stream-3frames: pixel 7 (y 1, x 3) holds 70 000 counts in channel 2000 and nothing else.
        @Test func testCountsWrapInTheTargetType() throws {
            #expect(value(try read("sk-1stream-3frames.emd")[0].data, [1, 3, 2000]) == 4464, "uint16: 70000 - 65536")
            #expect(value(try read("sk-1stream-3frames.emd", .init(dataType: .uint8))[0].data, [1, 3, 2000]) == 112, "uint8: 70000 mod 256")
            #expect(value(try read("sk-1stream-3frames.emd", .init(dataType: .int8))[0].data, [1, 3, 2000]) == 112, "int8: 112")
            #expect(value(try read("sk-1stream-3frames.emd", .init(dataType: .float32))[0].data, [1, 3, 2000]) == 70000)
            // Frames apart: 30000, 25000 and 15000 (the generator's split), the last two frames only from first_frame 1.
            let frames = try read("sk-1stream-3frames.emd", .init(sumFrames: false))[0]
            #expect(frames.data.shape == [3, 3, 4, 4096])
            #expect([0, 1, 2].map { value(frames.data, [$0, 1, 3, 2000]) } == [30000, 25000, 15000])
            #expect(value(try read("sk-1stream-3frames.emd", .init(firstFrame: 1))[0].data, [1, 3, 2000]) == 40000)
            #expect(value(try read("sk-1stream-3frames.emd", .init(lastFrame: 1))[0].data, [1, 3, 2000]) == 30000)
            // Rebinned by 4: channel 2000 is bin 500.
            #expect(value(try read("sk-1stream-3frames.emd", .init(rebinEnergy: 4, dataType: .uint32))[0].data, [1, 3, 500]) == 70000)
        }

        /// In memory: the kernel's own edges (RosettaSciIO's loop: += 1 in the type; the frame turnover on the value after a
        /// frame's last marker; last_frame 0 never stops).
        @Test func testKernelLiterals() throws {
            func run(_ values: [UInt16], _ ny: Int, _ nx: Int, _ channels: Int, first: Int = 0, last: Int, rebin: Int = 1,
                     summed: Bool = true, _ type: FormatoDataType) throws -> FormatoArray {
                try veloxStreamToArray(values, ny: ny, nx: nx, channels: channels, firstFrame: first, lastFrame: last,
                                       rebinEnergy: rebin, sumFrames: summed, dataType: type)
            }
            #expect(value(try run([UInt16](repeating: 1, count: 300), 1, 1, 2, last: 1, .uint8), [0, 0, 1]) == 44)
            #expect(value(try run([UInt16](repeating: 1, count: 200), 1, 1, 2, last: 1, .int8), [0, 0, 1]) == -56)
            #expect(value(try run([UInt16](repeating: 0, count: (1 << 24) + 5), 1, 1, 1, last: 1, .float32), [0, 0, 0]) == 16_777_216)
            // Two frames of one pixel: [1, M, 1, M]; last_frame 1 counts the first frame only, 0 counts both.
            let two: [UInt16] = [1, 65535, 1, 65535]
            #expect(value(try run(two, 1, 1, 2, last: 1, .uint16), [0, 0, 1]) == 1)
            #expect(value(try run(two, 1, 1, 2, last: 0, .uint16), [0, 0, 1]) == 2)
            // Rebin 2 sums channels 2 and 3 into bin 1.
            #expect(value(try run([2, 3, 3], 1, 1, 4, last: 1, rebin: 2, .uint16), [0, 0, 1]) == 3)
            // A channel at the bin count is refused (registered deviation).
            #expect(throws: FormatoReadError.self) { _ = try run([4], 1, 1, 4, last: 1, .uint16) }
        }

        /// The energy axis: the first Detectors entry in WRITTEN order whose name contains BinaryResult.Detector.
        @Test func testEnergyAxisFollowsRosettaSciIOsRule() throws {
            let decoy = try read("sk-axis-decoy.emd")[0].axes.last!
            #expect(decoy.name == "X-ray energy" && decoy.units == "keV")
            #expect(decoy.scale == 0.01 && decoy.offset == -0.5, "the decoy SuperXG1-old, written first, contains SuperXG1")
            let order = try read("sk-axis-order.emd")[0].axes.last!
            #expect(order.scale == 0.02 && order.offset == -1.9, "Detector-10 is written before Detector-2")
            let v11 = try read("si-planted-v11.emd")[0].axes.last!
            #expect(v11.scale == 0.005 && v11.offset == -0.02, "SuperXG23, written before SuperXG21, contains SuperXG2")
            #expect(try read("si-planted-v11.emd", .init(rebinEnergy: 4))[0].axes.last!.scale == 0.02)
        }

        /// The Time axis of frames not summed: FrameTime 0.001 s through _convert_scale_units with factor 3 is 1 ms.
        @Test func testFramesNotSummed() throws {
            let s = try read("sk-1stream-3frames.emd", .init(sumFrames: false))[0]
            #expect(s.axes.map(\.name) == ["Time", "y", "x", "X-ray energy"])
            #expect(s.axes[0].scale == 1 && s.axes[0].units == "ms" && s.axes[0].navigate)
            #expect(s.title == "EDS" && s.signalType == "EDS_TEM")
        }

        /// EELS: e1 stored (x, E, y) = (3, 5, 2), value 100x + 10E + y, read as (y, x, E); e2 stored (x, E), x + E/4.
        @Test func testEELSSpectrumImages() throws {
            let s = try read("si-planted-eels.emd")
            #expect(s.map(\.title) == ["EELS", "EELS", "EDS"])
            #expect(s[0].data.shape == [2, 3, 5] && s[0].data.dataType == .uint16)
            #expect(value(s[0].data, [1, 2, 3]) == 231)
            #expect(s[0].axes.map(\.name) == ["y", "x", "Energy-loss"])
            #expect(s[0].axes[2].offset == 100.5 && s[0].axes[2].scale == 0.25 && s[0].axes[2].units == "eV")
            #expect(s[1].data.shape == [3, 5] && s[1].data.dataType == .float32)
            #expect(value(s[1].data, [2, 1]) == 2.25)
            #expect(s[1].axes[1].offset == -5 && s[1].axes[1].scale == 0.05)
            #expect(s[0].signalType == "EELS" && s[0].metadata["General.original_filename"]?.value.text == "si-planted-eels.emd")
        }

        /// The registered deviations are refused by name.
        @Test func testDeviationsAreRefused() throws {
            #expect { _ = try read("si-planted-grid.emd") } throws: { "\($0)".contains("§3.3") }
            #expect(try read("si-planted-bins.emd").count == 1)
            #expect { _ = try read("si-planted-bins.emd", .init(sumEDSDetectors: false)) } throws: { "\($0)".contains("§3.5") }
            #expect { _ = try read("si-planted-v11.emd", .init(firstFrame: 2, lastFrame: 2, sumFrames: false)) } throws: { "\($0)".contains("§3.5") }
            #expect(throws: (any Error).self) { _ = try read("spectrokit/velox-stream-1stream-1frame.emd") }
        }
    }
}

private extension FormatoArray {
    /// Element `i` (C order) as a Double.
    func doubleAt(_ i: Int) -> Double {
        bytes.withUnsafeBytes { p in
            switch dataType {
            case .uint8: return Double(p.load(fromByteOffset: i, as: UInt8.self))
            case .int8: return Double(p.load(fromByteOffset: i, as: Int8.self))
            case .uint16: return Double(p.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
            case .int16: return Double(p.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))
            case .uint32: return Double(p.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
            case .int32: return Double(p.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self))
            case .uint64: return Double(p.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self))
            case .int64: return Double(p.loadUnaligned(fromByteOffset: 8 * i, as: Int64.self))
            case .float32: return Double(p.loadUnaligned(fromByteOffset: 4 * i, as: Float.self))
            case .float64: return p.loadUnaligned(fromByteOffset: 8 * i, as: Double.self)
            default: return .nan
            }
        }
    }
}
