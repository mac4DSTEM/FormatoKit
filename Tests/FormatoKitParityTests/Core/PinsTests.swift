//
//  PinsTests.swift
//  Every DM and Velox signal RosettaSciIO 049e7d70 returns from its public
//  test files (Fixtures/dm-velox-pins.json, tools/dm-velox-pins/pins.py) against FormatoDM's and FormatoEMD's adapters: shape, the
//  data's sha256 over the stored bytes (Velox in its stored type since step 3; Float32 before), every axis field bit for
//  bit, the signal type, the title (DM; Velox since step 3) and the mapped metadata with its source; a type RosettaSciIO reads and FormatoKit does not is refused by
//  name (A1.1). And L1: for every signal read, seeded slabs of the lazy array equal the same slabs cut from the eager one.
//  The public files are read from the pinned clone in References/ (tools/test.sh unzips the zips after checking their
//  sha256); without References, only the committed copy of 3D/EELS_SI.dm4 runs.
//  Mutations of §7 that this catches: 1-8 (DM axes, names, navigate, signal type, dtype, beam energy), 9, 10 (Velox), 13,
//  14 (lazy), 15 (provenance).
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoDM
import FormatoEMD

@Suite(.serialized) struct PinsTests {
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
        #expect(ours.count == pinned.count, "\(what): axis count")
        for (k, (a, p)) in zip(ours, pinned).enumerated() {
            let name = p["name"] as? String
            #expect(a.name == name, "\(what) axis \(k) name")
            #expect(a.size == p["size"] as? Int, "\(what) axis \(k) size")
            #expect(hex(a.scale) == p["scale_bits"] as? String, "\(what) axis \(k) scale \(a.scale) vs \(p["scale"]!)")
            #expect(hex(a.offset) == p["offset_bits"] as? String, "\(what) axis \(k) offset \(a.offset) vs \(p["offset"]!)")
            #expect(a.units == p["units"] as? String, "\(what) axis \(k) units")
            #expect(a.navigate == p["navigate"] as? Bool, "\(what) axis \(k) navigate")
        }
    }

    private func assertMetadata(_ ours: FormatoMetadata, _ pinned: [[String: Any]], _ what: String, skip: Set<String> = [],
                                producedName: (pinned: String, opened: String)? = nil) {
        let pinnedKeys = Set(pinned.compactMap { $0["key"] as? String }).subtracting(skip)
        #expect(Set(ours.keys).subtracting(skip) == pinnedKeys, "\(what): metadata keys")
        for p in pinned {
            guard let key = p["key"] as? String, !skip.contains(key), let e = ours[key] else { continue }
            if p["kind"] as? String == "number" {
                #expect(e.value.number.map(hex) == p["value_bits"] as? String, "\(what): \(key)")
            } else {
                // A DM file's name is in its metadata and title: the committed copy of EELS_SI.dm4 is stored as
                // rsciio-EELS_SI.dm4, so a pinned value equal to the pinned file's name is compared with the opened file's.
                var expected = p["value"] as? String
                if let n = producedName, expected == n.pinned { expected = n.opened }
                #expect(e.value.text == expected, "\(what): \(key)")
            }
            if let source = p["source"] as? String {
                // A1.5: compared by the tail from the first named group on ("Microscope Info.Voltage", "Optics...").
                let tail = source.range(of: "Microscope Info.").map { String(source[$0.lowerBound...]) } ?? source
                #expect(e.provenance.source.hasSuffix(tail), "\(what): \(key) source \(e.provenance.source) vs \(source)")
            }
            #expect(!(e.provenance.rule.isEmpty), "\(what): \(key) has no rule")
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
            #expect(try lazy.array.read(start: start, count: count) == eager.data.slab(start: start, count: count), "\(what): slab \(start) \(count)")
        }
    }

    @Test func testEveryPinnedSignalAgreesWithRosettaSciIO() throws {
        let files = try #require(try loadJSON("dm-velox-pins.json")["files"] as? [[String: Any]])
        let referencesPresent = FileManager.default.fileExists(atPath: TestPaths.rsciioData.path)
        let (read, signals, refused) = try compare(files, locate: locate, mustFind: referencesPresent)
        if referencesPresent {
            #expect(read == files.count, "every pinned file read")
            #expect(signals + refused == 153, "111 DM + 42 Velox signals")
        } else if read == 0 {
            // Nothing to compare: References/rosettasciio-049e7d70 is absent and no committed public file is pinned.
            // An early return, not Test.cancel (newer than the Swift Testing in Xcode 26.0, which CI pins).
            return
        }
    }

    /// The owner's files: run by tools/dm-velox-pins/owner-check.sh, which writes RosettaSciIO's reading of them
    /// with `pins.py --owner` and passes FORMATO_OWNER_PINS (that JSON) and FORMATO_OWNER_FILES (their absolute paths, one
    /// per line). Never part of the gate: skipped without the variables.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FORMATO_OWNER_PINS"] != nil,
                   "the owner's files are checked by tools/dm-velox-pins/owner-check.sh only"))
    func testOwnerFilesAgreeWithRosettaSciIO() throws {
        let env = ProcessInfo.processInfo.environment
        let pins = try #require(env["FORMATO_OWNER_PINS"]), list = try #require(env["FORMATO_OWNER_FILES"])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: pins))) as! [String: Any]
        let files = try #require(object["files"] as? [[String: Any]])
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
        let byName = Dictionary(paths.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName.count == paths.count, "the owner's file names are unique")
        let (read, signals, refused) = try compare(files, locate: { byName[$0].map(URL.init(fileURLWithPath:)) }, mustFind: true)
        #expect(read == files.count)
        print("OwnerPins: \(read) files, \(signals) signals equal, \(refused) refused by name")
    }

    /// Whether FormatoKit refuses the file: listing it throws, or building one of its signals does.
    private func refuses(_ url: URL, format: String) -> Bool {
        if format == "dm" {
            guard let dm = try? DMFile(path: url.path) else { return true }
            return dm.objects.contains { (try? dm.signal(index: $0.index)) == nil }
        }
        guard let velox = try? VeloxImageSignals(path: url.path) else { return true }
        return velox.images.contains { (try? velox.signal($0)) == nil }
    }

    /// Step 3's planted Velox files (Tests/FormatoEMDTests/Fixtures/velox-titles-*.emd, pinned by
    /// tools/velox-titles/pins.py): every Operations kind and branch, DetectorInformation and the carried name, both label maps, the
    /// ten stored types. Compared as the public files are.
    @Test func testStep3PlantedVeloxFilesAgree() throws {
        let files = try #require(try loadJSON("velox-titles-pins.json")["files"] as? [[String: Any]])
        let dir = TestPaths.root.appendingPathComponent("Tests/FormatoEMDTests/Fixtures")
        let (read, signals, refused) = try compare(files, locate: { name in
            let u = dir.appendingPathComponent(name); return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }, mustFind: true)
        #expect(read == 4)
        #expect(signals == 22)
        #expect(refused == 0)
    }

    /// Step 3's review files (Tests/FormatoEMDTests/Fixtures/velox-titles-refuter, tools/velox-titles/refuter_pins.py): 11 RosettaSciIO raises on (the detector-metadata lookup, root datasets, Acquisition, Version), refused here too;
    /// 2 it reads, read equal.
    @Test func testStep3RefuterFilesAgreeOrAreRefused() throws {
        let files = try #require(try loadJSON("step-3-refuter-pins.json")["files"] as? [[String: Any]])
        let dir = TestPaths.root.appendingPathComponent("Tests/FormatoEMDTests/Fixtures/velox-titles-refuter")
        let (read, signals, refused) = try compare(files, locate: { name in
            let u = dir.appendingPathComponent(name); return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }, mustFind: true)
        #expect(read == 13)
        #expect(refused == 11)
        #expect(signals == 2)
    }

    /// The review files (Fixtures/refuter, tools/dm-velox-pins/pins.py --set refuter): built by the refuter from RosettaSciIO's public
    /// fei_example_tem_stack.emd with one metadata value changed each. Where RosettaSciIO raises, FormatoKit must refuse
    /// (F1-F3); where it reads, the signals must be equal; `u_stack_unit_px.emd` (Pint's "px") is refused on purpose
    /// (units outside FormatoUnits are refused, not guessed).
    @Test func testRefuterFilesAgreeOrAreRefused() throws {
        let files = try #require(try loadJSON("refuter-pins.json")["files"] as? [[String: Any]])
        let dir = TestPaths.fixtures.appendingPathComponent("refuter")
        let (read, signals, refused) = try compare(files, locate: { name in
            let u = dir.appendingPathComponent(name); return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }, mustFind: true, refusedOnPurpose: ["u_stack_unit_px.emd"])
        #expect(read == 11)
        #expect(refused == 9, "8 files RosettaSciIO raises on and the px one")
        #expect(signals == 2)
    }

    private func compare(_ files: [[String: Any]], locate: (String) -> URL?, mustFind: Bool,
                         refusedOnPurpose: Set<String> = []) throws -> (Int, Int, Int) {
        var read = 0, signals = 0, refused = 0
        for f in files {
            let path = f["path"] as! String
            guard let url = locate(path) else {
                if mustFind { Issue.record("\(path): not found (tools/test.sh unzips the public zips)") }
                continue
            }
            #expect(sha(try Data(contentsOf: url)) == f["sha256"] as? String, "\(path): not the pinned file")
            read += 1
            if f["raises"] as? [String: Any] != nil || refusedOnPurpose.contains(path) {
                // P1: a file RosettaSciIO raises on is refused by FormatoKit too: the file, or at least one of its signals.
                #expect(refuses(url, format: f["format"] as! String), "\(path): RosettaSciIO raises (\(f["raises"] ?? "a registered refusal")), FormatoKit read it")
                refused += 1; continue
            }
            let pinned = f["signals"] as! [[String: Any]]
            if f["format"] as? String == "dm" {
                let dm = try DMFile(path: url.path)
                #expect(Set(dm.objects.map(\.index)) == Set(pinned.map { $0["dm_index"] as! Int }), "\(path): object set")
                for p in pinned {
                    let index = p["dm_index"] as! Int, what = "\(path)#\(index)"
                    let object = try #require(dm.objects.first { $0.index == index })
                    if p["axes_sizes_match_shape"] as? Bool != false {
                        assertAxes(DMFile.axes(of: object), p["axes"] as! [[String: Any]], what)
                    }
                    #expect(DMFile.signalType(of: object) == p["signal_type"] as? String, "\(what): signal type")
                    guard Self.supported.contains(p["dtype"] as! String) else {
                        let error = #expect(throws: FormatoReadError.self, "\(what): \(p["dtype"]!) must be refused") {
                            try dm.signal(index: index)
                        }
                        if let error, case .unsupportedDataType = error {} else { Issue.record("\(what): \(String(describing: error))") }
                        refused += 1; continue
                    }
                    let lazy = try dm.signal(index: index), eager = try lazy.load()
                    #expect(eager.data.dataType.rawValue == p["dtype"] as? String, "\(what): dtype")
                    #expect(eager.data.shape == p["shape"] as? [Int], "\(what): shape")
                    #expect(sha(eager.data.bytes) == p["data_sha256"] as? String, "\(what): data")
                    let pinnedName = (path as NSString).lastPathComponent
                    let title = (p["title"] as? String) == pinnedName ? url.lastPathComponent : p["title"] as? String
                    #expect(eager.title == title, "\(what): title")
                    assertMetadata(eager.metadata, p["metadata"] as! [[String: Any]], what,
                                   producedName: (pinnedName, url.lastPathComponent))
                    try assertLazyEqualsEager(lazy, eager, what)
                    signals += 1
                }
            } else {
                let velox = try VeloxImageSignals(path: url.path)
                #expect(velox.images.map(\.id) == pinned.map { $0["velox_image_id"] as! String }, "\(path): image list")
                for p in pinned {
                    let id = p["velox_image_id"] as! String, what = "\(path)#\(id.prefix(6))"
                    let image = try #require(velox.images.first { $0.id == id })
                    guard Self.supported.contains(p["dtype"] as! String) else {
                        #expect(throws: FormatoReadError.self, "\(what): \(p["dtype"]!) must be refused") { try velox.signal(image) }
                        refused += 1; continue
                    }
                    let lazy = try velox.signal(image), eager = try lazy.load()
                    assertAxes(eager.axes, p["axes"] as! [[String: Any]], what)
                    // Step 3: the stored type, its bytes and RosettaSciIO's title.
                    #expect(eager.data.dataType.rawValue == p["dtype"] as? String, "\(what): dtype")
                    #expect(eager.data.shape == p["shape"] as? [Int], "\(what): shape")
                    #expect(sha(eager.data.bytes) == p["data_sha256"] as? String, "\(what): data in the stored type")
                    #expect(eager.signalType == "", "\(what): Velox images carry no signal type")
                    #expect(eager.title == (p["title"] as? String ?? ""), "\(what): title")
                    #expect(velox.title(of: image) == p["title"] as? String, "\(what): title (nil when RosettaSciIO has none)")
                    assertMetadata(eager.metadata, p["metadata"] as! [[String: Any]], what)
                    try assertLazyEqualsEager(lazy, eager, what)
                    signals += 1
                }
            }
        }
        print("PinsTests: \(read) files, \(signals) signals equal, \(refused) refused by name")
        return (read, signals, refused)
    }
}
