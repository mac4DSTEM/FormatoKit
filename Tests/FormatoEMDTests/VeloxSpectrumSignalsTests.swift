import Testing
import Foundation
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    /// `VeloxSpectrumSignals` against RosettaSciIO's `select_type="single_spectrum"` (tools/velox-spectrum/pins.py): data bytes,
    /// axes, the General and Signal metadata and the HyperSpy mapping, under four time zones; and the planted literals typed by hand.
    @Suite final class VeloxSpectrumSignalsTests {
        private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

        private func read(_ name: String, zone: String? = nil) throws -> [FormatoSignal] {
            try read(path: Self.fixtures.appendingPathComponent("spectra/\(name).emd").path, zone: zone)
        }

        private func read(path: String, zone: String?) throws -> [FormatoSignal] {
            try VeloxSpectrumSignals(path: path, timeZone: zone.flatMap { TimeZone(identifier: $0) }).signals
        }

        /// The public files of RosettaSciIO's clone, unzipped by tools/test.sh; nil when absent.
        private func publicPath(_ key: String) -> String? {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let path = root.appendingPathComponent(".build/rsciio-unzipped/emd/\(parts[0])/\(parts[1])").path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        private func sha(_ a: FormatoArray) -> String {
            var hasher = SHA256Hex()
            return hasher.hex(a.bytes)
        }

        @Test func testEveryPinnedCaseEqualsRosettaSciIO() throws {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("spectra-pins.json"))
            let pins = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let cases = try #require(pins["cases"] as? [String: [String: Any]])
            #expect(cases.count == 15)
            try check(cases) { Self.fixtures.appendingPathComponent("spectra/\($0).emd").path }
        }

        /// RosettaSciIO's public Velox files with spectra (and the ones without), as its own reader returns them.
        @Test func testPublicFilesEqualRosettaSciIO() throws {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("spectra-pins.json"))
            let pins = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let all = try #require(pins["public"] as? [String: [String: Any]])
            let present = all.filter { publicPath($0.key) != nil }
            guard !present.isEmpty else { return }   // a clone without References: the planted cases above stand
            #expect(present.count == all.count, "every public file is unzipped or none")
            try check(present) { publicPath($0)! }
        }

        private func check(_ cases: [String: [String: Any]], path pathOf: (String) -> String) throws {
            for (name, record) in cases.sorted(by: { $0.key < $1.key }) {
                let zones = try #require(record["zones"] as? [String: Any])
                for (zone, value) in zones.sorted(by: { $0.key < $1.key }) {
                    let label = "\(name) @ \(zone)"
                    if let raised = value as? [String: Any] {
                        #expect(throws: (any Error).self, "\(label): RosettaSciIO raises \(raised["raises"] ?? "")") { _ = try read(path: pathOf(name), zone: zone) }
                        continue
                    }
                    let expected = try #require(value as? [[String: Any]], Comment(rawValue: label))
                    // HyperSpy's mapping raising inside a function is the load raising.
                    let mappedRaises = expected.contains { ($0["mapped"] as? [String: Any])?.values.contains { ($0 as? [String: Any])?["raises"] != nil } ?? false }
                    if mappedRaises {
                        #expect(throws: FormatoReadError.self, "\(label): the mapping raises") { _ = try read(path: pathOf(name), zone: zone) }
                        continue
                    }
                    let got = try read(path: pathOf(name), zone: zone)
                    try #require(got.count == expected.count, Comment(rawValue: label))
                    for (signal, want) in zip(got, expected) {
                        #expect(signal.data.dataType.rawValue == want["dtype"] as? String, Comment(rawValue: label))
                        #expect(signal.data.shape == want["shape"] as? [Int], Comment(rawValue: label))
                        #expect(sha(signal.data) == want["data_sha256"] as? String, Comment(rawValue: label))
                        #expect(signal.signalType == (want["signal"] as? [String: Any])?["signal_type"] as? String)
                        let axes = try #require(want["axes"] as? [[String: Any]])
                        try #require(signal.axes.count == axes.count, Comment(rawValue: label))
                        for (axis, expectedAxis) in zip(signal.axes, axes) {
                            #expect(axis.name == expectedAxis["name"] as? String, Comment(rawValue: label))
                            #expect(axis.size == expectedAxis["size"] as? Int)
                            #expect(axis.scale.bitPattern == (expectedAxis["scale"] as? Double ?? Double(expectedAxis["scale"] as? Int ?? 0)).bitPattern, "\(label) scale")
                            #expect(axis.offset.bitPattern == (expectedAxis["offset"] as? Double ?? Double(expectedAxis["offset"] as? Int ?? 0)).bitPattern, "\(label) offset")
                            #expect(axis.units == (expectedAxis["units"] as? String ?? ""), Comment(rawValue: label))
                            #expect(axis.navigate == (expectedAxis["navigate"] as? Bool))
                        }
                        // General (date and time; the zone's name only where the test process runs in it), then the mapping.
                        let general = try #require(want["general"] as? [String: Any])
                        let mapped = try #require(want["mapped"] as? [String: Any])
                        var wantedKeys = Set<String>()
                        for key in ["original_filename", "date", "time", "title"] {
                            guard let v = general[key] as? String else { continue }
                            let finalValue = key == "title" ? ((mapped["General.title"] as? String) ?? v) : v
                            wantedKeys.insert("General." + key)
                            #expect(signal.metadata["General." + key]?.value.text == finalValue, "\(label) General.\(key)")
                        }
                        if general["time_zone"] != nil {
                            wantedKeys.insert("General.time_zone")
                            let zoneName = signal.metadata["General.time_zone"]?.value.text
                            #expect(zoneName != nil, Comment(rawValue: label))
                            // In the process's own zone (zone nil) the name is the tz database's, as `tzlocal().tzname()` gives.
                            if TimeZone.current.identifier == zone {
                                let own = try read(path: pathOf(name), zone: nil)
                                #expect(own.first?.metadata["General.time_zone"]?.value.text == general["time_zone"] as? String, Comment(rawValue: label))
                                #expect(own.first?.metadata["General.time"]?.value.text == general["time"] as? String, Comment(rawValue: label))
                            }
                        }
                        for (key, v) in mapped where key != "General.title" {
                            wantedKeys.insert(key)
                            if key == "General.time_zone" { continue }   // the name: checked above, in the process's own zone only
                            let entry = try #require(signal.metadata[key], Comment(rawValue: "\(label) \(key)"))
                            switch v {
                            case let s as String: #expect(entry.value.text == s, "\(label) \(key)")
                            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): #expect(entry.value == .flag(n.boolValue), "\(label) \(key)")
                            case let n as NSNumber: #expect(entry.value.number?.bitPattern == n.doubleValue.bitPattern, "\(label) \(key)")
                            default: Issue.record("unexpected pin value for \(key)")
                            }
                        }
                        #expect(Set(signal.metadata.keys) == wantedKeys, "\(label): the metadata keys")
                    }
                }
            }
        }

        /// Planted literals, typed from the generator's definitions and not from the pins.
        @Test func testPlantedLiterals() throws {
            let single = try read("sp-single", zone: "UTC")
            #expect(single.count == 1 && single[0].title == "EDS" && single[0].signalType == "EDS_TEM")
            #expect(single[0].data.dataType == .uint32 && single[0].data.shape == [12])
            #expect(single[0].data.doubles() == (0..<12).map { (i: Int) -> Double in Double(i * 7 + 1) })
            #expect(single[0].axes == [FormatoAxis(name: "Energy", size: 12, scale: 0.005, offset: -0.48, units: "keV", navigate: false)])
            // 1490107072.25 s = 2017-03-21 14:37:52.25 UTC.
            #expect(single[0].metadata["General.date"]?.value.text == "2017-03-21")
            #expect(single[0].metadata["General.time"]?.value.text == "14:37:52.250000")
            #expect(single[0].metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number == 200)
            #expect(single[0].metadata["Acquisition_instrument.TEM.camera_length"]?.value.number == 98)
            #expect(single[0].metadata["Acquisition_instrument.TEM.Stage.tilt_beta"]?.value.number == -11.459)
            // New York is behind UTC: Python's isoformat().split("+")[0] keeps the offset on the time.
            #expect(try read("sp-single", zone: "America/New_York")[0].metadata["General.time"]?.value.text == "10:37:52.250000-04:00")
            // The stack is transposed: stored (bins 6, stack 3) value 3*(3b+s) becomes row s, column b.
            let stack = try read("sp-stack")[0]
            #expect(stack.data.shape == [3, 6] && stack.axes.map(\.name) == ["Stack", "Energy"] && stack.axes[0].navigate)
            #expect(stack.data.doubles()[1 * 6 + 2] == 3 * (3 * 2 + 1))
            // Names sort: "aa" (int16) before "zz" (float32, 0.01 keV per channel from SuperXG12).
            let two = try read("sp-two")
            #expect(two.map(\.data.dataType) == [.int16, .float32])
            #expect(two[1].axes[0].scale == 0.01 && two[1].axes[0].offset == -0.0965)
            // No detector name: scale 1, offset 0, and the axis still says keV (RosettaSciIO hard-codes it).
            let bare = try read("sp-nodetector")[0]
            #expect(bare.axes[0].scale == 1 && bare.axes[0].offset == 0 && bare.axes[0].units == "keV")
            // The spectra of a file with images but no spectrum image are not read; nor those of a file with none.
            #expect(try read("sp-images-only").isEmpty && read("sp-none").isEmpty)
            #expect(try read("sp-stream").count == 1)
        }

        @Test func testRefusalsNameTheRule() throws {
            for name in ["sp-no-acquisition", "sp-no-detector0", "sp-bad-dispersion", "sp-bad-voltage", "sp-notvelox"] {
                #expect(throws: (any Error).self, Comment(rawValue: name)) { _ = try read(name) }
            }
        }
    }
}

/// A small SHA-256 over `CryptoKit`-free code is not worth writing: the pins carry the digest of the bytes, so the test hashes with CommonCrypto.
import CommonCrypto

struct SHA256Hex {
    mutating func hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
