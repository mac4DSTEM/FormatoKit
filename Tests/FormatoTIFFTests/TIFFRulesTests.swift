//
//  TIFFRulesTests.swift
//  The small parsing rules step 2 ports (registration step 2 §1.2, §3.3), each by closed-form cases: tifffile's `astype`,
//  RosettaSciIO's DateTime parse, the FEI date and time forms, RosettaSciIO's axis names and its height/width cross-over.
//

import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFRulesTests {
    @Test func testAsTypeTriesIntFloatBoolString() {
        #expect(formatoPythonAsType("42") == .int(42))
        #expect(formatoPythonAsType(" -7 ") == .int(-7))
        #expect(formatoPythonAsType("1.5e-09") == .float(1.5e-09))
        #expect(formatoPythonAsType("4.0") == .float(4.0))
        #expect(formatoPythonAsType("TRUE") == .bool(true))
        #expect(formatoPythonAsType("Quanta") == .string("Quanta"))
        #expect(formatoPythonAsType("0x10") == .string("0x10"))
    }

    @Test func testDateTimeFollowsStrptime() {
        #expect(TIFFSignals.dateTime("2026:10:15 01:02:03")! == ("2026-10-15", "01:02:03"))
        #expect(TIFFSignals.dateTime("2026:1:5 1:2:3")! == ("2026-01-05", "01:02:03"))
        #expect(TIFFSignals.dateTime("2026/10/15 01:02")! == ("2026-10-15", "01:02:00"))
        #expect(TIFFSignals.dateTime("2026:02:30 01:02:03") == nil)
        #expect(TIFFSignals.dateTime("2026:10:15 01:02:03 ") == nil)
    }

    @Test func testFEIDateAndTimeForms() {
        #expect(TIFFSignals.feiDate("10/14/2026") == "2026-10-14")
        #expect(TIFFSignals.feiTime("11:22:33 PM") == "23:22:33")
        #expect(TIFFSignals.feiTime("12:00:01 AM") == "00:00:01")
        #expect(TIFFSignals.feiTime("7:05:09") == "07:05:09")
        #expect(TIFFSignals.feiDate("yesterday") == nil)
    }

    @Test func testOrderAxesByNameCrossesHeightAndWidth() {
        let (s, o, u) = TIFFSignals.ordered(["image series", "height", "width"], (2, 3, 4), (5, 6, 7), ("a", "b", "c"))
        #expect(s == [4, 2, 3])
        #expect(o == [7, 5, 6])
        #expect(u == ["c", "a", "b"])
        #expect(TIFFSignals.axisName("Y") == "height")
        #expect(TIFFSignals.axisName("Q") == "None")
    }
}
