//
//  DM4EELSSpectrumImageTests.swift
//  Role: Pin `DM4Experiment.readEELSSpectrumImage` (EELS slice 1b, registered in docs/eels-slice-1-registration.md section 1):
//        a 3D EELS spectrum image of a GMS `.dm4` as Float32 counts in (y, x, channel) order, its energy axis, and E0 /
//        convergence / collection semi-angle from the tags RosettaSciIO maps. Tier 2: file handling, no computed number.
//
//  PUBLIC API ONLY, on purpose (no @testable, no `package` access): macTEM is another package and sees only `public`.
//
//  TWO FILES, TWO KINDS OF TRUTH.
//   1. rsciio-EELS_SI.dm4: RosettaSciIO 049e7d70's public digitalmicrograph/3D/EELS_SI.dm4 (sha256 f9b8203f..., a real
//      GMS 2.32 high-loss spectrum image, 2 x 2 x 2048 float32). rsciio-EELS_SI.truth.json is RosettaSciIO's own reading
//      of it (tools/eels-reader/truth.py, the pinned checkout's `file_reader`): shape and axes as rsciio reports them,
//      the sha256 of the counts as float32 little-endian in SpectroKit's (y, x, channel) order, sample values, E0 / alpha /
//      beta as rsciio's mapping gives them. The axis numbers and the three tag values are also typed here as literals.
//      This file is SQUARE (nx = ny), so it cannot show an nx/ny swap; the planted file does.
//   2. eels-planted.dm4 (tools/eels-reader/make_planted.py, standard library only): 21 objects, non-square 3 x 2 x 5 cubes
//      of every type the reader converts, absent tags, the stack-builder tag group, one row, and each refusal. Its voxel
//      rule is repeated below as code (`b`, `RULE`); eels-planted.truth.json is rsciio's reading of the same bytes (so
//      the planted layout is also confirmed by an independent reader).
//
//  Negative controls (SpectroKit EELS slice 1b): each edit below was applied alone to DM4Experiment.swift (the commit
//  that added readEELSSpectrumImage) in a scratch clone and turned at least one test red:
//    M1 x and y swapped in the output index; M2 the returned energy axis taken from the x axis; M3 Voltage not divided by
//    1000; M4 nx and ny read from swapped dimensions; M5 convergence read from the collection tag; M6 int16 decoded as
//    uint16; M7 the channel-block offset forgotten in the output index; M8 the role check removed; M9 the `Data Order
//    Swapped` refusal removed; M10 the stack-builder tag group ignored; M11 the eV unit check removed; M12 Double to
//    Float rounded toward zero instead of to nearest; M13 the file's channel-major order kept; M16 the extent guard
//    removed AND a short read zero-filled.
//  Two single edits stay green on purpose: removing only the extent guard (`end <= source.size`), or only making a short
//  `fetch` zero-fill; each is covered by the other layer (the guard and `fetch` refuse the same condition), so neither
//  alone changes any behaviour. M16 removes both and testCutInsideTheLastBlockWalksButItsReadThrows catches it.
//

import CryptoKit
import Foundation
import XCTest
import FormatoDM

final class DM4EELSSpectrumImageTests: XCTestCase {

    // MARK: Fixtures and truth

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let realPath = fixtures.appendingPathComponent("rsciio-EELS_SI.dm4").path
    private static let plantedPath = fixtures.appendingPathComponent("eels-planted.dm4").path

    /// rsciio's reading of one object, as `truth.py` wrote it. Decoded with `JSONDecoder` (its Double parsing is correctly
    /// rounded; `JSONSerialization` parsed 0.0019920736085623503 two ulps away).
    private struct TruthAxis: Decodable {
        let name: String, size: Int, scale: Double, offset: Double, units: String
    }
    private struct TruthSample: Decodable {
        let y: Int, x: Int, c: Int, value: Double
    }
    private struct TruthObject: Decodable {
        let index: Int, name: String, rsciioShape: [Int], rsciioAxes: [TruthAxis]
        let dataOffset: Int, dataBytes: Int
        let nx: Int?, ny: Int?, channels: Int?, countsSha256: String?, samples: [TruthSample]?
        /// null in the file where rsciio's mapping gave no value (`beamEnergyKev`: convertFromSnakeCase reads "beam_energy_keV" so)
        let beamEnergyKev: Double?, convergenceAngleMrad: Double?, collectionAngleMrad: Double?
    }

    /// One truth file: its objects by one-based `ImageList` index.
    private struct Truth {
        let objects: [Int: TruthObject]
        init(_ name: String) throws {
            struct File: Decodable { let objects: [TruthObject] }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let data = try Data(contentsOf: DM4EELSSpectrumImageTests.fixtures.appendingPathComponent(name))
            objects = Dictionary(uniqueKeysWithValues: try decoder.decode(File.self, from: data).objects.map { ($0.index, $0) })
        }
        func object(_ index: Int) throws -> TruthObject { try XCTUnwrap(objects[index], "no truth for object \(index)") }
    }

    /// sha256 of the counts as float32 little-endian bytes (every supported host is little-endian).
    private func sha256(_ counts: [Float]) -> String {
        SHA256.hash(data: counts.withUnsafeBytes { Data($0) }).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ path: String, _ index: Int) throws -> DM4EELSSpectrumImage {
        try DM4Experiment.readEELSSpectrumImage(path: path, index: index)
    }

    /// The message of a `cannotOpen` the read of `index` throws, on BOTH entry points (path and data); fails otherwise.
    private func cannotOpenMessage(_ path: String, _ index: Int, line: UInt = #line) throws -> String {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        var messages = [String]()
        let reads: [() throws -> Any] = [
            { try DM4Experiment.readEELSSpectrumImage(path: path, index: index) },
            { try DM4Experiment.readEELSSpectrumImage(data: bytes, index: index) },
        ]
        for read in reads {
            do {
                _ = try read()
                XCTFail("object \(index) did not throw", line: line)
            } catch DM4Error.cannotOpen(let message) {
                messages.append(message)
            } catch {
                XCTFail("object \(index) threw \(error), not cannotOpen", line: line)
            }
        }
        XCTAssertEqual(messages.count, 2, line: line)
        XCTAssertEqual(messages.first, messages.last, "path and data entry points give the same message", line: line)
        return messages.first ?? ""
    }

    /// The axes rsciio reports, against the reader's: rsciio lists (Energy loss, y, x), offset = -origin * scale.
    private func assertAxes(_ r: DM4EELSSpectrumImage, _ truth: TruthObject, line: UInt = #line) throws {
        XCTAssertEqual(truth.rsciioAxes.map(\.name), ["Energy loss", "y", "x"], line: line)
        XCTAssertEqual(truth.rsciioAxes.map(\.size), [r.channels, r.ny, r.nx], "axis sizes: channels, ny, nx", line: line)
        XCTAssertEqual(truth.rsciioShape, [r.channels, r.ny, r.nx], "rsciio's array is (channel, y, x)", line: line)
        let mine: [DM4Axis] = [r.energyAxis, try XCTUnwrap(r.object.axes[1], line: line), try XCTUnwrap(r.object.axes[0], line: line)]
        for (axis, theirs) in zip(mine, truth.rsciioAxes) {
            XCTAssertEqual(-axis.origin * axis.scale, theirs.offset, "\(theirs.name) offset = -origin * scale", line: line)
            XCTAssertEqual(axis.scale, theirs.scale, "\(theirs.name) scale", line: line)
            XCTAssertEqual(axis.units, theirs.units, "\(theirs.name) units", line: line)
        }
    }

    // MARK: The real file (RosettaSciIO's EELS_SI.dm4)

    /// The file lists a thumbnail (ImageList.1) and the spectrum image (ImageList.2, role .eels, [2, 2, 2048]).
    func testListFindsTheEELSObjectWithRoleEELS() throws {
        let objects = try DM4Experiment.list(path: Self.realPath)
        XCTAssertEqual(objects.map(\.index), [1, 2])
        XCTAssertEqual(objects.map(\.role), [.thumbnail, .eels])
        let eels = objects[1]
        XCTAssertEqual(eels.name, "EELS_SI")
        XCTAssertEqual(eels.dimensions, [2, 2, 2048])
        XCTAssertEqual(try DM4Experiment.list(data: Data(contentsOf: URL(fileURLWithPath: Self.realPath))), objects)
    }

    /// Reading by path and from the bytes in memory is the same value, and it is the object that was listed.
    func testPathAndDataEntryPointsAgree() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: Self.realPath))
        let byPath = try read(Self.realPath, 2)
        let byData = try DM4Experiment.readEELSSpectrumImage(data: bytes, index: 2)
        XCTAssertEqual(byPath, byData)
        XCTAssertEqual(byPath.object, try DM4Experiment.list(path: Self.realPath)[1])
    }

    /// nx, ny, channels and the three axes: literals typed from the file, and equal to rsciio's reading.
    func testShapeAndAxesAreRsciios() throws {
        let r = try read(Self.realPath, 2)
        XCTAssertEqual([r.nx, r.ny, r.channels], [2, 2, 2048])
        XCTAssertEqual(r.counts.count, 2 * 2 * 2048)
        // ImageList.2.ImageData.Calibrations.Dimension.3: Origin -300, Scale 1, Units "eV" (rsciio offset +300).
        XCTAssertEqual(r.energyAxis, r.object.axes[2])
        XCTAssertEqual(r.energyAxis.origin, -300)
        XCTAssertEqual(r.energyAxis.scale, 1)
        XCTAssertEqual(r.energyAxis.units, "eV")
        // Dimension.1 and .2 (x, y): Origin 0, Scale 0.0019920736085623503, Units micro sign + "m".
        for axis in [r.object.axes[0], r.object.axes[1]] {
            XCTAssertEqual(axis?.origin, 0)
            XCTAssertEqual(axis?.scale, 0.0019920736085623503)
            XCTAssertEqual(axis?.units, "\u{B5}m")
        }
        try assertAxes(r, try Truth("rsciio-EELS_SI.truth.json").object(2))
    }

    /// Every one of the 2 x 2 x 2048 counts equals rsciio's, in (y, x, channel) order: the sha256 of all of them, and
    /// exact samples, so a wrong order shows in both.
    func testEveryCountEqualsRsciio() throws {
        let truth = try Truth("rsciio-EELS_SI.truth.json").object(2)
        let r = try read(Self.realPath, 2)
        XCTAssertEqual([truth.nx, truth.ny, truth.channels], [r.nx, r.ny, r.channels])
        XCTAssertEqual(sha256(r.counts), truth.countsSha256)
        let samples = try XCTUnwrap(truth.samples)
        XCTAssertGreaterThanOrEqual(samples.count, 6)
        for s in samples {
            XCTAssertEqual(Double(r.counts[(s.y * r.nx + s.x) * r.channels + s.c]), s.value, "(y \(s.y), x \(s.x), c \(s.c))")
        }
    }

    /// E0, convergence and collection semi-angle: 200 kV (the tag stores 200000 V), 21 and 62 mrad, as rsciio maps them.
    func testBeamEnergyAndAnglesAreRsciios() throws {
        let r = try read(Self.realPath, 2)
        XCTAssertEqual(r.beamEnergyKeV, 200)
        XCTAssertEqual(r.convergenceSemiAngleMrad, 21)
        XCTAssertEqual(r.collectionSemiAngleMrad, 62)
        let truth = try Truth("rsciio-EELS_SI.truth.json").object(2)
        XCTAssertEqual(r.beamEnergyKeV, truth.beamEnergyKev)
        XCTAssertEqual(r.convergenceSemiAngleMrad, truth.convergenceAngleMrad)
        XCTAssertEqual(r.collectionSemiAngleMrad, truth.collectionAngleMrad)
        XCTAssertEqual(r.object.voltage, 200_000, "the object still carries the voltage as stored (volts)")
    }

    /// Asking for the thumbnail (index 1) or an index the file does not have throws the documented error, never an image.
    func testNonEELSIndexThrowsNotAnEELSSpectrumImage() throws {
        let thumbnail = try cannotOpenMessage(Self.realPath, 1)
        XCTAssertTrue(thumbnail.contains("not an EELS spectrum image"), thumbnail)
        XCTAssertTrue(thumbnail.contains("thumbnail"), "names the role it found: \(thumbnail)")
        for missing in [0, 3, 99, -1] {
            let message = try cannotOpenMessage(Self.realPath, missing)
            XCTAssertTrue(message.contains("no image object \(missing)"), message)
        }
    }

    /// A copy of the file cut inside the data block (at its start, in the middle, one byte short) throws `truncated`, by
    /// path and from memory; so does a copy cut in the tags before the block. The block's position is rsciio's.
    func testTruncatedCopiesThrow() throws {
        let truth = try Truth("rsciio-EELS_SI.truth.json").object(2)
        let start = truth.dataOffset, length = truth.dataBytes
        XCTAssertEqual(length, 2 * 2 * 2048 * 4)
        let whole = try Data(contentsOf: URL(fileURLWithPath: Self.realPath))
        XCTAssertNoThrow(try DM4Experiment.readEELSSpectrumImage(data: whole, index: 2), "the uncut file reads")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eels-truncated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for cut in [start - 1000, start, start + length / 2, start + length - 1] {
            let piece = whole.prefix(cut)
            XCTAssertThrowsError(try DM4Experiment.readEELSSpectrumImage(data: Data(piece), index: 2), "data, cut at \(cut)") {
                guard case DM4Error.truncated = $0 else { return XCTFail("cut at \(cut) threw \($0), not truncated") }
            }
            let file = directory.appendingPathComponent("cut-\(cut).dm4")
            try piece.write(to: file)
            XCTAssertThrowsError(try self.read(file.path, 2), "path, cut at \(cut)") {
                guard case DM4Error.truncated = $0 else { return XCTFail("cut at \(cut) threw \($0), not truncated") }
            }
        }
    }

    // MARK: The planted file

    /// Object 21's pixel block is the last thing in the file (8 bytes of root trailer follow it), so a copy cut INSIDE the
    /// block still walks: the listing is whole and every other object still reads (a read takes only its own bytes), and
    /// only the read of object 21 can notice. It throws `truncated`, by path and from memory; cut after the block it reads.
    func testCutInsideTheLastBlockWalksButItsReadThrows() throws {
        let t = try Truth("eels-planted.truth.json").object(21)
        let whole = try Data(contentsOf: URL(fileURLWithPath: Self.plantedPath))
        XCTAssertEqual(t.dataBytes, 3 * 2 * 5 * 4)
        XCTAssertEqual(whole.count, t.dataOffset + t.dataBytes + 8, "the block is followed only by the 8-byte root trailer")
        let uncut = try DM4Experiment.readEELSSpectrumImage(data: whole, index: 21)
        XCTAssertEqual(uncut.counts.count, 30)
        let object2 = try read(Self.plantedPath, 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eels-last-block-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The block whole but the trailer gone: still reads, equal to the uncut read (so a throw below is the block's).
        let noTrailer = whole.prefix(t.dataOffset + t.dataBytes)
        XCTAssertEqual(try DM4Experiment.readEELSSpectrumImage(data: Data(noTrailer), index: 21), uncut)
        for cut in [t.dataOffset, t.dataOffset + t.dataBytes / 2, t.dataOffset + t.dataBytes - 1] {
            let piece = Data(whole.prefix(cut))
            XCTAssertEqual(try DM4Experiment.list(data: piece).count, 21, "cut at \(cut) still lists every object")
            XCTAssertEqual(try DM4Experiment.readEELSSpectrumImage(data: piece, index: 2), object2, "object 2 does not need the cut bytes")
            XCTAssertThrowsError(try DM4Experiment.readEELSSpectrumImage(data: piece, index: 21), "data, cut at \(cut)") {
                guard case DM4Error.truncated = $0 else { return XCTFail("cut at \(cut) threw \($0), not truncated") }
            }
            let file = directory.appendingPathComponent("cut-\(cut).dm4")
            try piece.write(to: file)
            XCTAssertThrowsError(try self.read(file.path, 21), "path, cut at \(cut)") {
                guard case DM4Error.truncated = $0 else { return XCTFail("cut at \(cut) threw \($0), not truncated") }
            }
        }
    }

    /// Voxel rule of make_planted.py: 3 x 2 x 5 cubes, b = 37 c + 11 y + 3 x, stored by type.
    private static func b(_ x: Int, _ y: Int, _ c: Int) -> Int { 37 * c + 11 * y + 3 * x }

    /// An object index, its name, and the stored value of voxel `b` as the Float32 the reader must return.
    private struct Rule: Sendable {
        let index: Int
        let name: String
        let value: @Sendable (Int) -> Float
    }

    private static let RULE: [Rule] = [
        Rule(index: 2, name: "EELS float32", value: { Float($0) / 4 - 10 }),
        Rule(index: 3, name: "EELS int16", value: { Float(100 * $0 - 8000) }),
        Rule(index: 4, name: "EELS uint16", value: { Float(300 * $0) }),
        Rule(index: 5, name: "EELS uint8", value: { Float($0) }),
        Rule(index: 6, name: "EELS int8", value: { Float($0 - 83) }),
        Rule(index: 7, name: "EELS int32", value: { Float(Int32(1_000_003 * $0 - 80_000_000)) }),
        Rule(index: 8, name: "EELS uint32", value: { Float(UInt32(4_000_000_000 + 1_000_003 * $0)) }),
        Rule(index: 9, name: "EELS float64", value: { Float(Double($0) / 7 + 1e-9) }),
    ]

    /// The listing: 21 objects, the survey, the EELS ones (also the refused ones, whose role is still .eels), one EDS,
    /// one EELS by `Meta Data.Signal` alone (18), a keV one (19), a stack-builder one with a string-only group (20), and a last EELS one whose pixel block ends the file.
    func testPlantedListing() throws {
        let objects = try DM4Experiment.list(path: Self.plantedPath)
        XCTAssertEqual(objects.map(\.index), Array(1...21))
        XCTAssertEqual(objects.map(\.role), [.survey] + Array(repeating: .eels, count: 15) + [.eds, .eels, .eels, .eels, .eels])
        let truth = try Truth("eels-planted.truth.json")
        XCTAssertEqual(objects.map(\.name), try (1...21).map { try truth.object($0).name })
    }

    /// RosettaSciIO calls an object EELS from `Meta Data.Signal` == "EELS" alone (`signal_type`). Object 18 has no known
    /// Label keyword and a name without "eels": it is an EELS object by that tag only, and reads as rsciio reads it.
    func testSignalTagAloneMakesAnEELSObject() throws {
        let objects = try DM4Experiment.list(path: Self.plantedPath)
        let o = objects[17]
        XCTAssertEqual(o.name, "Spectrum cube by signal tag")
        XCTAssertFalse(o.name.lowercased().contains("eels"), "the name does not say EELS")
        XCTAssertEqual(o.imageTagStrings["Meta Data.Signal"], "EELS")
        XCTAssertEqual(o.role, .eels, "by the Signal tag alone, as rsciio's signal_type")
        let t = try Truth("eels-planted.truth.json").object(18)
        XCTAssertEqual(t.name, o.name)
        let r = try read(Self.plantedPath, 18)
        XCTAssertEqual([r.nx, r.ny, r.channels], [3, 2, 5])
        XCTAssertEqual(sha256(r.counts), t.countsSha256, "vs rsciio")
        XCTAssertEqual(r.counts[(1 * 3 + 2) * 5 + 3], 22.0)           // b = 128, float32 rule
        XCTAssertEqual(r.beamEnergyKeV, 100)
        XCTAssertEqual(r.convergenceSemiAngleMrad, 9)
        XCTAssertEqual(r.collectionSemiAngleMrad, 11)
        XCTAssertEqual([r.beamEnergyKeV, r.convergenceSemiAngleMrad, r.collectionSemiAngleMrad],
                       [t.beamEnergyKev, t.convergenceAngleMrad, t.collectionAngleMrad])
        try assertAxes(r, t)
        // The EDS object (label EDS, Signal empty) is still not EELS.
        XCTAssertEqual(objects[16].role, .eds)
    }

    /// The third axis in keV is refused with the unit named, as documented (eV only), even though rsciio reads the file.
    func testEnergyAxisInKeVIsRefused() throws {
        let message = try cannotOpenMessage(Self.plantedPath, 19)
        XCTAssertTrue(message.contains("EELS energy in keV") && message.contains("'keV'") && message.contains("eV"), message)
        let t = try Truth("eels-planted.truth.json").object(19)
        XCTAssertEqual(t.rsciioAxes.first?.units, "keV", "rsciio reads the same axis, in keV")
    }

    /// A `source.Tags at creation` group that holds only a STRING tag still decides where the tags are read: RosettaSciIO looks
    /// in that group whenever `source` exists, finds no voltage and no angles, and returns none; the top-level 60 kV / 1 / 2 mrad
    /// (the decoy) must not be read. (A reader that looks for numbers only in the group would fall back on the decoy.)
    func testStackBuilderGroupWithOnlyAStringHidesTheTopLevelTags() throws {
        let r = try read(Self.plantedPath, 20)
        XCTAssertEqual(r.object.voltage, 60_000, "the decoy is on the object as stored")
        XCTAssertEqual(r.object.imageTagNumbers["Microscope Info.Voltage"], 60_000)
        XCTAssertEqual(r.object.imageTagStrings["source.Tags at creation.Note"], "stacked")
        XCTAssertNil(r.beamEnergyKeV)
        XCTAssertNil(r.convergenceSemiAngleMrad)
        XCTAssertNil(r.collectionSemiAngleMrad)
        let t = try Truth("eels-planted.truth.json").object(20)
        XCTAssertEqual(t.name, "EELS stack builder, strings only")
        XCTAssertNil(t.beamEnergyKev, "rsciio finds no voltage there")
        XCTAssertNil(t.convergenceAngleMrad)
        XCTAssertNil(t.collectionAngleMrad)
        XCTAssertEqual(sha256(r.counts), t.countsSha256)
    }

    /// A cube with a zero dimension ([3, 0, 5]) is refused (`cannotOpen`, the dimensions named), by path and from memory, even
    /// though its empty Data tag agrees with it. RosettaSciIO reads it as an empty (5, 0, 3) array; an empty cube is not an image.
    func testZeroDimensionIsRefused() throws {
        let path = Self.fixtures.appendingPathComponent("eels-refused-zerodim.dm4").path
        let message = try cannotOpenMessage(path, 1)
        XCTAssertTrue(message.contains("[3, 0, 5]") && message.contains("[x, y, energy]"), message)
        struct Shapes: Decodable { let rsciioRaises: Bool; let rsciioShapes: [[Int]] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let truth = try decoder.decode(Shapes.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("eels-refused-zerodim.truth.json")))
        XCTAssertFalse(truth.rsciioRaises)
        XCTAssertEqual(truth.rsciioShapes, [[5, 0, 3]], "rsciio's empty array, recorded")
    }

    /// A Data tag whose length is not the cube's (0, 29 or 31 elements for dims [3, 2, 5]) throws `truncated`, by path and
    /// from memory: never a cube decoded from the bytes after the tag. RosettaSciIO raises on each of these files.
    func testDataTagOfTheWrongLengthThrowsTruncated() throws {
        for name in ["zero", "short", "long"] {
            let path = Self.fixtures.appendingPathComponent("eels-refused-\(name).dm4").path
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let listed = try DM4Experiment.list(data: bytes)
            XCTAssertEqual(listed.count, 1, name)
            XCTAssertEqual(listed[0].dimensions, [3, 2, 5], name)
            struct Refusal: Decodable { let rsciioRaises: Bool; let rsciioException: String }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let truth = try decoder.decode(Refusal.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("eels-refused-\(name).truth.json")))
            XCTAssertTrue(truth.rsciioRaises, "rsciio raises on the \(name) file")
            XCTAssertEqual(truth.rsciioException, "ValueError")
            for read in [{ try self.read(path, 1) }, { try DM4Experiment.readEELSSpectrumImage(data: bytes, index: 1) }] {
                XCTAssertThrowsError(try read(), name) {
                    guard case DM4Error.truncated = $0 else { return XCTFail("\(name) threw \($0), not truncated") }
                }
            }
        }
    }

    /// The cube is 3 wide and 2 high with 5 channels: nx and ny are not interchangeable here, and a voxel is where the
    /// rule puts it. Every type the reader converts, each against the rule (computed here) and against rsciio (sha256 and
    /// samples). Values beyond 2^24 (int32, uint32) and a float64 that is not a float32 are rounded to the nearest Float,
    /// as NumPy's astype does.
    func testNonSquareCubeOfEveryTypeEqualsTheRuleAndRsciio() throws {
        let truth = try Truth("eels-planted.truth.json")
        for rule in Self.RULE {
            let r = try read(Self.plantedPath, rule.index)
            let label = "\(rule.name) (object \(rule.index))"
            XCTAssertEqual(r.object.name, rule.name)
            XCTAssertEqual([r.nx, r.ny, r.channels], [3, 2, 5], label)
            var want = [Float]()
            for y in 0..<2 { for x in 0..<3 { for c in 0..<5 { want.append(rule.value(Self.b(x, y, c))) } } }
            XCTAssertEqual(r.counts, want, "\(label): counts[(y*nx + x)*channels + c] by the rule")
            let t = try truth.object(rule.index)
            XCTAssertEqual(sha256(r.counts), t.countsSha256, "\(label) vs rsciio")
            for s in try XCTUnwrap(t.samples) {
                XCTAssertEqual(Double(r.counts[(s.y * r.nx + s.x) * r.channels + s.c]), s.value, "\(label) (y \(s.y), x \(s.x), c \(s.c))")
            }
            try assertAxes(r, t)
        }
        // A few voxels as literals (x = 2, y = 1, c = 3 is b = 128; x = 1, y = 0, c = 4 is b = 151).
        let f = try read(Self.plantedPath, 2)
        XCTAssertEqual(f.counts[(1 * 3 + 2) * 5 + 3], 22.0)           // 128 / 4 - 10
        XCTAssertEqual(f.counts[(0 * 3 + 1) * 5 + 4], 27.75)          // 151 / 4 - 10
        XCTAssertEqual(f.counts[(1 * 3 + 0) * 5 + 0], -7.25)          // b = 11
        let i = try read(Self.plantedPath, 3)
        XCTAssertEqual(i.counts[(1 * 3 + 2) * 5 + 3], 4800)           // 100 * 128 - 8000
        let u = try read(Self.plantedPath, 8)
        XCTAssertEqual(u.counts[0], 4_000_000_000)
        XCTAssertEqual(u.counts[(1 * 3 + 2) * 5 + 3], Float(UInt32(4_000_000_000 + 1_000_003 * 128)), "rounded to Float32")
    }

    /// The energy axis of the planted cubes is (origin -40, scale 0.25, eV); x and y have their own calibrations, so
    /// the three are not mistaken for each other. The `Brightness` scale (0.5 e-/count) is not applied.
    func testPlantedAxesAndBrightnessNotApplied() throws {
        let r = try read(Self.plantedPath, 2)
        XCTAssertEqual(r.energyAxis, r.object.axes[2])
        XCTAssertEqual([r.energyAxis.origin, r.energyAxis.scale], [-40, 0.25])
        XCTAssertEqual(r.energyAxis.units, "eV")
        XCTAssertEqual([r.object.axes[0]?.origin, r.object.axes[0]?.scale], [1.5, 2.5])
        XCTAssertEqual([r.object.axes[1]?.origin, r.object.axes[1]?.scale], [0, 3.5])
        XCTAssertEqual(r.object.axes[0]?.units, "nm")
        XCTAssertEqual(r.counts[0], -10, "b = 0 stores -10; with Brightness 0.5 applied it would read -5")
    }

    /// E0 / convergence / collection per object: present, partly present, absent, and the stack-builder group.
    func testBeamEnergyAndAnglesPresentAbsentAndStackBuilder() throws {
        // object: (E0 keV, convergence, collection), nil where the planted file has no such tag
        let planted: [Int: (Double?, Double?, Double?)] = [
            2: (80, 17.5, 33.25),      // Voltage 80000 V
            3: (300, nil, nil),        // only the voltage
            4: (nil, 10, nil),         // only the convergence angle
            5: (nil, nil, 20),         // only the collection angle
            6: (nil, nil, nil),        // no tags
            7: (200, nil, nil), 8: (200, nil, nil), 9: (200, nil, nil),
            10: (120, 25, 45),         // under source.Tags at creation; the top-level 60 kV / 1 / 2 mrad is a decoy
            11: (nil, nil, nil),
        ]
        let truth = try Truth("eels-planted.truth.json")
        for (index, want) in planted.sorted(by: { $0.key < $1.key }) {
            let r = try read(Self.plantedPath, index)
            XCTAssertEqual(r.beamEnergyKeV, want.0, "object \(index) E0")
            XCTAssertEqual(r.convergenceSemiAngleMrad, want.1, "object \(index) convergence")
            XCTAssertEqual(r.collectionSemiAngleMrad, want.2, "object \(index) collection")
            let t = try truth.object(index)
            XCTAssertEqual(r.beamEnergyKeV, t.beamEnergyKev, "object \(index) E0 vs rsciio")
            XCTAssertEqual(r.convergenceSemiAngleMrad, t.convergenceAngleMrad, "object \(index) convergence vs rsciio")
            XCTAssertEqual(r.collectionSemiAngleMrad, t.collectionAngleMrad, "object \(index) collection vs rsciio")
        }
        // Object 10: the top-level decoy (60000 V) is still on the object as stored, and is not the beam energy returned.
        let stack = try read(Self.plantedPath, 10)
        XCTAssertEqual(stack.object.voltage, 60_000)
        XCTAssertEqual(stack.beamEnergyKeV, 120)
    }

    /// One row (ny = 1): a 4 x 1 x 3 cube. The rule for it is the same b with its own size; sha256 and axes from rsciio.
    func testOneRowCube() throws {
        let r = try read(Self.plantedPath, 11)
        XCTAssertEqual([r.nx, r.ny, r.channels], [4, 1, 3])
        XCTAssertEqual(r.counts.count, 12)
        var want = [Float]()
        for x in 0..<4 { for c in 0..<3 { want.append(Float(Self.b(x, 0, c)) / 4 - 10) } }
        XCTAssertEqual(r.counts, want)
        let t = try Truth("eels-planted.truth.json").object(11)
        XCTAssertEqual(sha256(r.counts), t.countsSha256)
        try assertAxes(r, t)
        XCTAssertEqual([r.energyAxis.origin, r.energyAxis.scale], [-5, 0.5])
    }

    /// Path and data entry points agree on every readable planted object.
    func testPlantedPathAndDataAgree() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: Self.plantedPath))
        for index in Array(2...11) + [18, 20, 21] {
            XCTAssertEqual(try read(Self.plantedPath, index), try DM4Experiment.readEELSSpectrumImage(data: bytes, index: index), "object \(index)")
        }
    }

    // MARK: Refusals

    /// Everything the reader refuses says why, with the object's name; both entry points.
    func testRefusalsSayWhy() throws {
        let p = Self.plantedPath
        let survey = try cannotOpenMessage(p, 1)
        XCTAssertTrue(survey.contains("not an EELS spectrum image") && survey.contains("survey"), survey)
        let eds = try cannotOpenMessage(p, 17)
        XCTAssertTrue(eds.contains("not an EELS spectrum image") && eds.contains("eds"), eds)
        let nm = try cannotOpenMessage(p, 12)
        XCTAssertTrue(nm.contains("EELS energy in nm") && nm.contains("'nm'") && nm.contains("eV"), nm)
        let swapped = try cannotOpenMessage(p, 13)
        XCTAssertTrue(swapped.contains("Data Order Swapped"), swapped)
        let flat = try cannotOpenMessage(p, 14)
        XCTAssertTrue(flat.contains("dimensions [4, 3]") && flat.contains("[x, y, energy]"), flat)
        let uncalibrated = try cannotOpenMessage(p, 15)
        XCTAssertTrue(uncalibrated.contains("no energy calibration"), uncalibrated)
    }

    /// A pixel type outside int8/16/32, uint8/16/32, float32/64 is `unsupportedDataType` with the file's code (14 = bool).
    func testUnsupportedDataTypeIsNamed() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: Self.plantedPath))
        for read in [{ try self.read(Self.plantedPath, 16) }, { try DM4Experiment.readEELSSpectrumImage(data: bytes, index: 16) }] {
            XCTAssertThrowsError(try read()) {
                guard case DM4Error.unsupportedDataType(14) = $0 else { return XCTFail("threw \($0), not unsupportedDataType(14)") }
            }
        }
    }
}
