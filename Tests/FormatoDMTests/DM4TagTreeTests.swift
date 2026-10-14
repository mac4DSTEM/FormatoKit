import Testing
import Foundation
import FormatoDM

/// `DM4Experiment.tagTree(data:)` reads a BARE DM tag stream: the DM4 stream DigitalMicrograph stores in private TIFF
/// tag 65027, whose root group is the image's ImageTags (no ImageList). Fixture `dm-tag65027-saved-with-DM.dm4` is that
/// tag's bytes sliced out of RosettaSciIO's `test_loading_image_saved_with_DM.tif`; its `.truth.json` is ncempy's
/// `fileDM.allTags` on the same file (ncempy 1.11.1 in the py4dstem conda env; script kept in the lane's scratchpad
/// `dm/extract.py`, leading "." of each key removed, arrays omitted).
@Suite(.serialized) struct DM4TagTreeTests {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func bare() throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("dm-tag65027-saved-with-DM.dm4"))
    }

    @Test func testABareTagStreamListsNoObjectsButTagTreeMatchesNcempy() throws {
        let data = try bare()
        #expect(try DM4Experiment.list(data: data).count == 0)
        let truth = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.fixtures.appendingPathComponent("dm-tag65027-saved-with-DM.truth.json"))) as! [String: Any]
        let wantNumbers = truth["numbers"] as! [String: Double]
        let wantStrings = truth["strings"] as! [String: String]
        #expect(wantNumbers.count > 80)
        let tree = try DM4Experiment.tagTree(data: data)
        // ncempy leaves numeric arrays and structs out of its scalar list; the walk keeps none of those in `numbers` either.
        #expect(tree.numbers == wantNumbers)
        #expect(tree.strings == wantStrings)
        // Hand-checked against DigitalMicrograph's own display: 200 kV, 51x, TEM imaging, BM-UltraScan.
        #expect(tree.numbers["Microscope Info.Voltage"] == 200_000)
        #expect(tree.numbers["Microscope Info.Indicated Magnification"] == 51)
        #expect(tree.strings["Microscope Info.Illumination Mode"] == "TEM")
        #expect(tree.strings["DataBar.Device Name"] == "BM-UltraScan")
    }

    @Test func testATruncatedBareStreamThrowsAtEveryCut() throws {
        let data = try bare()
        // The last 8 bytes are the stream's trailer, which no walk reads; every cut before it loses a required byte.
        for cut in stride(from: 0, to: data.count - 8, by: 7) + [data.count - 9] {
            #expect(throws: (any Error).self, "cut at \(cut)") { try DM4Experiment.tagTree(data: data.prefix(cut)) }
        }
    }

    /// A stream WITH an ImageList is listed exactly as before, and its tag tree keeps the `ImageList.N.` prefix
    /// (the keys are relative to the stream's root, whatever it is).
    @Test func testAStreamWithAnImageListStillListsAndKeepsItsRootPrefix() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("demo-edx-tiny.dm4"))
        let objects = try DM4Experiment.list(data: data)
        #expect(objects.count == 5)
        #expect(objects.first { $0.role == .eds }?.metaDataSignal == "X-ray")
        let tree = try DM4Experiment.tagTree(data: data)
        #expect(tree.strings["ImageList.\(try #require(objects.first { $0.role == .eds }).index).ImageTags.Meta Data.Signal"] != nil)
    }
}
