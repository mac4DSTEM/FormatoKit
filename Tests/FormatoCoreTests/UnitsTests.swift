//
//  UnitsTests.swift
//  Gate U1 of docs/registration-step-1.md: FormatoUnits against RosettaSciIO's own `convert_units` and Velox
//  `_convert_scale_units` (Pint 0.26.1), bit for bit, on every call the public Velox files make, a seeded sweep and the
//  planted cases (Fixtures/units-pins.json, tools/step-1/pins.py); and the planted closed forms of §4 as literals.
//

import XCTest
import FormatoCore

final class UnitsTests: XCTestCase {
    /// Every record of units-pins.json. Mutations: `to_compact` floor -> round (mutant 11), the factor not halved (12) - red.
    func testEveryPinnedCallIsBitIdenticalToRosettaSciIO() throws {
        let records = try XCTUnwrap(try loadJSON("units-pins.json")["records"] as? [[String: Any]])
        XCTAssertGreaterThan(records.count, 3000)
        var failures = 0, checked = 0
        for r in records {
            guard r["raises"] == nil, let vb = r["value_bits"] as? String, let ob = r["out_bits"] as? String else { continue }
            let value = bits(vb)
            guard let units = r["units"] as? String else {
                // `units is None`: RosettaSciIO returns the value untouched; FormatoKit never passes None (a Velox file without
                // PixelUnitX gives ""), so only the record's own consistency is checked.
                XCTAssertEqual(vb, ob); continue
            }
            checked += 1
            switch r["fn"] as! String {
            case "convert_units":
                let to = r["to_units"] as! String
                guard let got = FormatoUnits.convertUnits(value, from: units, to: to) else {
                    failures += 1; if failures < 10 { XCTFail("convert_units(\(value), \(units), \(to)) not handled") }; continue
                }
                if got.bitPattern != bits(ob).bitPattern {
                    failures += 1; if failures < 10 { XCTFail("convert_units(\(value), \(units), \(to)) = \(hex(got)), Pint \(ob)") }
                }
            case "convert_scale_units":
                let factor = r["factor"] as! Int
                guard let got = FormatoUnits.convertScaleUnits(value, units: units, factor: factor) else {
                    failures += 1; if failures < 10 { XCTFail("convert_scale_units(\(value), \(units), \(factor)) not handled") }; continue
                }
                if got.value.bitPattern != bits(ob).bitPattern || got.units != r["out_units"] as! String {
                    failures += 1
                    if failures < 10 { XCTFail("convert_scale_units(\(value), \(units), \(factor)) = \(hex(got.value)) \(got.units), Pint \(ob) \(r["out_units"]!)") }
                }
            default: XCTFail("unknown fn \(r["fn"]!)")
            }
        }
        XCTAssertEqual(failures, 0, "\(failures) of \(checked) records differ")
    }

    /// §4's closed forms, independent of Pint: the prefix exactly, the value within one unit in the last place.
    func testPlantedClosedForms() throws {
        func ulps(_ a: Double, _ b: Double) -> UInt64 { a.bitPattern > b.bitPattern ? a.bitPattern - b.bitPattern : b.bitPattern - a.bitPattern }
        let a = try XCTUnwrap(FormatoUnits.convertScaleUnits(1.5e-9, units: "m", factor: 100))
        XCTAssertEqual(a.units, "nm"); XCTAssertLessThanOrEqual(ulps(a.value, 1.5), 1)
        let b = try XCTUnwrap(FormatoUnits.convertScaleUnits(2.5e-7, units: "m", factor: 1000))
        XCTAssertEqual(b.units, "μm"); XCTAssertLessThanOrEqual(ulps(b.value, 0.25), 1)
        let c = try XCTUnwrap(FormatoUnits.convertScaleUnits(0.5, units: "s", factor: 40))
        XCTAssertEqual(c.units, "s"); XCTAssertLessThanOrEqual(ulps(c.value, 0.5), 1)   // 0.5 s x 20 = 10 s is already compact
        let z = try XCTUnwrap(FormatoUnits.convertScaleUnits(0, units: "m", factor: 100))
        XCTAssertEqual(z.units, "m"); XCTAssertEqual(z.value, 0)
        let n = try XCTUnwrap(FormatoUnits.convertScaleUnits(.nan, units: "m", factor: 100))
        XCTAssertTrue(n.value.isNaN); XCTAssertEqual(n.units, "m")
        let inv = try XCTUnwrap(FormatoUnits.convertScaleUnits(526850.7664536564, units: "1/m", factor: 36))
        XCTAssertEqual(inv.units, "1 / μm"); XCTAssertLessThanOrEqual(ulps(inv.value, 0.5268507664536564), 1)
        XCTAssertLessThanOrEqual(FormatoUnits.convertUnits(3, from: "µm", to: "nm").map { ulps($0, 3000) } ?? 99, 1)
        XCTAssertNil(FormatoUnits.convertScaleUnits(1, units: "eV", factor: 2), "an unhandled unit is not converted")
        XCTAssertNil(FormatoUnits.convertUnits(1, from: "m", to: "s"), "different bases do not convert")
    }
}
