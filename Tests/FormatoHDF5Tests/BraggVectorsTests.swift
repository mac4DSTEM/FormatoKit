//
//  BraggVectorsTests.swift
//  py4DSTEM BraggVectors in EMD 1.0: the reader against py4DSTEM-written files (bit for bit), the writer against py4DSTEM
//  and h5py (tools/bragg-writer/check.py, result pinned here with each file's SHA-256), the app's axis convention, refusals,
//  and the atomic publish. Fixtures: tools/bragg-writer/generate.py (py4DSTEM f050d207, 0.14.19).
//
//  Regenerating the swift-*.h5 fixtures: FORMATO_BRAGG_FIXTURE_DIR=<this Fixtures/bragg folder> swift test --filter
//  BraggVectorsTests, then run check.py (its docstring has the line) and commit the files with check-result.json.
//

import Foundation
import Testing
import CryptoKit
import Synchronization
import FormatoCore
import FormatoHDF5

@Suite(.serialized) struct BraggVectorsTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/bragg")
    }
    private func fixture(_ name: String) -> String { fixtures.appendingPathComponent(name).path }
    private func pins() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as! [String: Any]
    }
    private func pinnedCase(_ name: String) throws -> [String: Any] {
        try (pins()["cases"] as! [[String: Any]]).first { $0["name"] as? String == name }!
    }
    /// The py4DSTEM-written peaks, as stored: (qx, qy, intensity) float64 triples, scan row-major.
    private func pinnedPeaks(_ name: String, counts: [Int]) throws -> [[BraggPeak]] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name + ".peaks.bin"))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)).map { Double(bitPattern: UInt64(littleEndian: $0)) } }
        #expect(values.count == counts.reduce(0, +) * 3)
        var out: [[BraggPeak]] = [], offset = 0
        for n in counts {
            out.append((0..<n).map { k in
                let b = offset + k * 3
                return BraggPeak(qx: values[b], qy: values[b + 1], intensity: values[b + 2])
            })
            offset += n * 3
        }
        return out
    }
    private func sameBits(_ a: [[BraggPeak]], _ b: [[BraggPeak]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.count == y.count && zip(x, y).allSatisfy {
                $0.qx.bitPattern == $1.qx.bitPattern && $0.qy.bitPattern == $1.qy.bitPattern
                    && $0.intensity.bitPattern == $1.intensity.bitPattern
            }
        }
    }
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bragg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func listing(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    // MARK: Reading py4DSTEM's own files

    @Test func readsPy4DSTEMFilesBitForBit() throws {
        let root = try pins()
        #expect(root["py4dstem_commit"] as? String == "f050d207851f8accd3aa550365baaf1f38230428")
        #expect(root["py4dstem_version"] as? String == "0.14.19")
        for name in ["basic", "empty"] {
            let pin = try pinnedCase(name)
            let counts = pin["counts"] as! [Int]
            let v = try BraggVectorsEMD.read(path: fixture(name + ".h5"))
            #expect(v.scan == BraggGridShape(rows: (pin["scan"] as! [Int])[0], columns: (pin["scan"] as! [Int])[1]))
            #expect(v.detector == BraggGridShape(rows: (pin["detector"] as! [Int])[0], columns: (pin["detector"] as! [Int])[1]))
            #expect(v.groupPath == "/braggvectors_root/braggvectors")
            #expect(v.peaks.map(\.count) == counts)
            #expect(v.peakCount == counts.reduce(0, +))
            #expect(sameBits(v.peaks, try pinnedPeaks(name, counts: counts)))
            let cal = pin["calibration"] as! [String: Any]
            #expect(v.calibration.qPixelSize?.bitPattern == (cal["Q_pixel_size"] as! Double).bitPattern)
            #expect(v.calibration.rPixelSize?.bitPattern == (cal["R_pixel_size"] as! Double).bitPattern)
            #expect(v.calibration.qPixelUnits == cal["Q_pixel_units"] as? String)
            #expect(v.calibration.rPixelUnits == cal["R_pixel_units"] as? String)
            #expect(v.calibration.qrFlip == cal["QR_flip"] as? Bool)
            if name == "basic" {
                #expect(v.calibration.qrRotation?.bitPattern == (cal["QR_rotation"] as! Double).bitPattern)
                #expect(v.calibration.qrRotationDegrees == 15.0)
                #expect(v.calibration.qx0Mean == 7.5 && v.calibration.qy0Mean == 9.25)
                #expect(v.calibration.ellipseA == 1.5 && v.calibration.ellipseB == 1.25 && v.calibration.ellipseTheta == -0.25)
                #expect(v.calibration.probeSemiangle == 20.5)
                // Edge values survive: negative zero and 1e300 are stored exactly.
                #expect(v.peaks(row: 0, column: 2)[0].qy.bitPattern == (-0.0).bitPattern)
                #expect(v.peaks(row: 0, column: 2)[0].intensity == 1e300)
                #expect(v.peaks(row: 0, column: 0).count == 2 && v.peaks(row: 0, column: 1).isEmpty)
            } else {
                #expect(v.calibration.qrRotation == nil && v.calibration.ellipseA == nil)
            }
        }
        // An explicit group path reads the same object.
        let explicit = try BraggVectorsEMD.read(path: fixture("basic.h5"), groupPath: "/braggvectors_root/braggvectors")
        #expect(sameBits(explicit.peaks, try BraggVectorsEMD.read(path: fixture("basic.h5")).peaks))
    }

    @Test func theAppAxisConventionIsAnExplicitSwap() throws {
        let stored = try BraggVectorsEMD.read(path: fixture("basic.h5"))
        let app = try BraggVectorsEMD.read(path: fixture("basic.h5"), convention: .appImageXY)
        for (a, b) in zip(stored.peaks.joined(), app.peaks.joined()) {
            #expect(a.qx.bitPattern == b.qy.bitPattern && a.qy.bitPattern == b.qx.bitPattern && a.intensity == b.intensity)
        }
        // Pinned to mac4DSTEM's own writer (writePeakGrid): an app peak at x = 3 (column), y = 7 (row) is stored as qx = 7, qy = 3.
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.h5")
        try BraggVectorsEMD.write(peaks: [[BraggPeak(qx: 3, qy: 7, intensity: 5)]], scan: BraggGridShape(rows: 1, columns: 1),
                                  detector: BraggGridShape(rows: 16, columns: 16), to: url, convention: .appImageXY)
        let raw = try BraggVectorsEMD.read(path: url.path)
        #expect(raw.peaks(row: 0, column: 0) == [BraggPeak(qx: 7, qy: 3, intensity: 5)])
        #expect(try BraggVectorsEMD.read(path: url.path, convention: .appImageXY).peaks(row: 0, column: 0)
                == [BraggPeak(qx: 3, qy: 7, intensity: 5)])
    }

    // MARK: Writing

    private func swiftWritten(_ source: BraggVectorsEMD, name: String, extras: Bool = false) throws -> (url: URL, directory: URL) {
        let injected = ProcessInfo.processInfo.environment["FORMATO_BRAGG_FIXTURE_DIR"]
        let dir = try injected.map { URL(fileURLWithPath: $0) } ?? scratch()
        let url = dir.appendingPathComponent(name)
        @Sendable func appAttributes(_ target: BraggAttributeTarget) -> [String: String] {
            switch target {
            case .file: return ["mac4dstem_session": "1"]
            case .root: return ["mac4dstem_schema": "7"]
            case .braggVectors: return ["mac4dstem_detection_provenance": #"{"detector":"test"}"#]
            }
        }
        try BraggVectorsEMD.write(peaks: source.peaks, scan: source.scan, detector: source.detector,
                                  calibration: source.calibration, to: url,
                                  extraAttributes: extras ? appAttributes : nil)
        return (url, dir)
    }

    @Test func writtenFilesRoundTripBitForBitAndMatchTheCommittedFixtures() throws {
        for (source, name, extras) in [("basic", "swift-basic.h5", false), ("empty", "swift-empty.h5", false), ("basic", "swift-extras.h5", true)] {
            let original = try BraggVectorsEMD.read(path: fixture(source + ".h5"))
            let (url, dir) = try swiftWritten(original, name: name, extras: extras)
            defer { if ProcessInfo.processInfo.environment["FORMATO_BRAGG_FIXTURE_DIR"] == nil { try? FileManager.default.removeItem(at: dir) } }
            let back = try BraggVectorsEMD.read(path: url.path, attributeNames: ["mac4dstem_session", "mac4dstem_schema", "mac4dstem_detection_provenance"])
            #expect(back.scan == original.scan && back.detector == original.detector)
            #expect(sameBits(back.peaks, original.peaks))
            #expect(back.calibration == original.calibration)
            #expect(back.attributes[.file]?["mac4dstem_session"] == (extras ? "1" : nil))
            #expect(back.attributes[.root]?["mac4dstem_schema"] == (extras ? "7" : nil))
            #expect(back.attributes[.braggVectors]?["mac4dstem_detection_provenance"] == (extras ? #"{"detector":"test"}"# : nil))
            // The writer's output has the size of the committed file (the structure is checked by check.py, pinned below).
            let committed = fixtures.appendingPathComponent(name)
            #expect(try Data(contentsOf: url).count == Data(contentsOf: committed).count, "\(name): the writer's layout changed")
            #expect(sameBits(try BraggVectorsEMD.read(path: committed.path).peaks, original.peaks))
        }
    }

    /// check.py's result: py4DSTEM reads each committed Swift-written file, its peaks and calibration equal py4DSTEM's own to the
    /// bit, and h5py shows the same group/dataset/attribute structure as the py4DSTEM-written file (named extras excepted).
    @Test func py4DSTEMAndH5pyAgreeWithTheCommittedSwiftFiles() throws {
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("check-result.json"))) as! [String: Any]
        #expect(result["py4dstem_version"] as? String == "0.14.19")
        let files = result["files"] as! [String: [String: Any]]
        #expect(Set(files.keys) == ["swift-basic.h5", "swift-empty.h5", "swift-extras.h5"])
        for (name, entry) in files {
            let digest = SHA256.hash(data: try Data(contentsOf: fixtures.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            #expect(entry["sha256"] as? String == digest, "\(name) changed after check.py ran: rerun it")
            for key in ["py4dstem_reads", "counts_equal", "peaks_bit_exact", "shapes_equal", "calibration_equal", "extras_present", "structure_equal"] {
                #expect(entry[key] as? Bool == true, "\(name): \(key)")
            }
        }
        #expect(files["swift-extras.h5"]?["extra_attribute_names"] as? [String] ==
            ["/braggvectors_root/braggvectors@mac4dstem_detection_provenance", "/braggvectors_root@mac4dstem_schema", "/@mac4dstem_session"].sorted())
    }

    // MARK: Refusals

    @Test func malformedFilesThrowTypedErrorsAndNeverCrash() throws {
        let m = fixture("malformed.h5")
        func bad(_ root: String) -> Error? {
            do { _ = try BraggVectorsEMD.read(path: m, groupPath: "/\(root)_root/braggvectors"); return nil } catch { return error }
        }
        for root in ["noshape", "mismatch", "notvlen", "zeroshape", "nodata", "wrongclass", "badcal", "badstring"] {
            let error = try #require(bad(root), "\(root) must throw")
            #expect(error is BraggVectorsEMDError, "\(root): \(error)")
            if case BraggVectorsEMDError.malformed = error {} else { Issue.record("\(root): expected malformed, got \(error)") }
        }
        #expect(throws: BraggVectorsEMDError.self) { try BraggVectorsEMD.read(path: fixture("plain.h5")) }
        do { _ = try BraggVectorsEMD.read(path: fixture("two.h5")); Issue.record("two BraggVectors groups must need a groupPath") }
        catch let e as BraggVectorsEMDError { if case .unsupported = e {} else { Issue.record("two.h5: \(e)") } }
        #expect(try BraggVectorsEMD.read(path: fixture("two.h5"), groupPath: "/b_root/braggvectors").peakCount == 7)
        #expect(throws: BraggVectorsEMDError.self) { try BraggVectorsEMD.read(path: fixture("basic.h5"), groupPath: "/nope/braggvectors") }
        #expect(throws: BraggVectorsEMDError.self) { try BraggVectorsEMD.read(path: "/nonexistent/bragg.h5") }
    }

    @Test func truncatedAndForeignInputThrows() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let whole = try Data(contentsOf: fixtures.appendingPathComponent("basic.h5"))
        var cases: [(String, Data)] = [("empty", Data()), ("text", Data("not an hdf5 file\n".utf8)), ("signature", whole.prefix(8)),
                                       ("superblock", whole.prefix(96))]
        for fraction in [4, 2] { cases.append(("trunc\(fraction)", whole.prefix(whole.count / fraction))) }
        cases.append(("short", whole.prefix(whole.count - 1)))
        for (name, data) in cases {
            let url = dir.appendingPathComponent(name + ".h5")
            try data.write(to: url)
            #expect(throws: BraggVectorsEMDError.self, "\(name)") { try BraggVectorsEMD.read(path: url.path) }
        }
    }

    @Test func theWriterRefusesBadInput() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.h5")
        let one = BraggGridShape(rows: 1, columns: 1), det = BraggGridShape(rows: 4, columns: 4)
        let peak = BraggPeak(qx: 1, qy: 2, intensity: 3)
        func refused(_ body: () throws -> Void, _ label: String) {
            do { try body(); Issue.record("\(label) must throw") } catch let e as BraggVectorsEMDError {
                if case .invalidInput = e {} else { Issue.record("\(label): \(e)") }
            } catch { Issue.record("\(label): \(error)") }
        }
        refused({ try BraggVectorsEMD.write(peaks: [], scan: one, detector: det, to: url) }, "count mismatch")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: BraggGridShape(rows: 0, columns: 1), detector: det, to: url) }, "zero scan")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: one, detector: BraggGridShape(rows: 4, columns: 0), to: url) }, "zero detector")
        refused({ try BraggVectorsEMD.write(peaks: [[BraggPeak(qx: .nan, qy: 0, intensity: 0)]], scan: one, detector: det, to: url) }, "NaN")
        refused({ try BraggVectorsEMD.write(peaks: [[BraggPeak(qx: 0, qy: .infinity, intensity: 0)]], scan: one, detector: det, to: url) }, "inf")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: one, detector: det, to: url, rootName: "a/b") }, "slash in the root name")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: one, detector: det, to: url, nodeName: "") }, "empty node name")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: one, detector: det, to: url,
                                            extraAttributes: { _ in ["python_class": "x"] }) }, "reserved attribute")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: one, detector: det, to: url,
                                            extraAttributes: { $0 == .file ? ["UUID": "x"] : [:] }) }, "reserved file attribute")
        refused({ try BraggVectorsEMD.write(peaks: [[peak]], scan: one, detector: det, to: url,
                                            extraAttributes: { _ in ["bad\0name": "x"] }) }, "NUL in attribute name")
        #expect(try listing(dir).isEmpty, "a refused write leaves nothing behind")
    }

    // MARK: Atomic publish

    @Test func theDestinationIsNeverTheSourceAndNothingIsOverwritten() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("scan.h5")
        let original = Data("the source, byte for byte".utf8)
        try original.write(to: source)
        let args: (peaks: [[BraggPeak]], scan: BraggGridShape, det: BraggGridShape) =
            ([[BraggPeak(qx: 1, qy: 2, intensity: 3)]], BraggGridShape(rows: 1, columns: 1), BraggGridShape(rows: 4, columns: 4))
        func expectRefused(_ destination: URL, label: String) {
            do {
                try BraggVectorsEMD.write(peaks: args.peaks, scan: args.scan, detector: args.det, to: destination, sourcePath: source.path)
                Issue.record("\(label) must be refused")
            } catch let e as BraggVectorsEMDError { if case .destinationIsSource = e {} else { Issue.record("\(label): \(e)") } }
            catch { Issue.record("\(label): \(error)") }
        }
        expectRefused(source, label: "same path")
        expectRefused(dir.appendingPathComponent("./scan.h5"), label: "other spelling")
        let link = dir.appendingPathComponent("link.h5")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        expectRefused(link, label: "symlink")
        let hard = dir.appendingPathComponent("hard.h5")
        try FileManager.default.linkItem(at: source, to: hard)
        expectRefused(hard, label: "hard link")
        #expect(try Data(contentsOf: source) == original)
        #expect(try listing(dir) == ["hard.h5", "link.h5", "scan.h5"], "no temporary file")
    }

    @Test func publishReplacesAnExistingDestinationAtomicallyAndLeavesNoTemporaryFile() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vectors.h5")
        try Data("old contents".utf8).write(to: url)
        let basic = try BraggVectorsEMD.read(path: fixture("basic.h5"))
        try BraggVectorsEMD.write(peaks: basic.peaks, scan: basic.scan, detector: basic.detector, calibration: basic.calibration,
                                  to: url, sourcePath: fixture("basic.h5"))
        #expect(try listing(dir) == ["vectors.h5"])
        #expect(sameBits(try BraggVectorsEMD.read(path: url.path).peaks, basic.peaks))

        // Cancelled mid-write: the old file survives, nothing is left beside it.
        let before = try Data(contentsOf: url)
        let polls = Mutex(0)
        #expect(throws: FormatoCancelled.self) {
            try BraggVectorsEMD.write(peaks: basic.peaks, scan: basic.scan, detector: basic.detector, to: url,
                                      cancelled: { polls.withLock { $0 += 1; return $0 >= 3 } })
        }
        #expect(polls.withLock { $0 } >= 3)
        #expect(try Data(contentsOf: url) == before)
        #expect(try listing(dir) == ["vectors.h5"])

        // Cancelled at the end, after the whole temporary file exists: still nothing published, nothing left.
        let calls = Mutex(0)
        #expect(throws: FormatoCancelled.self) {
            try BraggVectorsEMD.write(peaks: basic.peaks, scan: basic.scan, detector: basic.detector, to: url,
                                      cancelled: { calls.withLock { $0 += 1; return $0 > basic.scan.rows + 1 } })
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try listing(dir) == ["vectors.h5"])

        // A destination folder that does not exist: a typed publish error, no stray file.
        let missing = dir.appendingPathComponent("no-such-folder/vectors.h5")
        #expect(throws: BraggVectorsEMDError.self) {
            try BraggVectorsEMD.write(peaks: basic.peaks, scan: basic.scan, detector: basic.detector, to: missing)
        }
        #expect(try listing(dir) == ["vectors.h5"])
    }
}
