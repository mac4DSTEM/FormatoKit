import Testing
import Foundation
import FormatoCore
import FormatoEMD

/// The 0.2.0 refuter's findings: a ScanSize x ScanArea that overflows Int must give no grid (it trapped,
/// default path too); unit strings are trimmed as Pint trims them (ASCII whitespace), not Foundation's wider set.
@Suite struct Refuter020Tests {
    private func metadata(width: String, height: String, right: String) throws -> VeloxMetadata {
        let json = #"{"Scan": {"ScanSize": {"width": "\#(width)", "height": "\#(height)"}, "ScanArea": {"left": "0", "top": "0", "right": "\#(right)", "bottom": "1"}}}"#
        return try VeloxMetadata.parse(jsonData: Data(json.utf8))
    }

    @Test func testAnOverflowingScanGridGivesNoGrid() throws {
        let huge = try metadata(width: "4", height: "4", right: "1e30")
        #expect(huge.derivedGrid == nil, "ScanArea right 1e30")
        let wide = try metadata(width: "4611686018427387904", height: "4", right: "8")
        #expect(wide.derivedGrid == nil, "ScanSize 2^62 x area 8")
        let fine = try metadata(width: "4", height: "4", right: "1")
        let grid = try #require(fine.derivedGrid)
        #expect(grid.ny == 4)
        #expect(grid.nx == 4)
    }

    @Test func testUnitsAreTrimmedAsPintTrimsThem() {
        #expect(FormatoUnits.parse("\u{200B}nm") == nil, "a zero-width space: Pint raises")
        #expect(FormatoUnits.parse("\u{00A0}nm") == nil, "a no-break space: Pint raises")
        #expect(FormatoUnits.parse("nm\u{3000}") == nil, "an ideographic space: Pint raises")
        #expect(FormatoUnits.parse("\nnm") != nil, "a newline: Pint reads")
        #expect(FormatoUnits.parse(" nm\t") != nil, "spaces and a tab: Pint reads")
    }
}
