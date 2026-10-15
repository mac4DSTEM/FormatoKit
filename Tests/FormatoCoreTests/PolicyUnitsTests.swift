//
//  PolicyUnitsTests.swift
//  Registration 0.2.0 P1's building block: `FormatoUnits.scaleOutcome` tells a unit FormatoUnits does not handle (a reader's
//  policy decides) from a conversion Pint raises on (a refusal under every policy), with the arithmetic of `convertScaleUnits`.
//

import Foundation
import Testing
import FormatoCore

@Suite struct PolicyUnitsTests {
    @Test func testUnhandledUnitAndPintRaiseAreToldApart() {
        #expect(FormatoUnits.scaleOutcome(0.5, units: "px", factor: 4) == .unhandledUnit)
        #expect(FormatoUnits.scaleOutcome(0.5, units: "pixels", factor: 4) == .unhandledUnit)
        #expect(FormatoUnits.scaleOutcome(0.5, units: "fm", factor: 4) == .unhandledUnit, "Pint's fermi, not converted (step 4 A1 F6)")
        // 5e-324 nm is 0 in metres: Pint's log10 raises (step 1 Gate B F1). factor 2 halves to 1.
        #expect(FormatoUnits.scaleOutcome(5e-324, units: "nm", factor: 2) == .pintRaises)
        #expect(FormatoUnits.convertScaleUnits(5e-324, units: "nm", factor: 2) == nil)
        #expect(FormatoUnits.convertScaleUnits(0.5, units: "px", factor: 4) == nil)
    }

    @Test func testConvertedOutcomeIsConvertScaleUnits() {
        let cases: [(Double, String, Int)] = [(2e-9, "m", 4), (1.5e-10, "m", 3), (0.001, "s", 3), (7, "", 5), (0, "nm", 2), (3.5, "1/nm", 8)]
        for (value, units, factor) in cases {
            let wrapped = FormatoUnits.convertScaleUnits(value, units: units, factor: factor)
            guard case .converted(let v, let u) = FormatoUnits.scaleOutcome(value, units: units, factor: factor), let wrapped else {
                Issue.record("\(value) \(units) \(factor) is not converted"); continue
            }
            #expect(v.bitPattern == wrapped.value.bitPattern, "\(value) \(units) \(factor)")
            #expect(u == wrapped.units)
        }
    }

    @Test func testPolicyKeyPrefix() {
        #expect(FormatoMetadata.policyKeyPrefix == "FormatoKit.policy.")
        #expect(FormatoUnconvertedUnits.refuse != FormatoUnconvertedUnits.keepAsWritten)
    }
}
