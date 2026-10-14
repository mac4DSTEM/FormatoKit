//
//  PinsTests.swift
//  Gates P1 and L1 of docs/registration-step-1.md: every DM and Velox signal RosettaSciIO 049e7d70 returns from its public
//  test files (Fixtures/step-1-pins.json, tools/step-1/pins.py) against FormatoDM's and FormatoEMD's adapters: shape, the
//  data's sha256 (DM: the stored bytes; Velox: Float32, amendment step 1), every axis field bit for bit, the signal type,
//  the title (DM) and the mapped metadata with its source; a type RosettaSciIO reads and FormatoKit does not is refused by
//  name (A1.1). And L1: for every signal read, seeded slabs of the lazy array equal the same slabs cut from the eager one.
//  The public files are read from the pinned clone in References/ (tools/test.sh unzips the zips after checking their
//  sha256); without References, only the committed copy of 3D/EELS_SI.dm4 runs.
//  Mutations of §7 that this catches: 1-8 (DM axes, names, navigate, signal type, dtype, beam energy), 9, 10 (Velox), 13,
//  14 (lazy), 15 (provenance).
//

import CryptoKit
import XCTest
import FormatoCore
import FormatoDM
import FormatoEMD

final class PinsTests: XCTestCase {
    private static let supported: Set<String> = Set(FormatoDataType.allCases.map(\.rawValue))

    private func locate(_ pinPath: String) -> URL? {
        let parts = pinPath.split(separator: "/").map(String.init)
        let candidates: [URL]
        if parts.count == 3, parts[0] == "emd", parts[1].hasSuffix(".zip") {
            candidates = [TestPaths.unzipped.appendingPathComponent(pinPath)]
        } else {
            candidates = [TestPaths.rsciioData.appendingPathComponent(pinPath)]
                + (pinPath == "digitalmicrograph/3D/EELS_SI.dm4"
                   ? [TestPaths.root.appendingPathComponent("Tests/FormatoDMTests/Fixtures/rsciio-EELS_SI.dm4")] : [])
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func assertAxes(_ ours: [FormatoAxis], _ pinned: [[String: Any]], _ what: String) {
        XCTAssertEqual(ours.count, pinned.count, "\(what): axis count")
        for (k, (a, p)) in zip(ours, pinned).enumerated() {
            let name = p["name"] as? String
            XCTAssertEqual(a.name, name, "\(what) axis \(k) name")
            XCTAssertEqual(a.size, p["size"] as? Int, "\(what) axis \(k) size")
            XCTAssertEqual(hex(a.scale), p["scale_bits"] as? String, "\(what) axis \(k) scale \(a.scale) vs \(p["scale"]!)")
            XCTAssertEqual(hex(a.offset), p["offset_bits"] as? String, "\(what) axis \(k) offset \(a.offset) vs \(p["offset"]!)")
            XCTAssertEqual(a.units, p["units"] as? String, "\(what) axis \(k) units")
            XCTAssertEqual(a.navigate, p["navigate"] as? Bool, "\(what) axis \(k) navigate")
        }
    }

    private func assertMetadata(_ ours: FormatoMetadata, _ pinned: [[String: Any]], _ what: String, skip: Set<String> = []) {
        let pinnedKeys = Set(pinned.compactMap { $0["key"] as? String }).subtracting(skip)
        XCTAssertEqual(Set(ours.keys).subtracting(skip), pinnedKeys, "\(what): metadata keys")
        for p in pinned {
            guard let key = p["key"] as? String, !skip.contains(key), let e = ours[key] else { continue }
            if p["kind"] as? String == "number" {
                XCTAssertEqual(e.value.number.map(hex), p["value_bits"] as? String, "\(what): \(key)")
            } else {
                XCTAssertEqual(e.value.text, p["value"] as? String, "\(what): \(key)")
            }
            if let source = p["source"] as? String {
                // A1.5: compared by the tail from the first named group on ("Microscope Info.Voltage", "Optics...").
                let tail = source.range(of: "Microscope Info.").map { String(source[$0.lowerBound...]) } ?? source
                XCTAssertTrue(e.provenance.source.hasSuffix(tail), "\(what): \(key) source \(e.provenance.source) vs \(source)")
            }
            XCTAssertFalse(e.provenance.rule.isEmpty, "\(what): \(key) has no rule")
        }
    }

    /// L1 on one signal: the lazy array's whole read and seeded slabs equal the eager array's.
    private func assertLazyEqualsEager(_ lazy: FormatoLazySignal, _ eager: FormatoSignal, _ what: String) throws {
        let shape = eager.data.shape
        var seed = UInt64(truncatingIfNeeded: what.hashValue) | 1
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % max(n, 1) }
        for _ in 0..<6 {
            let start = shape.map { next($0 + 1) }
            let count = zip(start, shape).map { s, n in next(n - s + 1) }
            XCTAssertEqual(try lazy.array.read(start: start, count: count), try eager.data.slab(start: start, count: count),
                           "\(what): slab \(start) \(count)")
        }
    }

    func testEveryPinnedSignalAgreesWithRosettaSciIO() throws {
        let files = try XCTUnwrap(try loadJSON("step-1-pins.json")["files"] as? [[String: Any]])
        let referencesPresent = FileManager.default.fileExists(atPath: TestPaths.rsciioData.path)
        let (read, signals, refused) = try compare(files, locate: locate, mustFind: referencesPresent)
        if referencesPresent {
            XCTAssertEqual(read, files.count, "every pinned file read")
            XCTAssertEqual(signals + refused, 153, "111 DM + 42 Velox signals")
        } else if read == 0 {
            throw XCTSkip("References/rosettasciio-049e7d70 is absent and no committed public file is pinned")
        }
    }

    /// The owner's files (registration §2): run by tools/step-1/owner-check.sh, which writes RosettaSciIO's reading of them
    /// with `pins.py --owner` and passes FORMATO_OWNER_PINS (that JSON) and FORMATO_OWNER_FILES (their absolute paths, one
    /// per line). Never part of the gate: skipped without the variables.
    func testOwnerFilesAgreeWithRosettaSciIO() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pins = env["FORMATO_OWNER_PINS"], let list = env["FORMATO_OWNER_FILES"] else {
            throw XCTSkip("the owner's files are checked by tools/step-1/owner-check.sh only")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: pins))) as! [String: Any]
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
        let byName = Dictionary(paths.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName.count, paths.count, "the owner's file names are unique")
        let (read, signals, refused) = try compare(files, locate: { byName[$0].map(URL.init(fileURLWithPath:)) }, mustFind: true)
        XCTAssertEqual(read, files.count)
        print("OwnerPins: \(read) files, \(signals) signals equal, \(refused) refused by name")
    }

    private func compare(_ files: [[String: Any]], locate: (String) -> URL?, mustFind: Bool) throws -> (Int, Int, Int) {
        var read = 0, signals = 0, refused = 0, titleDifferences: [String] = []
        for f in files {
            let path = f["path"] as! String
            guard let url = locate(path) else {
                if mustFind { XCTFail("\(path): not found (tools/test.sh unzips the public zips)") }
                continue
            }
            XCTAssertEqual(sha(try Data(contentsOf: url)), f["sha256"] as? String, "\(path): not the pinned file")
            XCTAssertNil(f["raises"] as? [String: Any], "\(path): RosettaSciIO raised; no such file is pinned at step 1")
            let pinned = f["signals"] as! [[String: Any]]
            read += 1
            if f["format"] as? String == "dm" {
                let dm = try DMFile(path: url.path)
                XCTAssertEqual(Set(dm.objects.map(\.index)), Set(pinned.map { $0["dm_index"] as! Int }), "\(path): object set")
                for p in pinned {
                    let index = p["dm_index"] as! Int, what = "\(path)#\(index)"
                    let object = try XCTUnwrap(dm.objects.first { $0.index == index })
                    if p["axes_sizes_match_shape"] as? Bool != false {
                        assertAxes(DMFile.axes(of: object), p["axes"] as! [[String: Any]], what)
                    }
                    XCTAssertEqual(DMFile.signalType(of: object), p["signal_type"] as? String, "\(what): signal type")
                    guard Self.supported.contains(p["dtype"] as! String) else {
                        XCTAssertThrowsError(try dm.signal(index: index), "\(what): \(p["dtype"]!) must be refused") {
                            guard case .unsupportedDataType = $0 as? FormatoReadError else { return XCTFail("\(what): \($0)") }
                        }
                        refused += 1; continue
                    }
                    let lazy = try dm.signal(index: index), eager = try lazy.load()
                    XCTAssertEqual(eager.data.dataType.rawValue, p["dtype"] as? String, "\(what): dtype")
                    XCTAssertEqual(eager.data.shape, p["shape"] as? [Int], "\(what): shape")
                    XCTAssertEqual(sha(eager.data.bytes), p["data_sha256"] as? String, "\(what): data")
                    XCTAssertEqual(eager.title, p["title"] as? String, "\(what): title")
                    assertMetadata(eager.metadata, p["metadata"] as! [[String: Any]], what)
                    try assertLazyEqualsEager(lazy, eager, what)
                    signals += 1
                }
            } else {
                let velox = try VeloxImageSignals(path: url.path)
                XCTAssertEqual(velox.images.map(\.id), pinned.map { $0["velox_image_id"] as! String }, "\(path): image list")
                for p in pinned {
                    let id = p["velox_image_id"] as! String, what = "\(path)#\(id.prefix(6))"
                    let image = try XCTUnwrap(velox.images.first { $0.id == id })
                    guard Self.supported.contains(p["dtype"] as! String) else {
                        XCTAssertThrowsError(try velox.signal(image), "\(what): \(p["dtype"]!) must be refused")
                        refused += 1; continue
                    }
                    let lazy = try velox.signal(image), eager = try lazy.load()
                    assertAxes(eager.axes, p["axes"] as! [[String: Any]], what)
                    XCTAssertEqual(eager.data.shape, p["shape"] as? [Int], "\(what): shape")
                    XCTAssertEqual(p["float32_exact"] as? Bool, true, "\(what): a stored type Float32 does not hold (A4)")
                    XCTAssertEqual(sha(eager.data.bytes), p["data_f32_sha256"] as? String, "\(what): data as Float32")
                    XCTAssertEqual(eager.signalType, "", "\(what): Velox images carry no signal type")
                    if eager.title != p["title"] as? String { titleDifferences.append("\(what): \(eager.title) vs \(p["title"]!)") }
                    assertMetadata(eager.metadata, p["metadata"] as! [[String: Any]], what, skip: ["General.title"])
                    try assertLazyEqualsEager(lazy, eager, what)
                    signals += 1
                }
            }
        }
        print("PinsTests: \(read) files, \(signals) signals equal, \(refused) refused by name; Velox titles differing from RosettaSciIO's (A4): \(titleDifferences.count)")
        for t in titleDifferences { print("  title  \(t)") }
        return (read, signals, refused)
    }
}
