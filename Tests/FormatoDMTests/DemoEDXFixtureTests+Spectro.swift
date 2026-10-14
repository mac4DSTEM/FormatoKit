// SpectroKit S1 test partition (ADR 064 section 3.3): the methods of DemoEDXFixtureTests that move with the EDX core;
// the rest stay in DemoEDXFixtureTests.swift. Helpers are duplicated, not shared, across the split.
import XCTest
import CryptoKit
import FormatoDM

/// v5.0 WP2 lane S: the simulated 4D-STEM + EDX dataset (`tools/demo-edx/`). The fixture is the TINY variant
/// (6 x 4 scan, 16 x 16 detector, 512 channels at 20 eV, a perturbed energy axis, two 30 %-dead rows; 123 kB) written by `sim_edx.py --tiny` in the GMS
/// multi-object layout of `docs/archive/v5/4d-edx-file-structure-2026-10-05.md` §4a, next to its truth file.
/// The truth carries the SHA-256 of every array as WRITTEN (C order of the logical shape), so these tests compare
/// what our readers return to what the generator wrote, and the scan is not square (6 != 4) so an axis swap shows.
/// Every layout detail the file asserts is a GUESS until a real GMS 4D + EDS file exists (truth `guesses`).
final class DemoEDXFixtureSpectro: XCTestCase {

    private static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    private static var dm4: String { dir.appendingPathComponent("demo-edx-tiny.dm4").path }

    private func truth() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent("demo-edx-tiny.truth.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func hash(_ truth: [String: Any], _ key: String) throws -> String {
        let hashes = try XCTUnwrap(truth["array_sha256_of_written_arrays_C_order"] as? [String: String])
        return try XCTUnwrap(hashes[key])
    }
    private func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private func object(_ objects: [DM4ImageObject], _ role: DM4ImageRole) throws -> DM4ImageObject {
        try XCTUnwrap(objects.first { $0.role == role }, "no \(role) object")
    }

    func testTheFixtureListsFiveObjectsInOrderUnderOneExperiment() throws {
        let objects = try DM4Experiment.list(path: Self.dm4)
        XCTAssertEqual(objects.map(\.role), [.thumbnail, .survey, .scanSignal, .diffraction, .eds])
        XCTAssertEqual(objects.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(objects.map(\.name), ["Image Of demo-edx-tiny.dm4", "ADF Image (SI Survey)", "HAADF Image",
                                             "Diffraction SI", "EDS SI"])
        XCTAssertEqual(objects.map(\.dataTypeName), ["rgba8", "uint16", "float32", "float32", "uint32"])
        // Roles come from the root thumbnail list and the Experiment-keywords labels, not from names or types.
        XCTAssertEqual(objects.map(\.roleSource), [.thumbnailIndex, .label, .label, .label, .label])
        // The thumbnail has no Meta Data group, so no Experiment ID; the four other objects share one.
        XCTAssertEqual(DM4Experiment.experimentIDs(in: objects), ["Spectrum Imaging_10/05/2026_10:00:00 AM"])
        XCTAssertEqual(DM4Experiment.objects(inExperiment: "Spectrum Imaging_10/05/2026_10:00:00 AM", of: objects).map(\.index),
                       [2, 3, 4, 5])
        // Dimensions are fastest first: 6 x 4 scan (nx != ny), detector 16 x 16, 512 channels.
        XCTAssertEqual(try object(objects, .survey).dimensions, [64, 64])
        XCTAssertEqual(try object(objects, .scanSignal).dimensions, [6, 4])
        XCTAssertEqual(try object(objects, .diffraction).dimensions, [16, 16, 6, 4])
        XCTAssertEqual(try object(objects, .eds).dimensions, [6, 4, 512])
    }

    func testTheRectAndTheSurveyLinkOfEverySIObjectMatchTheTruth() throws {
        let objects = try DM4Experiment.list(path: Self.dm4)
        let survey = try object(objects, .survey)
        let truthRect = try XCTUnwrap(((try truth()["edx"]) as? [String: Any])?["rect_survey_pixels_top_left_bottom_right"] as? [Double])
        XCTAssertEqual(truthRect, [24, 14, 44, 44])           // top, left, bottom, right: asymmetric on purpose
        for role in [DM4ImageRole.scanSignal, .diffraction, .eds] {
            let si = try object(objects, role)
            let rect = try XCTUnwrap(si.spectrumImageRect, "\(role)")
            XCTAssertEqual([rect.top, rect.left, rect.bottom, rect.right], truthRect, "\(role)")
            XCTAssertEqual(rect.width / rect.height, 6.0 / 4.0, accuracy: 1e-12, "the rect's aspect is the scan's, \(role)")
            XCTAssertEqual(si.surveyImageID, survey.uniqueID, "\(role)")
            XCTAssertEqual(DM4Experiment.survey(for: si, in: objects)?.index, survey.index, "\(role)")
        }
        XCTAssertNil(survey.spectrumImageRect, "the rect sits on the SI objects, not on the survey")
    }

    func testTheEDSObjectCarriesTheDetectorTagsAndTheEnergyAxis() throws {
        let objects = try DM4Experiment.list(path: Self.dm4)
        let eds = try object(objects, .eds)
        let tags = try XCTUnwrap(eds.eds)
        XCTAssertEqual(tags.azimuthDegrees, 45)
        XCTAssertEqual(tags.elevationDegrees, 22, "the planted physics (round 3), not the Titan file's 18")
        XCTAssertEqual(try XCTUnwrap(tags.solidAngle), 0.7, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tags.realTime), 6 * 4 * 1.0e-3, accuracy: 1e-6)
        // Two of the four scan rows are 30 % dead (live 0.70), two 5 % dead (0.95): the scalar is real x mean live fraction 0.825.
        XCTAssertEqual(try XCTUnwrap(tags.liveTime), 6 * 4 * 1.0e-3 * 0.825, accuracy: 1e-6)
        // Energy axis of the FILE: the generator's axis (E = (i - 23.9) * 0.02 keV, 512 channels) perturbed by E_file = 1.002 E_true - 10 eV,
        // so scale 0.02004 keV and origin 23.9 + 0.010 / 0.02004 = 24.399.
        let energy = try XCTUnwrap(eds.axes[2])
        XCTAssertEqual(energy.units, "keV")
        XCTAssertEqual(energy.origin, 24.399, accuracy: 1e-4)
        XCTAssertEqual(energy.scale, 0.02004, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(eds.axes[0]).units, "nm")
        XCTAssertEqual(try XCTUnwrap(eds.axes[0]).scale, 5, accuracy: 1e-6)
        let diffraction = try object(objects, .diffraction)
        XCTAssertEqual(try XCTUnwrap(diffraction.axes[0]).units, "1/nm")
        XCTAssertEqual(try XCTUnwrap(diffraction.axes[0]).scale, 0.96, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(diffraction.axes[0]).origin, 7.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(diffraction.axes[3]).units, "nm")
    }

    func testTheSurveyAndTheScanImageReadBackEqualToWhatWasWritten() throws {
        let t = try truth()
        let objects = try DM4Experiment.list(path: Self.dm4)
        let survey = try DM4Experiment.readImage(path: Self.dm4, index: try object(objects, .survey).index)
        XCTAssertEqual([survey.width, survey.height], [64, 64])
        var bytes = Data()
        for p in survey.pixels { var v = UInt16(p).littleEndian; bytes.append(Data(bytes: &v, count: 2)) }
        XCTAssertEqual(hex(SHA256.hash(data: bytes)), try hash(t, "survey_uint16"))
        let haadf = try DM4Experiment.readImage(path: Self.dm4, index: try object(objects, .scanSignal).index)
        XCTAssertEqual([haadf.width, haadf.height], [6, 4], "x is the fast axis and the scan is not square")
        var fbytes = Data()
        for p in haadf.pixels { var v = p.bitPattern.littleEndian; fbytes.append(Data(bytes: &v, count: 4)) }
        XCTAssertEqual(hex(SHA256.hash(data: fbytes)), try hash(t, "haadf_ny_nx_float32"))
        // 3D and 4D objects are listed, never decoded here.
        XCTAssertThrowsError(try DM4Experiment.readImage(path: Self.dm4, index: try object(objects, .eds).index))
    }

    func testTheEDSBlobIsEnergySlowestAndItsPerRecipeSumsMatchTheTruthMap() throws {
        // Memory order of the EDS SI is (channel, y, x) with x fastest: a swapped nx/ny reads the wrong recipe's counts.
        let t = try truth()
        let objects = try DM4Experiment.list(path: Self.dm4)
        let eds = try object(objects, .eds)
        XCTAssertEqual(eds.dataByteCount, 6 * 4 * 512 * 4)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: Self.dm4))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(eds.dataOffset))
        let raw = try XCTUnwrap(try handle.read(upToCount: eds.dataByteCount))
        XCTAssertEqual(raw.count, eds.dataByteCount)
        let counts: [UInt32] = raw.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let map = try XCTUnwrap(t["recipe_map"] as? [[Int]])
        XCTAssertEqual(map.count, 4); XCTAssertEqual(map[0].count, 6)
        let names = try XCTUnwrap(t["recipe_names_in_map_order"] as? [String])
        let recipes = try XCTUnwrap(t["recipes"] as? [String: [String: Any]])
        var sums = [Int](repeating: 0, count: names.count)
        for ch in 0..<512 { for y in 0..<4 { for x in 0..<6 {
            sums[map[y][x]] += Int(counts[(ch * 4 + y) * 6 + x])
        } } }
        for (i, name) in names.enumerated() {
            XCTAssertEqual(sums[i], recipes[name]?["realised_total_eds_counts"] as? Int, name)
        }
        let totals = try XCTUnwrap(t["totals_written"] as? [String: Any])
        XCTAssertEqual(counts.reduce(0) { $0 + Int($1) }, totals["eds_counts"] as? Int)
        XCTAssertEqual(names.count, 13, "the tiny scan holds one pixel of every recipe or more")
    }
}
