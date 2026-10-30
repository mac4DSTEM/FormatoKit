//
//  VeloxSpectrumElementsTests.swift
//  `Sample.elements`, the four file-level metadata groups and the segment times of Velox single spectra.
//  Files: Fixtures/elements (tools/velox-elements/pins.py: planted with h5py, read by RosettaSciIO 049e7d70, the mapping applied with
//  HyperSpy 2.4.0's DictionaryTreeBrowser as `dict2signal` applies it). Exact: the element list as HyperSpy sets it, or the refusal
//  where RosettaSciIO or HyperSpy raises; the times to the bit against `float()` of RosettaSciIO's `original_metadata`. RosettaSciIO
//  has no rule for which segments a spectrum's times are: the test re-derives the kit's documented rule from the pinned entries, so
//  it pins the stored values, not the rule.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    @Suite struct VeloxSpectrumElementsTests {
        static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/elements")

        struct Number: Decodable { let value: Double?; let bits: String }
        struct Detector: Decodable {
            let name: String?; let type: String?; let enabled: String?
            let liveTimeS: Number?; let realTimeS: Number?
        }
        struct Elements: Decodable { let value: [String]?; let raises: String? }
        struct Spectrum: Decodable { let binaryResultDetector: String?; let detectors: [Detector]; let elements: Elements? }
        enum File: Decodable {
            case raises(String), spectra([Spectrum])
            init(from decoder: Decoder) throws {
                if let list = try? [Spectrum](from: decoder) { self = .spectra(list); return }
                struct Raise: Decodable { let raises: String }
                self = .raises(try Raise(from: decoder).raises)
            }
        }
        struct Pins: Decodable { let files: [String: File] }

        static func pins() throws -> Pins {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Pins.self, from: Data(contentsOf: dir.appendingPathComponent("velox-elements-pins.json")))
        }
        static func path(_ name: String) -> String { dir.appendingPathComponent(name + ".emd").path }
        private func bits(_ x: Double?) -> String? { x.map { String(format: "%016llx", $0.bitPattern) } }

        @Test func testThePinsCoverEveryCase() throws {
            let files = try Self.pins().files
            #expect(files.count == 20)
            let read = files.values.filter { if case .spectra(let s) = $0 { return s.allSatisfy { $0.elements?.raises == nil } }; return false }
            #expect(read.count == 10)
            for name in files.keys { #expect(FileManager.default.fileExists(atPath: Self.path(name)), "\(name)") }
        }

        /// The refusal `VeloxSpectrumSignals` gives where RosettaSciIO or HyperSpy raises: `unsupported`, naming RosettaSciIO.
        private func expectRefused(_ name: String, _ why: String) {
            #expect(FileManager.default.fileExists(atPath: Self.path(name)), "\(name)")
            do {
                _ = try VeloxSpectrumSignals(path: Self.path(name))
                Issue.record("\(name): read, where \(why)")
            } catch let FormatoReadError.unsupported(message) {
                #expect(message.contains("RosettaSciIO raises"), "\(name): \(message)")
            } catch {
                Issue.record("\(name): \(error), not the refusal, where \(why)")
            }
        }

        @Test func testSlugifyAsHyperSpy() {
            let table = ["0b4c": "Number_0b4c", "B111": "B111", "element-Selection": "elementSelection", "_a": "_a", " a b ": "a_b",
                         "": "Number_", "é1": "e1", "1-2": "Number_12", "a.b": "ab"]
            // Checked against HyperSpy 2.4.0's slugify(key, valid_variable_name=True).
            for (key, slug) in table { #expect(VeloxSampleElements.slugify(key) == slug, "\(key)") }
        }

        @Test func testSampleElementsAsHyperSpySetsThem() throws {
            for (name, file) in try Self.pins().files.sorted(by: { $0.key < $1.key }) {
                switch file {
                case .raises(let why):
                    expectRefused(name, "RosettaSciIO raises \(why)")
                case .spectra(let spectra) where spectra.contains(where: { $0.elements?.raises != nil }):
                    expectRefused(name, "HyperSpy raises in the mapping")
                case .spectra(let spectra):
                    let signals = try VeloxSpectrumSignals(path: Self.path(name)).signals
                    #expect(signals.count == spectra.count, "\(name)")
                    for (signal, pin) in zip(signals, spectra) {
                        #expect(signal.metadata["Sample.elements"]?.value.texts == pin.elements?.value, "\(name)")
                        #expect(signal.metadata["Sample.elements"].map { $0.value.texts != nil } ?? true, "\(name)")
                    }
                }
            }
        }

        @Test func testTheProvenanceNamesTheEntryHyperSpyTakes() throws {
            let signal = try #require(try VeloxSpectrumSignals(path: Self.path("el-v11-two-settings")).signals.first)
            let entry = try #require(signal.metadata["Sample.elements"])
            #expect(entry.value == .texts(["Ca", "Cu", "H", "Uue"]))
            #expect(entry.provenance.source == "SharedProperties/EDSSpectrumQuantificationSettings/0b4c.elementSelection")
            let v4 = try #require(try VeloxSpectrumSignals(path: Self.path("el-v4")).signals.first)
            #expect(v4.metadata["Sample.elements"]?.provenance.source == "Operations/ImageQuantificationOperation/80e138836ebd4b7aad5be7d3dd071f47.elementSelection")
        }

        @Test func testTheSegmentTimesOfEachSpectrum() throws {
            for (name, file) in try Self.pins().files.sorted(by: { $0.key < $1.key }) {
                guard case .spectra(let spectra) = file else { continue }
                let metadata = try VeloxEMDReader(path: Self.path(name)).spectrumMetadata()
                #expect(metadata.count == spectra.count, "\(name)")
                for (m, pin) in zip(metadata, spectra) {
                    #expect(m.binaryResultDetector == pin.binaryResultDetector)
                    let named = pin.binaryResultDetector ?? ""
                    let expected = pin.detectors.filter { $0.type == "AnalyticalDetector" && $0.enabled != "false" && ($0.name ?? "").contains(named) }
                    let times = m.binaryResultSegmentTimes
                    #expect(times.map(\.name) == expected.map { $0.name ?? "" }, "\(name)")
                    #expect(times.map { bits($0.liveTimeSeconds) } == expected.map { $0.liveTimeS?.bits }, "\(name)")
                    #expect(times.map { bits($0.realTimeSeconds) } == expected.map { $0.realTimeS?.bits }, "\(name)")
                }
            }
            // Velox 4, "SuperXG2": all four segments, one common time; Velox 6, "SuperXG24": the one segment; Velox 13: the disabled one left out.
            let v4 = try VeloxEMDReader(path: Self.path("el-v4")).spectrumMetadata()[0]
            #expect(v4.binaryResultSegmentTimes.count == 4 && v4.commonLiveTimeSeconds == 10.061437738684702)
            let v6 = try VeloxEMDReader(path: Self.path("el-v6-one-segment")).spectrumMetadata()[0]
            #expect(v6.binaryResultSegmentTimes.map(\.name) == ["SuperXG24"] && v6.commonLiveTimeSeconds == nil)
            let v13 = try VeloxEMDReader(path: Self.path("el-v13-disabled")).spectrumMetadata()[0]
            #expect(v13.binaryResultSegmentTimes.map(\.name) == ["UltraX1", "UltraX2", "UltraX4"])
        }

        /// RosettaSciIO's public Velox files, unzipped by tools/test.sh: the elements of each single spectrum.
        @Test func testThePublicFiles() throws {
            struct PublicSpectrum: Decodable { let elements: Elements? }
            struct Public: Decodable { let `public`: [String: [PublicSpectrum]] }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let pins = try decoder.decode(Public.self, from: Data(contentsOf: Self.dir.appendingPathComponent("velox-elements-pins.json")))
            #expect(pins.public["velox_emd_version11.zip/Test SI 16x16 215 kx.emd"]?.first?.elements?.value == ["C", "O", "Ca", "Cu"])
            let root = Self.dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let present = pins.public.filter {
                FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/rsciio-unzipped/emd/" + $0.key).path)
            }
            guard !present.isEmpty else { return }   // not unzipped (a clone without References): the planted files stand
            #expect(present.count == pins.public.count, "every public file is unzipped or none")
            for (name, spectra) in present.sorted(by: { $0.key < $1.key }) {
                let signals = try VeloxSpectrumSignals(path: root.appendingPathComponent(".build/rsciio-unzipped/emd/" + name).path).signals
                #expect(signals.map { $0.metadata["Sample.elements"]?.value.texts } == spectra.map { $0.elements?.value }, "\(name)")
            }
        }

        @Test func testAFileWhoseSpectraRosettaSciIODoesNotReadGivesNoMetadata() throws {
            let spectra = Self.dir.deletingLastPathComponent().appendingPathComponent("spectra")
            #expect(try VeloxEMDReader(path: spectra.appendingPathComponent("sp-images-only.emd").path).spectrumMetadata().isEmpty)
            #expect(try VeloxEMDReader(path: spectra.appendingPathComponent("sp-none.emd").path).spectrumMetadata().isEmpty)
            #expect(try VeloxEMDReader(path: spectra.appendingPathComponent("sp-two.emd").path).spectrumMetadata().count == 2)
        }
    }
}
