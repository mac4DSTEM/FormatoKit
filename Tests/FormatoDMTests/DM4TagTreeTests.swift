import XCTest
import FormatoDM

/// `DM4Experiment.tagTree(data:)` reads a BARE DM tag stream: the DM4 stream DigitalMicrograph stores in private TIFF
/// tag 65027, whose root group is the image's ImageTags (no ImageList). Fixture `dm-tag65027-saved-with-DM.dm4` is that
/// tag's bytes sliced out of RosettaSciIO's `test_loading_image_saved_with_DM.tif`; its `.truth.json` is ncempy's
/// `fileDM.allTags` on the same file (ncempy 1.11.1 in the py4dstem conda env; script kept in the lane's scratchpad
/// `dm/extract.py`, leading "." of each key removed, arrays omitted).
final class DM4TagTreeTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func bare() throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("dm-tag65027-saved-with-DM.dm4"))
    }

    func testABareTagStreamListsNoObjectsButTagTreeMatchesNcempy() throws {
        let data = try bare()
        XCTAssertEqual(try DM4Experiment.list(data: data).count, 0)
        let truth = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.fixtures.appendingPathComponent("dm-tag65027-saved-with-DM.truth.json"))) as! [String: Any]
        let wantNumbers = truth["numbers"] as! [String: Double]
        let wantStrings = truth["strings"] as! [String: String]
        XCTAssertGreaterThan(wantNumbers.count, 80)
        let tree = try DM4Experiment.tagTree(data: data)
        // ncempy leaves numeric arrays and structs out of its scalar list; the walk keeps none of those in `numbers` either.
        XCTAssertEqual(tree.numbers, wantNumbers)
        XCTAssertEqual(tree.strings, wantStrings)
        // Hand-checked against DigitalMicrograph's own display: 200 kV, 51x, TEM imaging, BM-UltraScan.
        XCTAssertEqual(tree.numbers["Microscope Info.Voltage"], 200_000)
        XCTAssertEqual(tree.numbers["Microscope Info.Indicated Magnification"], 51)
        XCTAssertEqual(tree.strings["Microscope Info.Illumination Mode"], "TEM")
        XCTAssertEqual(tree.strings["DataBar.Device Name"], "BM-UltraScan")
    }

    func testATruncatedBareStreamThrowsAtEveryCut() throws {
        let data = try bare()
        // The last 8 bytes are the stream's trailer, which no walk reads; every cut before it loses a required byte.
        for cut in stride(from: 0, to: data.count - 8, by: 7) + [data.count - 9] {
            XCTAssertThrowsError(try DM4Experiment.tagTree(data: data.prefix(cut)), "cut at \(cut)")
        }
    }

    /// A stream WITH an ImageList is listed exactly as before, and its tag tree keeps the `ImageList.N.` prefix
    /// (the keys are relative to the stream's root, whatever it is).
    func testAStreamWithAnImageListStillListsAndKeepsItsRootPrefix() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("demo-edx-tiny.dm4"))
        let objects = try DM4Experiment.list(data: data)
        XCTAssertEqual(objects.count, 5)
        XCTAssertEqual(objects.first { $0.role == .eds }?.metaDataSignal, "X-ray")
        let tree = try DM4Experiment.tagTree(data: data)
        XCTAssertNotNil(tree.strings["ImageList.\(try XCTUnwrap(objects.first { $0.role == .eds }).index).ImageTags.Meta Data.Signal"])
    }
}
