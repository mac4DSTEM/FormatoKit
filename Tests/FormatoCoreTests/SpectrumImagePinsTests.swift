//
//  SpectrumImagePinsTests.swift
//  Gate P4 and the kernel pins of docs/registration-step-4.md: every (file, option set) of Fixtures/step-4-pins.json
//  (tools/step-4/pins.py: RosettaSciIO 049e7d70's `file_reader(select_type="spectrum_image", lazy=False)` with sparse and
//  numba) against `VeloxSpectrumImageSignals`: where RosettaSciIO raises, FormatoKit refuses; where it reads, the signals in
//  order are equal in type, shape, data sha256, every axis field bit for bit, title, signal type and metadata with source.
//  The registered deviations (registration §3.3, §3.5, §3.6) are refused by name: the pins' `deviations`, and the runs whose
//  axes RosettaSciIO leaves without a number or of another size than the data. And RosettaSciIO's `stream_to_array` on the
//  synthetic streams of the kernel pins, byte for byte.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoEMD

@Suite(.serialized) struct SpectrumImagePinsTests {
    private static let planted = TestPaths.root.appendingPathComponent("Tests/FormatoEMDTests/Fixtures/step4")

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func locate(_ file: [String: Any]) -> URL? {
        let path = file["path"] as! String
        let url: URL
        switch file["set"] as! String {
        case "public":
            let parts = path.split(separator: "/")
            url = parts.count == 3 && parts[1].hasSuffix(".zip")
                ? TestPaths.unzipped.appendingPathComponent(path) : TestPaths.rsciioData.appendingPathComponent(path)
        default:
            url = Self.planted.appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func options(_ o: [String: Any]) throws -> VeloxSpectrumImageOptions {
        var out = VeloxSpectrumImageOptions()
        for (key, value) in o {
            switch key {
            case "first_frame": out.firstFrame = value as! Int
            case "last_frame": out.lastFrame = value as? Int
            case "sum_frames": out.sumFrames = value as! Bool
            case "sum_EDS_detectors": out.sumEDSDetectors = value as! Bool
            case "rebin_energy": out.rebinEnergy = value as! Int
            case "SI_dtype":
                out.dataType = FormatoDataType(rawValue: value as! String)
                #expect(out.dataType != nil, "SI_dtype \(value) names a FormatoDataType")
            default: Issue.record("unknown option \(key)")
            }
        }
        return out
    }

    /// Whether the pins name this run a registered deviation (refused here although RosettaSciIO reads).
    private func isDeviation(_ path: String, _ o: [String: Any], _ deviations: [String: [String]]) -> Bool {
        guard let d = deviations[path] else { return false }
        switch d[0] {
        case "all": return true
        case "unsummed": return o["sum_EDS_detectors"] as? Bool == false
        default: Issue.record("unknown deviation kind \(d[0])"); return false
        }
    }

    private func assertSignal(_ s: FormatoSignal, _ p: [String: Any], _ what: String) {
        #expect(s.data.dataType.rawValue == p["dtype"] as? String, "\(what): dtype")
        #expect(s.data.shape == p["shape"] as? [Int], "\(what): shape")
        #expect(sha(s.data.bytes) == p["data_sha256"] as? String, "\(what): data")
        #expect(s.title == p["title"] as? String, "\(what): title")
        #expect(s.signalType == p["signal_type"] as? String, "\(what): signal type")
        let axes = p["axes"] as! [[String: Any]]
        #expect(s.axes.count == axes.count, "\(what): axis count")
        for (k, (a, q)) in zip(s.axes, axes).enumerated() {
            #expect(a.name == q["name"] as? String, "\(what) axis \(k) name")
            #expect(a.size == q["size"] as? Int, "\(what) axis \(k) size")
            #expect(hex(a.scale) == q["scale_bits"] as? String, "\(what) axis \(k) scale \(a.scale) vs \(q["scale"] ?? "nil")")
            #expect(hex(a.offset) == q["offset_bits"] as? String, "\(what) axis \(k) offset \(a.offset) vs \(q["offset"] ?? "nil")")
            #expect(a.units == (q["units"] as? String ?? ""), "\(what) axis \(k) units (none is \"\")")
            #expect(a.navigate == q["navigate"] as? Bool, "\(what) axis \(k) navigate")
        }
        let md = p["metadata"] as! [[String: Any]]
        #expect(Set(s.metadata.keys) == Set(md.map { $0["key"] as! String }), "\(what): metadata keys")
        for e in md {
            let key = e["key"] as! String
            guard let ours = s.metadata[key] else { continue }
            if e["kind"] as? String == "number" {
                #expect(ours.value.number.map(hex) == e["value_bits"] as? String, "\(what): \(key)")
            } else {
                #expect(ours.value.text == e["value"] as? String, "\(what): \(key)")
            }
            if let source = e["source"] as? String {
                #expect(ours.provenance.source.hasSuffix(source), "\(what): \(key) source \(ours.provenance.source) vs \(source)")
            }
            #expect(!ours.provenance.rule.isEmpty, "\(what): \(key) has no rule")
        }
    }

    @Test func testEveryPinnedSpectrumImageAgreesOrIsRefused() throws {
        let doc = try loadJSON("step-4-pins.json")
        let files = try #require(doc["files"] as? [[String: Any]])
        let deviations = doc["deviations"] as? [String: [String]] ?? [:]
        let referencesPresent = FileManager.default.fileExists(atPath: TestPaths.rsciioData.path)
        var runs = 0, raised = 0, deviated = 0, signals = 0, files_ = 0
        for f in files {
            let path = f["path"] as! String
            guard let url = locate(f) else {
                if f["set"] as? String != "public" || referencesPresent { Issue.record("\(path): not found") }
                continue
            }
            #expect(sha(try Data(contentsOf: url)) == f["sha256"] as? String, "\(path): not the pinned file")
            files_ += 1
            let byOption = f["runs"] as! [String: [String: Any]]
            for key in byOption.keys.sorted() {
                let run = byOption[key]!, what = "\(path) \(key)"
                let o = run["options"] as! [String: Any]
                let pinned = run["signals"] as! [[String: Any]]
                runs += 1
                let refusedByRule = isDeviation(path, o, deviations)
                    || pinned.contains { $0["axes_numeric"] as? Bool == false || $0["axes_sizes_match_shape"] as? Bool == false }
                if run["raises"] as? [String: Any] != nil || refusedByRule {
                    if run["raises"] as? [String: Any] != nil { raised += 1 } else { deviated += 1 }
                    #expect(throws: (any Error).self, "\(what): RosettaSciIO \(run["raises"].map { "raises \($0)" } ?? "reads (a registered deviation)"); FormatoKit read it") {
                        _ = try VeloxSpectrumImageSignals(path: url.path, options: try options(o))
                    }
                    continue
                }
                let ours: VeloxSpectrumImageSignals
                do { ours = try VeloxSpectrumImageSignals(path: url.path, options: try options(o)) } catch {
                    Issue.record("\(what): RosettaSciIO reads, FormatoKit refuses: \(error)"); continue
                }
                #expect(ours.signals.count == pinned.count, "\(what): signal count")
                for (i, (s, p)) in zip(ours.signals, pinned).enumerated() {
                    assertSignal(s, p, "\(what) #\(i)")
                    signals += 1
                }
            }
        }
        print("SpectrumImagePins: \(files_) files, \(runs) runs: \(signals) signals equal, \(raised) refused where RosettaSciIO raises, \(deviated) registered deviations")
        if referencesPresent {
            #expect(files_ == files.count)
            #expect(runs == 226)
            #expect(raised == 34)
            #expect(deviated == 9, "the grid file's 8 reads (its O9 and O10 raise) and the bin counts' unsummed read")
            #expect(signals == 244 - 8 - 2, "every signal RosettaSciIO returns outside the deviations")
        }
    }

    /// The owner's spectrum image (registration step 4 §2): run by tools/step-4/owner-check.sh, which writes RosettaSciIO's
    /// reading with `pins.py --owner` and passes FORMATO_OWNER_SI_PINS and FORMATO_OWNER_SI_FILE. Never part of the gate.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORMATO_OWNER_SI_PINS"] != nil,
                   "the owner's spectrum image is checked by tools/step-4/owner-check.sh only"))
    func testOwnerSpectrumImages() throws {
        let env = ProcessInfo.processInfo.environment
        let pins = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try #require(env["FORMATO_OWNER_SI_PINS"])))) as! [String: Any]
        let file = try #require((pins["files"] as? [[String: Any]])?.first)
        let path = try #require(env["FORMATO_OWNER_SI_FILE"])
        for (key, run) in (file["runs"] as! [String: [String: Any]]).sorted(by: { $0.key < $1.key }) {
            let start = Date()
            let o = run["options"] as! [String: Any]
            #expect(run["raises"] as? [String: Any] == nil, "\(key): RosettaSciIO raises")
            let ours = try VeloxSpectrumImageSignals(path: path, options: try options(o))
            let pinned = run["signals"] as! [[String: Any]]
            #expect(ours.signals.count == pinned.count, "\(key): signal count")
            for (i, (s, p)) in zip(ours.signals, pinned).enumerated() { assertSignal(s, p, "owner \(key) #\(i)") }
            print("OwnerSI: \(key) \(o): \(ours.signals.map { "\($0.data.dataType.rawValue)\($0.data.shape)" }) equal, \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
    }

    /// RosettaSciIO's `stream_to_array` (jitted) on the kernel pins' synthetic streams.
    @Test func testKernelEqualsRosettaSciIOStreamToArray() throws {
        let cases = try #require(try loadJSON("step-4-pins.json")["kernel"] as? [[String: Any]])
        #expect(cases.count == 20)
        for c in cases {
            let name = c["name"] as! String
            var stream: [UInt16] = []
            for run in c["runs"] as! [[Int]] { stream += [UInt16](repeating: UInt16(run[0]), count: run[1]) }
            let a = try veloxStreamToArray(
                stream, ny: c["ny"] as! Int, nx: c["nx"] as! Int, channels: c["channels"] as! Int,
                firstFrame: c["first_frame"] as! Int, lastFrame: c["last_frame"] as! Int, rebinEnergy: c["rebin_energy"] as! Int,
                sumFrames: c["sum_frames"] as! Bool, dataType: try #require(FormatoDataType(rawValue: c["dtype"] as! String)))
            #expect(a.shape == c["shape"] as? [Int], "\(name): shape")
            #expect(sha(a.bytes) == c["data_sha256"] as? String, "\(name): data")
        }
    }
}
