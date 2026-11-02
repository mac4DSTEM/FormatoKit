//
//  UnitsTests.swift
//  FormatoUnits against RosettaSciIO's own `convert_units` and Velox
//  `_convert_scale_units` (Pint 0.26.1), on every call the public Velox files make, a seeded sweep and the
//  planted cases (Fixtures/units-pins.json, tools/dm-velox-pins/pins.py); and the planted closed forms of §4 as literals.
//  D12: numerics are allowed a written tolerance; the asserts compare exactly today.
//

import Foundation
import Testing
import FormatoCore

@Suite struct UnitsTests {
    /// Every record of units-pins.json. Mutations: `to_compact` floor -> round (mutant 11), the factor not halved (12) - red.
    @Test func testEveryPinnedCallIsBitIdenticalToRosettaSciIO() throws {
        let records = try #require(try loadJSON("units-pins.json")["records"] as? [[String: Any]])
        #expect(records.count > 3000)
        var failures = 0, checked = 0
        for r in records {
            guard r["raises"] == nil, let vb = r["value_bits"] as? String, let ob = r["out_bits"] as? String else { continue }
            let value = bits(vb)
            guard let units = r["units"] as? String else {
                // `units is None`: RosettaSciIO returns the value untouched; FormatoKit never passes None (a Velox file without
                // PixelUnitX gives ""), so only the record's own consistency is checked.
                #expect(vb == ob); continue
            }
            checked += 1
            switch r["fn"] as! String {
            case "convert_units":
                let to = r["to_units"] as! String
                guard let got = FormatoUnits.convertUnits(value, from: units, to: to) else {
                    failures += 1; if failures < 10 { Issue.record("convert_units(\(value), \(units), \(to)) not handled") }; continue
                }
                if got.bitPattern != bits(ob).bitPattern {
                    failures += 1; if failures < 10 { Issue.record("convert_units(\(value), \(units), \(to)) = \(hex(got)), Pint \(ob)") }
                }
            case "convert_scale_units":
                let factor = r["factor"] as! Int
                guard let got = FormatoUnits.convertScaleUnits(value, units: units, factor: factor) else {
                    failures += 1; if failures < 10 { Issue.record("convert_scale_units(\(value), \(units), \(factor)) not handled") }; continue
                }
                if got.value.bitPattern != bits(ob).bitPattern || got.units != r["out_units"] as! String {
                    failures += 1
                    if failures < 10 { Issue.record("convert_scale_units(\(value), \(units), \(factor)) = \(hex(got.value)) \(got.units), Pint \(ob) \(r["out_units"]!)") }
                }
            default: Issue.record("unknown fn \(r["fn"]!)")
            }
        }
        #expect(failures == 0, "\(failures) of \(checked) records differ")
    }

    /// §4's closed forms, independent of Pint: the prefix exactly, the value within one unit in the last place.
    @Test func testPlantedClosedForms() throws {
        func ulps(_ a: Double, _ b: Double) -> UInt64 { a.bitPattern > b.bitPattern ? a.bitPattern - b.bitPattern : b.bitPattern - a.bitPattern }
        let a = try #require(FormatoUnits.convertScaleUnits(1.5e-9, units: "m", factor: 100))
        #expect(a.units == "nm"); #expect(ulps(a.value, 1.5) <= 1)
        let b = try #require(FormatoUnits.convertScaleUnits(2.5e-7, units: "m", factor: 1000))
        #expect(b.units == "μm"); #expect(ulps(b.value, 0.25) <= 1)
        let c = try #require(FormatoUnits.convertScaleUnits(0.5, units: "s", factor: 40))
        #expect(c.units == "s"); #expect(ulps(c.value, 0.5) <= 1)   // 0.5 s x 20 = 10 s is already compact
        let z = try #require(FormatoUnits.convertScaleUnits(0, units: "m", factor: 100))
        #expect(z.units == "m"); #expect(z.value == 0)
        let n = try #require(FormatoUnits.convertScaleUnits(.nan, units: "m", factor: 100))
        #expect(n.value.isNaN); #expect(n.units == "m")
        let inv = try #require(FormatoUnits.convertScaleUnits(526850.7664536564, units: "1/m", factor: 36))
        #expect(inv.units == "1 / μm"); #expect(ulps(inv.value, 0.5268507664536564) <= 1)
        #expect(FormatoUnits.convertUnits(3, from: "µm", to: "nm").map { ulps($0, 3000) } ?? 99 <= 1)
        #expect(FormatoUnits.convertScaleUnits(1, units: "eV", factor: 2) == nil, "an unhandled unit is not converted")
        // Where the value times the factor under- or overflows in the base unit, Pint raises; not converted, no trap.
        #expect(FormatoUnits.convertScaleUnits(5e-324, units: "nm", factor: 2) == nil)
        #expect(FormatoUnits.convertScaleUnits(1e308, units: "1/nm", factor: 2) == nil)
        #expect(FormatoUnits.convertScaleUnits(1e300, units: "Ym", factor: 64) == nil)
        #expect(FormatoUnits.convertUnits(1, from: "m", to: "s") == nil, "different bases do not convert")
    }
}
