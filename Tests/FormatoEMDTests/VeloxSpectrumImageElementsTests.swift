//
//  VeloxSpectrumImageElementsTests.swift
//  `Sample.elements` of Velox spectrum images. Files: Fixtures/elements/si-el-*.emd (tools/velox-elements/pins.py: planted with
//  h5py, read by RosettaSciIO 049e7d70 with `select_type="spectrum_image"`, the mapping applied with HyperSpy 2.4.0's
//  DictionaryTreeBrowser as `dict2signal` applies it), once with the defaults and once with `sum_EDS_detectors=False`. Exact: per
//  signal the element list as HyperSpy sets it (none on EELS), or the refusal where RosettaSciIO or HyperSpy raises.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    @Suite struct VeloxSpectrumImageElementsTests {
        static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/elements")

        struct Elements: Decodable { let value: [String]?; let raises: String? }
        struct Signal: Decodable { let title: String; let signalType: String; let elements: Elements? }
        enum File: Decodable {
            case raises(String), signals([Signal])
            init(from decoder: Decoder) throws {
                if let list = try? [Signal](from: decoder) { self = .signals(list); return }
                struct Raise: Decodable { let raises: String }
                self = .raises(try Raise(from: decoder).raises)
            }
            /// RosettaSciIO raises, or HyperSpy raises in the mapping of one of the signals.
            var raises: Bool {
                switch self {
                case .raises: return true
                case .signals(let s): return s.contains { $0.elements?.raises != nil }
                }
            }
        }
        struct Pins: Decodable {
            let spectrumImages: [String: [String: File]]
            let publicSpectrumImages: [String: File]
        }

        static func pins() throws -> Pins {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Pins.self, from: Data(contentsOf: dir.appendingPathComponent("velox-elements-pins.json")))
        }
        static func path(_ name: String) -> String { dir.appendingPathComponent(name + ".emd").path }
        static func options(_ run: String) -> VeloxSpectrumImageOptions {
            VeloxSpectrumImageOptions(sumEDSDetectors: run != "per_stream")
        }

        private func expectMatches(_ file: File, path: String, options: VeloxSpectrumImageOptions, _ label: String) throws {
            switch file {
            case _ where file.raises:
                do {
                    _ = try VeloxSpectrumImageSignals(path: path, options: options)
                    Issue.record("\(label): read, where RosettaSciIO or HyperSpy raises")
                } catch let FormatoReadError.unsupported(message) {
                    #expect(message.contains("RosettaSciIO raises"), "\(label): \(message)")
                }
            case .signals(let pins):
                let signals = try VeloxSpectrumImageSignals(path: path, options: options).signals
                #expect(signals.map(\.title) == pins.map(\.title), "\(label)")
                #expect(signals.map(\.signalType) == pins.map(\.signalType), "\(label)")
                #expect(signals.map { $0.metadata["Sample.elements"]?.value.texts } == pins.map { $0.elements?.value }, "\(label)")
                // An entry, when there is one, is a list of texts.
                #expect(signals.allSatisfy { $0.metadata["Sample.elements"].map { $0.value.texts != nil } ?? true }, "\(label)")
            case .raises:
                break
            }
        }

        @Test func testThePinsCoverEveryCase() throws {
            let files = try Self.pins().spectrumImages
            #expect(files.count == 8)
            // The pruned file returns no signal, so the bad selection it carries is never mapped.
            if case .signals(let pruned) = files["si-el-pruned-z-120"]?["default"] { #expect(pruned.isEmpty) } else { Issue.record("si-el-pruned-z-120") }
            #expect(files.values.allSatisfy { Set($0.keys) == ["default", "per_stream"] })
            #expect(files.values.filter { $0["default"]!.raises }.count == 2)
            for name in files.keys { #expect(FileManager.default.fileExists(atPath: Self.path(name)), "\(name)") }
        }

        @Test func testSampleElementsAsHyperSpySetsThem() throws {
            for (name, runs) in try Self.pins().spectrumImages.sorted(by: { $0.key < $1.key }) {
                for (run, file) in runs.sorted(by: { $0.key < $1.key }) {
                    try expectMatches(file, path: Self.path(name), options: Self.options(run), "\(name) \(run)")
                }
            }
        }

        @Test func testTheProvenanceNamesTheEntryHyperSpyTakes() throws {
            let v11 = try #require(try VeloxSpectrumImageSignals(path: Self.path("si-el-v11")).signals.first)
            let entry = try #require(v11.metadata["Sample.elements"])
            #expect(entry.value == .texts(["Ca", "Cu", "O"]))
            #expect(entry.provenance.source == "SharedProperties/EDSSpectrumQuantificationSettings/0b4c.elementSelection")
            let v9 = try #require(try VeloxSpectrumImageSignals(path: Self.path("si-el-v9")).signals.first)
            #expect(v9.metadata["Sample.elements"]?.provenance.source
                    == "Operations/ImageQuantificationOperation/80e138836ebd4b7aad5be7d3dd071f47.elementSelection")
        }

        /// RosettaSciIO's public Velox spectrum-image files, unzipped by tools/test.sh. A file this reader refuses on purpose (a
        /// registered deviation, e.g. the grid check) is left out; every other file matches.
        @Test func testThePublicFiles() throws {
            let pins = try Self.pins().publicSpectrumImages
            guard case .signals(let test) = try #require(pins["velox_emd_version11.zip/Test SI 16x16 215 kx.emd"]) else {
                Issue.record("Test SI 16x16 215 kx.emd: RosettaSciIO raises"); return
            }
            // RosettaSciIO's own test of that file.
            #expect(test.last?.elements?.value == ["C", "O", "Ca", "Cu"])
            let root = Self.dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let present = pins.filter {
                FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/rsciio-unzipped/emd/" + $0.key).path)
            }
            guard !present.isEmpty else { return }   // not unzipped (a clone without References): the planted files stand
            #expect(present.count == pins.count, "every public file is unzipped or none")
            var compared = 0
            for (name, file) in present.sorted(by: { $0.key < $1.key }) {
                let path = root.appendingPathComponent(".build/rsciio-unzipped/emd/" + name).path
                guard case .signals(let pinned) = file, !file.raises else {
                    try expectMatches(file, path: path, options: VeloxSpectrumImageOptions(), name); continue
                }
                let signals: [FormatoSignal]
                do {
                    signals = try VeloxSpectrumImageSignals(path: path).signals
                } catch let FormatoReadError.unsupported(message) where message.contains("refused here on purpose") {
                    continue
                }
                #expect(signals.map(\.title) == pinned.map(\.title), "\(name)")
                #expect(signals.map { $0.metadata["Sample.elements"]?.value.texts } == pinned.map { $0.elements?.value }, "\(name)")
                compared += 1
            }
            #expect(compared >= 3, "most public files are compared")
        }
    }
}
