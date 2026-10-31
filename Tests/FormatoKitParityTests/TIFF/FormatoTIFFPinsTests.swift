//
//  FormatoTIFFPinsTests.swift
//  Every TIFF of RosettaSciIO 049e7d70's public test data, the planted
//  files and (owner-check.sh only) the owner's Ceta TIFFs against Fixtures/tiff-pins.json (tools/tiff-pins/pins.py,
//  RosettaSciIO's file_reader over tifffile 2026.9.20): page 0's tags as tifffile decodes them (code, type, count, the raw
//  bytes' sha256, the decoded value), and for each series in scope the data's sha256, shape, element type, every axis
//  field exactly and the metadata with its source; a file out of scope or one RosettaSciIO raises on is refused by
//  name. L2: seeded slabs of each lazy array equal the eager one.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoKitTestSupport
@testable import FormatoTIFF

@Suite(.serialized) struct FormatoTIFFPinsTests {
    static let fixtures = FixtureDirs.fixtures(of: "FormatoTIFFTests")
    static let root = FixtureDirs.repository
    static let rsciioData = root.appendingPathComponent("References/rosettasciio-049e7d70/rsciio/tests/data")
    static let unpacked = FixtureDirs.unpackedTIFF

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private func hex(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) }

    /// The numpy dtype name RosettaSciIO reports for a FormatoKit element type (structured RGB by its fields).
    static func numpyName(_ t: FormatoDataType) -> [String] {
        switch t {
        case .rgb8: return ["[('R', 'u1'), ('G', 'u1'), ('B', 'u1')]"]
        case .rgba8: return ["[('R', 'u1'), ('G', 'u1'), ('B', 'u1'), ('A', 'u1')]"]
        case .rgb16: return ["[('R', '<u2'), ('G', '<u2'), ('B', '<u2')]", "[('R', '>u2'), ('G', '>u2'), ('B', '>u2')]"]
        case .rgba16: return ["[('R', '<u2'), ('G', '<u2'), ('B', '<u2'), ('A', '<u2')]", "[('R', '>u2'), ('G', '>u2'), ('B', '>u2'), ('A', '>u2')]"]
        default: return [t.rawValue]
        }
    }

    private func locate(_ path: String) -> URL? {
        let candidates = [Self.unpacked.appendingPathComponent(path), Self.rsciioData.appendingPathComponent(path),
                          Self.fixtures.appendingPathComponent(path), Self.fixtures.appendingPathComponent("planted/" + path)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func refuses(_ url: URL) -> Bool {
        guard let t = try? TIFFSignals(path: url.path) else { return true }
        return t.series.indices.contains { (try? t.signal(series: $0)) == nil }
    }

    private func assertTags(_ dir: TIFFDirectory, _ pinned: [[String: Any]], _ what: String) {
        // tifffile drops a tag of a type it does not know; the walker keeps it: compared without those.
        let known: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16, 17, 18]
        let gotCodes: [Int] = dir.tags.filter { known.contains($0.type) }.map(\.code)
        let wantCodes: [Int] = pinned.map { (p: [String: Any]) -> Int in p["code"] as! Int }
        #expect(gotCodes == wantCodes, "\(what): tag codes")
        for p in pinned {
            guard let tag = dir[p["code"] as! Int] else { continue }
            let w = "\(what) tag \(tag.code)"
            #expect(tag.type == p["type"] as? Int, "\(w): type")
            #expect(tag.count == p["count"] as? Int, "\(w): count")
            // A pointer tag (EXIF 34665, GPS 34853, Interoperability 40965, TVIPS 37706 as tifffile reads it): tifffile's
            // `valueoffset` is where it reads the structure, so its "raw" bytes are not the stored field; the walker keeps
            // the stored field.
            if ![34665, 34853, 40965, 37706].contains(tag.code) { #expect(sha(tag.raw) == p["raw_sha256"] as? String, "\(w): raw bytes") }
            // The decoded value, item by item: a float by its bits, an integer by its value, a string as decoded.
            if let s = p["value"] as? String { #expect(tag.text == s, "\(w): text"); continue }
            let values: [Any] = (p["value"] as? [Any]) ?? (p["value"].map { [$0] } ?? [])
            let bits: [Any] = (p["value_bits"] as? [Any]) ?? (p["value_bits"].map { [$0] } ?? [])
            guard !values.isEmpty, !(values.first is NSNull) else { continue }
            let ours = tagNumbers(tag)
            #expect(ours.count == values.count, "\(w): \(values.count) values, ours \(ours.count)")
            for (i, v) in values.enumerated() where i < ours.count {
                if i < bits.count, let b = bits[i] as? String { #expect(hex(ours[i]) == b, "\(w)[\(i)]: bits") }
                else if let n = v as? NSNumber { #expect(ours[i] == n.doubleValue, "\(w)[\(i)]: \(n) vs \(ours[i])") }
            }
        }
    }

    /// A tag's numbers as tifffile flattens them (rationals as numerator, denominator).
    private func tagNumbers(_ tag: TIFFTag) -> [Double] {
        switch tag.value {
        case .integers(let v): return v.map(Double.init)
        case .reals(let v): return v
        case .rationals(let v): return v.flatMap { [Double($0.numerator), Double($0.denominator)] }
        default: return []
        }
    }

    private func compare(_ files: [[String: Any]], locate: (String) -> URL?, mustFind: Bool, refusedOnPurpose: Set<String> = [],
                         metadataDeviations: Set<String> = [], readNow: Set<String> = [], ignoreScope: Bool = false) throws -> (files: Int, signals: Int, refused: Int) {
        var read = 0, signals = 0, refused = 0
        for f in files {
            let path = f["path"] as! String
            guard let url = locate(path) else {
                if mustFind { Issue.record("\(path): not found") }
                continue
            }
            #expect(sha(try Data(contentsOf: url)) == f["sha256"] as? String, "\(path): not the pinned file")
            read += 1
            if let tags = f["tags"] as? [[String: Any]], let file = try? TIFFFile(path: url.path), let first = file.directories.first {
                assertTags(first, tags, path)
                #expect(file.directories.count == f["pages"] as? Int, "\(path): pages")
            }
            if (f["in_scope"] as? Bool != true && !ignoreScope && !readNow.contains(path)) || f["raises"] as? [String: Any] != nil || refusedOnPurpose.contains(path) {
                #expect(refuses(url), "\(path): out of scope (\(f["out_of_scope"] ?? f["raises"] ?? "?")) but read")
                refused += 1; continue
            }
            let tiff = try TIFFSignals(path: url.path)
            let pinned = f["series"] as! [[String: Any]]
            #expect(tiff.series.count == pinned.count, "\(path): series count")
            for (i, p) in pinned.enumerated() where i < tiff.series.count {
                let what = "\(path)#\(i)"
                #expect(tiff.series[i].axes == p["tifffile_axes"] as? String, "\(what): tifffile axes")
                let lazy = try tiff.signal(series: i), eager = try lazy.load()
                #expect(Self.numpyName(eager.data.dataType).contains(p["dtype"] as! String), "\(what): dtype \(eager.data.dataType) vs \(p["dtype"]!)")
                #expect(eager.data.shape == p["shape"] as? [Int], "\(what): shape")
                #expect(sha(eager.data.bytes) == p["data_sha256"] as? String, "\(what): data")
                let axes = p["axes"] as! [[String: Any]]
                #expect(eager.axes.count == axes.count, "\(what): axis count")
                for (k, (a, q)) in zip(eager.axes, axes).enumerated() {
                    #expect(a.name == q["name"] as? String, "\(what) axis \(k) name")
                    #expect(a.size == q["size"] as? Int, "\(what) axis \(k) size")
                    #expect(hex(a.scale) == q["scale_bits"] as? String, "\(what) axis \(k) scale \(a.scale) vs \(q["scale"]!)")
                    #expect(hex(a.offset) == q["offset_bits"] as? String, "\(what) axis \(k) offset \(a.offset) vs \(q["offset"]!)")
                    #expect(a.units == ((q["units"] as? String) ?? ""), "\(what) axis \(k) units '\(a.units)' vs \(q["units"] ?? "None")")
                    #expect(a.navigate == q["navigate"] as? Bool, "\(what) axis \(k) navigate")
                }
                let md = metadataDeviations.contains(path) ? [] : p["metadata"] as! [[String: Any]]
                if !metadataDeviations.contains(path) {
                    #expect(Set(eager.metadata.keys) == Set(md.map { $0["key"] as! String }), "\(what): metadata keys")
                }
                for e in md {
                    let key = e["key"] as! String
                    guard let ours = eager.metadata[key] else { continue }
                    if let bits = e["value_bits"] as? String { #expect(ours.value.number.map(hex) == bits, "\(what): \(key)") }
                    else if let s = e["value"] as? String { #expect(ours.value.text == s, "\(what): \(key)") }
                    if let source = e["source"] as? String { #expect(ours.provenance.source.hasSuffix(source.replacingOccurrences(of: "fei_metadata.", with: "")) || ours.provenance.source == source, "\(what): \(key) source \(ours.provenance.source) vs \(source)") }
                }
                // L2: seeded slabs.
                var seed = UInt64(truncatingIfNeeded: what.hashValue) | 1
                func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % max(n, 1) }
                for _ in 0..<6 {
                    let start = eager.data.shape.map { next($0 + 1) }
                    let count = zip(start, eager.data.shape).map { s, n in next(n - s + 1) }
                    #expect(try lazy.array.read(start: start, count: count) == eager.data.slab(start: start, count: count), "\(what): slab \(start) \(count)")
                }
                signals += 1
            }
        }
        return (read, signals, refused)
    }

    @Test func testEveryPinnedTIFFAgreesWithRosettaSciIO() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("tiff-pins.json"))) as! [String: Any]
        let files = object["files"] as! [[String: Any]]
        let referencesPresent = FileManager.default.fileExists(atPath: Self.rsciioData.path)
        let r = try compare(files, locate: locate, mustFind: referencesPresent)
        print("FormatoTIFFPins: \(r.files) files, \(r.signals) signals equal, \(r.refused) refused by name")
        if referencesPresent { #expect(r.files == files.count) }
    }

    /// The review files (Fixtures/refuter, pinned by `pins.py --owner` into refuter-pins.json): where RosettaSciIO raises,
    /// FormatoKit refuses; where it reads, the signals are equal, except the files FormatoKit refuses on purpose
    /// (tifffile's shaped, OME, several-series, pyramid, FillOrder, strip-offset-0 rules are not
    /// ported) and one deliberate metadata deviation (a DateTime in non-ASCII digits, which Python's strptime reads).
    @Test func testRefuterFilesAgreeOrAreRefused() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("refuter-pins.json"))) as! [String: Any]
        let files = object["files"] as! [[String: Any]]
        let dir = Self.fixtures.appendingPathComponent("refuter")
        let onPurpose: Set<String> = ["m_photo_diff.tif", "m_rps_diff.tif", "pyr_half.tif", "dm_stack_mix_series.tif",
                                      "ij_desc_07.tif", "ij_pages2_images4.tif", "ij_ovf_fs_1p.tif", "f_257_val_1.tif",
                                      "o_fill2_u8.tif", "h_off0.tif"]
        let r = try compare(files, locate: { name in
            let u = dir.appendingPathComponent(name); return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }, mustFind: true, refusedOnPurpose: onPurpose, metadataDeviations: ["dt_15.tif"], readNow: ["tf_stack2.tif"])
        print("TIFFRefuter: \(r.files) files, \(r.signals) equal, \(r.refused) refused")
        #expect(r.files == 26)
    }

    /// Files tifffile writes with its default (shaped) description, `tools/shaped-tiff/pins.py` into shaped-pins.json: the
    /// shaped series rule gives RosettaSciIO's shapes, axes, bytes and metadata exactly; where RosettaSciIO raises, FormatoKit
    /// refuses; where tifffile gives up on the description and uses the generic rule, so does FormatoKit.
    @Test func testShapedSeriesFilesAgreeWithRosettaSciIO() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("shaped-pins.json"))) as! [String: Any]
        let files = object["files"] as! [[String: Any]]
        let r = try compare(files, locate: { name in
            let u = Self.fixtures.appendingPathComponent(name); return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }, mustFind: true, ignoreScope: true)
        print("ShapedTIFF: \(r.files) files, \(r.signals) signals equal, \(r.refused) refused")
        #expect(r.files == files.count)
        #expect(r.signals >= 50)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORMATO_OWNER_TIFF_PINS"] != nil, "owner files: tools/tiff-pins/owner-check.sh"))
    func testOwnerTIFFsAgreeWithRosettaSciIO() throws {
        let env = ProcessInfo.processInfo.environment
        let pins = try #require(env["FORMATO_OWNER_TIFF_PINS"]), list = try #require(env["FORMATO_OWNER_TIFF_FILES"])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: pins))) as! [String: Any]
        let files = object["files"] as! [[String: Any]]
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
        let byName = Dictionary(paths.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let r = try compare(files, locate: { byName[$0].map(URL.init(fileURLWithPath:)) }, mustFind: true)
        print("OwnerTIFFPins: \(r.files) files, \(r.signals) signals equal, \(r.refused) refused by name")
        #expect(r.files == files.count)
    }
}
