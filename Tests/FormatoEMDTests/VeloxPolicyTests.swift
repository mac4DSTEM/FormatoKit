import CryptoKit
import Foundation
import Testing
import FormatoCore
@testable import FormatoEMD

extension VeloxEMDSerialized {
    /// FormatoKit's Velox policies. P2 (the grid) against RosettaSciIO's own
    /// reading in step-4-pins.json, P1 (an unhandled pixel unit) against literals typed here for the planted `si-units-px.emd`
    /// (tools/policy/make_policy_fixtures.py), P3 (the array cap) at its boundary, P8 (the block size) by equal results and by
    /// the blocks it makes.
    @Suite final class VeloxPolicyTests {
        private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        private static let step4 = tests.appendingPathComponent("FormatoEMDTests/Fixtures/step4")
        private static let policyFixtures = tests.appendingPathComponent("FormatoEMDTests/Fixtures/policy")
        private static let pins = tests.appendingPathComponent("FormatoCoreTests/Fixtures/step-4-pins.json")
        private static let prefix = "FormatoKit.policy."

        private func planted(_ name: String) -> String { Self.step4.appendingPathComponent(name).path }
        private func policyFile(_ name: String) -> String { Self.policyFixtures.appendingPathComponent(name).path }

        private func read(_ path: String, _ options: VeloxSpectrumImageOptions = .init()) throws -> [FormatoSignal] {
            try VeloxSpectrumImageSignals(path: path, options: options).signals
        }

        private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        private func hex(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) }

        private func policyKeys(_ s: FormatoSignal) -> [String] { s.metadata.keys.filter { $0.hasPrefix(Self.prefix) } }

        private func options(_ o: [String: Any], _ policy: VeloxReadPolicy) throws -> VeloxSpectrumImageOptions {
            var out = VeloxSpectrumImageOptions(policy: policy)
            for (key, value) in o {
                switch key {
                case "first_frame": out.firstFrame = try #require(value as? Int)
                case "last_frame": out.lastFrame = value as? Int
                case "sum_frames": out.sumFrames = try #require(value as? Bool)
                case "sum_EDS_detectors": out.sumEDSDetectors = try #require(value as? Bool)
                case "rebin_energy": out.rebinEnergy = try #require(value as? Int)
                case "SI_dtype": out.dataType = FormatoDataType(rawValue: try #require(value as? String))
                default: Issue.record("unknown option \(key)")
                }
            }
            return out
        }

        /// A Sendable count of the times a read polls for cancellation: once per block of a stream, so it counts the blocks.
        private final class Polls: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func tick() -> Bool { lock.lock(); n += 1; lock.unlock(); return false }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }

        // MARK: P2, the grid

        /// `.firstImage` is RosettaSciIO's own reading: on the planted grid file (first image 3 x 4, ScanSize x ScanArea 4 x 3)
        /// option sets O1 to O8 of step-4-pins.json equal its records exactly; O9 and O10 raise there and here. The default
        /// refuses on that file (§3.3).
        @Test func testFirstImageEqualsRosettaSciIOOnThePlantedGrid() throws {
            let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.pins)) as? [String: Any])
            let files = try #require(doc["files"] as? [[String: Any]])
            let file = try #require(files.first { $0["path"] as? String == "si-planted-grid.emd" })
            let runs = try #require(file["runs"] as? [String: [String: Any]])
            let path = planted("si-planted-grid.emd")
            var equalSignals = 0
            for key in (1...10).map({ "O\($0)" }) {
                let run = try #require(runs[key])
                let o = try #require(run["options"] as? [String: Any])
                let opts = try options(o, VeloxReadPolicy(spectrumImageGrid: .firstImage))
                if run["raises"] as? [String: Any] != nil {
                    #expect(throws: (any Error).self, "\(key): RosettaSciIO raises") { _ = try self.read(path, opts) }
                    continue
                }
                let pinned = try #require(run["signals"] as? [[String: Any]])
                let ours = try read(path, opts)
                #expect(ours.count == pinned.count, "\(key): signal count")
                for (s, p) in zip(ours, pinned) {
                    #expect(s.data.dataType.rawValue == p["dtype"] as? String, "\(key): dtype")
                    #expect(s.data.shape == p["shape"] as? [Int], "\(key): shape")
                    let digest = sha(s.data.bytes)
                    #expect(digest == p["data_sha256"] as? String, "\(key): data")
                    #expect(s.title == p["title"] as? String, "\(key): title")
                    let axes = try #require(p["axes"] as? [[String: Any]])
                    #expect(s.axes.count == axes.count, "\(key): axis count")
                    for (a, q) in zip(s.axes, axes) {
                        let name = q["name"] as? String ?? "?"
                        #expect(a.name == name, "\(key): axis name")
                        #expect(a.size == q["size"] as? Int, "\(key): \(name) size")
                        #expect(hex(a.scale) == q["scale_bits"] as? String, "\(key): \(name) scale")
                        #expect(hex(a.offset) == q["offset_bits"] as? String, "\(key): \(name) offset")
                        #expect(a.units == (q["units"] as? String ?? ""), "\(key): \(name) units")
                    }
                    #expect(policyKeys(s) == [Self.prefix + "grid"], "\(key): the grid flag, and only it")
                    equalSignals += 1
                }
            }
            #expect(equalSignals == 8)
            #expect { _ = try read(path) } throws: { "\($0)".contains("ScanSize x ScanArea") }
            #expect { _ = try read(path, .init(policy: VeloxReadPolicy(spectrumImageGrid: .firstImageChecked))) } throws: { "\($0)".contains("ScanSize x ScanArea") }
        }

        /// `.scanSizeTimesArea` decodes onto the stream's 4 x 3 grid: the planted counts are 12 events in stream order, so the
        /// bytes are `.firstImage`'s with the axes 4 (y) by 3 (x). The flag names the grid used and the other.
        @Test func testScanSizeTimesAreaDecodesOntoTheStreamsGrid() throws {
            let path = planted("si-planted-grid.emd")
            let first = try read(path, .init(policy: VeloxReadPolicy(spectrumImageGrid: .firstImage)))[0]
            let scan = try read(path, .init(policy: VeloxReadPolicy(spectrumImageGrid: .scanSizeTimesArea)))[0]
            #expect(first.data.shape == [3, 4, 8])
            #expect(scan.data.shape == [4, 3, 8])
            #expect(scan.data.dataType == first.data.dataType)
            #expect(scan.data.bytes == first.data.bytes, "the same stream, in the same flat order")
            #expect(scan.axes.map(\.name) == ["y", "x", "X-ray energy"])
            #expect(scan.axes[0].size == 4)
            #expect(scan.axes[1].size == 3)
            #expect(abs(scan.axes[1].scale - 2) < 1e-12 && scan.axes[1].units == "nm", "2 nm a pixel through the 3-pixel factor")
            let flag = try #require(scan.metadata[Self.prefix + "grid"])
            #expect(flag.value.text == "4 x 3")
            #expect(flag.provenance.rule.hasPrefix("FormatoKit policy, not RosettaSciIO's"))
            #expect(flag.provenance.rule.contains("3 x 4"), "the other grid is named")
            #expect(policyKeys(scan) == [Self.prefix + "grid"])
        }

        /// A file whose grids agree reaches no grid branch: either choice returns the default's signals and no policy key.
        @Test func testGridChoicesOnAFileWhoseGridsAgreeAreTheDefault() throws {
            for name in ["si-planted-v9.emd", "si-planted-v11.emd"] {
                let byDefault = try read(planted(name))
                #expect(byDefault.flatMap(policyKeys).isEmpty, "\(name): the default carries no policy key")
                for choice in [VeloxGridChoice.firstImage, .scanSizeTimesArea] {
                    let other = try read(planted(name), .init(policy: VeloxReadPolicy(spectrumImageGrid: choice)))
                    #expect(other == byDefault, "\(name) \(choice)")
                }
            }
        }

        // MARK: P1, an unhandled pixel unit

        /// `si-units-px.emd`: PixelUnitX "px" in the image and the stream, width 0.5, height 0.25, Offset x 1, y 2 (literals of
        /// the generator). The default refuses; `.keepAsWritten` carries the numbers and the unit as written.
        @Test func testKeepAsWrittenCarriesAnUnhandledUnit() throws {
            let path = policyFile("si-units-px.emd")
            #expect { _ = try read(path) } throws: { "\($0)".contains("pixel units") && "\($0)".contains("px") }
            let keep = VeloxReadPolicy(unconvertedUnits: .keepAsWritten)
            let s = try #require(try read(path, .init(policy: keep)).first)
            #expect(s.axes.map(\.name) == ["y", "x", "X-ray energy"])
            let (y, x) = (s.axes[0], s.axes[1])
            #expect(y.scale.bitPattern == (0.25).bitPattern)
            #expect(y.offset.bitPattern == (2.0).bitPattern)
            #expect(x.scale.bitPattern == (0.5).bitPattern)
            #expect(x.offset.bitPattern == (1.0).bitPattern)
            #expect(y.units == "px" && x.units == "px")
            #expect(y.size == 2 && x.size == 3)
            #expect(s.axes[2].units == "keV", "only the pixel axes are the policy's")
            // The same draw as si-planted-v9.emd: the same counts.
            let twin = try #require(try read(planted("si-planted-v9.emd")).first)
            #expect(s.data.shape == twin.data.shape)
            #expect(s.data.dataType == twin.data.dataType)
            #expect(s.data.bytes == twin.data.bytes)
            let flag = try #require(s.metadata[Self.prefix + "units"])
            #expect(flag.value.text == "px")
            #expect(flag.provenance.rule.hasPrefix("FormatoKit policy, not RosettaSciIO's"))
            #expect(flag.provenance.source.hasSuffix("BinaryResult.PixelUnitX"))
            #expect(policyKeys(s) == [Self.prefix + "units"])
        }

        /// The first image of the same file: `VeloxImageSignals(path:policy:)` refuses by default, keeps the unit as written
        /// under the policy, and says so.
        @Test func testKeepAsWrittenOnTheImagePath() throws {
            let path = policyFile("si-units-px.emd")
            let byDefault = try VeloxImageSignals(path: path)
            #expect(throws: FormatoReadError.self) { _ = try byDefault.signal(byDefault.images[0]) }
            let kept = try VeloxImageSignals(path: path, policy: VeloxReadPolicy(unconvertedUnits: .keepAsWritten))
            let signal = try kept.signal(kept.images[0])
            #expect(signal.axes.map(\.name) == ["y", "x"])
            #expect(signal.axes[0].scale.bitPattern == (0.25).bitPattern)
            #expect(signal.axes[0].offset.bitPattern == (2.0).bitPattern)
            #expect(signal.axes[1].scale.bitPattern == (0.5).bitPattern)
            #expect(signal.axes[1].offset.bitPattern == (1.0).bitPattern)
            #expect(signal.axes.map(\.units) == ["px", "px"])
            #expect(signal.metadata[Self.prefix + "units"]?.value.text == "px")
        }

        /// A handled unit never reaches the policy: the signals equal the default's, exactly, with no policy key.
        @Test func testKeepAsWrittenLeavesAHandledUnitAlone() throws {
            let keep = VeloxReadPolicy(unconvertedUnits: .keepAsWritten)
            for name in ["si-planted-v9.emd", "si-planted-v11.emd", "si-planted-eels.emd"] {
                let byDefault = try read(planted(name))
                let kept = try read(planted(name), .init(policy: keep))
                #expect(kept == byDefault, "\(name)")
                #expect(kept.flatMap(policyKeys).isEmpty, "\(name): no policy key")
            }
            let defaultImages = try VeloxImageSignals(path: planted("si-planted-v9.emd"))
            let keptImages = try VeloxImageSignals(path: planted("si-planted-v9.emd"), policy: keep)
            let a = try defaultImages.signal(defaultImages.images[0]).load()
            let b = try keptImages.signal(keptImages.images[0]).load()
            #expect(a == b)
        }

        /// Where Pint raises, `.keepAsWritten` still refuses (the calibration both readers share): "nm" whose value underflows
        /// to 0 m is `pintRaises`, a unit FormatoUnits does not handle is the policy's.
        @Test func testAPintRaiseStaysARefusalUnderKeepAsWritten() {
            let keep = VeloxReadPolicy(unconvertedUnits: .keepAsWritten)
            let refuse = VeloxReadPolicy()
            func make(_ width: Double, _ unit: String, _ policy: VeloxReadPolicy) -> VeloxPixelCalibration? {
                VeloxPixelCalibration.make(width: width, height: 0.25, offsetX: 1, offsetY: 2, unit: unit, factor: 2, policy: policy)
            }
            #expect(make(5e-324, "nm", keep) == nil, "Pint raises on 0 m")
            #expect(make(5e-324, "nm", refuse) == nil)
            #expect(make(0.5, "px", refuse) == nil)
            let kept = make(0.5, "px", keep)
            #expect(kept?.keptAsWritten == true)
            #expect(kept?.scaleX.bitPattern == (0.5).bitPattern)
            #expect(kept?.offsetY.bitPattern == (2.0).bitPattern)
            #expect(kept?.units == "px")
            let handled = make(2e-9, "m", keep)
            #expect(handled?.keptAsWritten == false)
            #expect(handled?.units == "nm")
        }

        // MARK: P3, the array cap

        /// si-planted-v9.emd's one array is (2, 3, 8) int8, 48 bytes: a cap of 48 reads it, 47 refuses it.
        @Test func testArrayCapAtItsBoundary() throws {
            let path = planted("si-planted-v9.emd")
            let byDefault = try read(path)
            let exact = try read(path, .init(policy: VeloxReadPolicy(maximumArrayBytes: 48)))
            #expect(exact == byDefault)
            #expect { _ = try read(path, .init(policy: VeloxReadPolicy(maximumArrayBytes: 47))) } throws: {
                "\($0)".contains("47 bytes the policy allows")
            }
            #expect(throws: FormatoReadError.self) { _ = try read(path, .init(policy: VeloxReadPolicy(maximumArrayBytes: 0))) }
        }

        /// The EELS arrays (60 bytes each) are read whole under the same cap, then the EDS one (2, 3, 8) uint16, 96 bytes.
        @Test func testArrayCapOnTheEELSAndEDSArrays() throws {
            let path = planted("si-planted-eels.emd")
            let byDefault = try read(path)
            #expect(try read(path, .init(policy: VeloxReadPolicy(maximumArrayBytes: 96))) == byDefault)
            #expect { _ = try read(path, .init(policy: VeloxReadPolicy(maximumArrayBytes: 95))) } throws: {
                "\($0)".contains("95 bytes the policy allows")
            }
            #expect { _ = try read(path, .init(policy: VeloxReadPolicy(maximumArrayBytes: 59))) } throws: { "\($0)".contains("refused here on purpose") }
        }

        // MARK: P8, the block size

        /// Blocks of 1 and 3 values read the same arrays as the default block, exactly, on a file whose last frame stops
        /// early, one whose frames the markers count, and four streams.
        @Test func testBlockSizeChangesNoResult() throws {
            for name in ["si-planted-v9.emd", "si-planted-endframe.emd", "sk-4streams-2frames.emd"] {
                for opts in [VeloxSpectrumImageOptions(), VeloxSpectrumImageOptions(sumFrames: false)] {
                    let byDefault = try read(planted(name), opts)
                    for block in [1, 3] {
                        var small = opts
                        small.policy.streamBlockValues = block
                        #expect(try read(planted(name), small) == byDefault, "\(name) block \(block) sumFrames \(opts.sumFrames)")
                    }
                }
            }
        }

        /// The option is used: a read polls for cancellation once per block, so blocks of 1 and 3 values poll about
        /// (stream length) and (stream length / 3) times. si-planted-v9.emd's stream holds 274 values; its frames come from the
        /// markers, so the stream is read twice (a count of the markers, then the fill).
        @Test func testBlockSizeMakesTheBlocks() throws {
            let path = planted("si-planted-v9.emd")
            func polls(_ block: Int) throws -> Int {
                let counter = Polls()
                var opts = VeloxSpectrumImageOptions()
                opts.policy.streamBlockValues = block
                _ = try VeloxSpectrumImageSignals(path: path, options: opts, cancelled: { counter.tick() })
                return counter.count
            }
            let one = try polls(1), three = try polls(3), whole = try polls(VeloxReadPolicy().streamBlockValues)
            #expect(one >= 274, "a block a value: \(one) polls")
            #expect(three >= 92 && three < one, "a block of three: \(three) polls")
            #expect(whole < 10, "the default block holds the whole stream: \(whole) polls")
            // A block size below 1 is a block of 1, not a hang or a trap.
            #expect(try polls(0) == one)
        }
    }
}
