//
//  FormatoUnits.swift
//  Role: The unit arithmetic the readers need, ported bit for bit from what RosettaSciIO does with Pint 0.26.1
//        (docs/registration-step-1.md §3.1 and amendment A1.2-3):
//        - `convertUnits(_:from:to:)` is RosettaSciIO's `rsciio.utils._units.convert_units`, `(value * ureg(units)).to(to_units)`;
//        - `convertScaleUnits(_:units:factor:)` is RosettaSciIO Velox's `_convert_scale_units`: the value times half the
//          factor, Pint's `to_compact`, divided by half the factor again, and the compact unit's short form.
//        Units handled: a base of length (m, meter) or time (s, second) with any of Pint's 25 SI prefixes, to the power +1
//        or -1 ("nm", "μm" or "µm", "1/m", "1 / μm"), and "" (dimensionless). Anything else is not converted: the functions
//        return nil and a reader refuses rather than guesses.
//        A conversion is `value * factor`, with Pint's own factor (FormatoUnitsFactors.swift, generated from the pinned
//        venv): Pint's factors are not the quotient of the two prefix scales, so they are carried, not recomputed.
//        Pint is BSD-3-Clause (NOTICE).
//

import Foundation

public nonisolated enum FormatoUnits {
    /// A parsed unit: a prefixed base to a power of +1 or -1, or dimensionless.
    public struct Unit: Sendable, Equatable {
        /// Index into `FormatoUnitsFactors.powers` (the prefix); ignored when `base` is "".
        public let prefixIndex: Int
        /// "m", "s", or "" for dimensionless.
        public let base: String
        /// +1 or -1.
        public let power: Int

        /// Pint's short form (`"{:~}"`): "nm", "μm" (U+03BC), "1 / μm", "s", "" for dimensionless.
        public var shortForm: String {
            if base.isEmpty { return "" }
            let s = FormatoUnitsFactors.symbols[prefixIndex] + base
            return power > 0 ? s : "1 / " + s
        }
    }

    private static let unprefixed = FormatoUnitsFactors.powers.firstIndex(of: 0)!
    private static let names = ["quecto", "ronto", "yocto", "zepto", "atto", "femto", "pico", "nano", "micro", "milli", "centi",
                                "deci", "", "deca", "hecto", "kilo", "mega", "giga", "tera", "peta", "exa", "zetta", "yotta",
                                "ronna", "quetta"]

    /// Parses the units strings the formats carry. nil for anything not handled (see the file header).
    public static func parse(_ text: String) -> Unit? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "dimensionless" { return Unit(prefixIndex: unprefixed, base: "", power: 1) }
        // Pint reads "fm" as the fermi, its own unit, not femto-metre: compacted it gives "Mfm", "mfm", ... (registration step 4
        // A1, F6). Not converted.
        if s == "fm" || s == "1/fm" || s == "1 / fm" { return nil }
        var power = 1
        if s.hasPrefix("1/") || s.hasPrefix("1 /") {
            power = -1
            s = String(s.drop(while: { $0 != "/" }).dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for (base, long) in [("m", "meter"), ("s", "second")] {
            for (i, symbol) in FormatoUnitsFactors.symbols.enumerated() {
                let symbols = symbol == "μ" ? ["μ", "µ"] : [symbol]          // U+03BC and the micro sign U+00B5
                if symbols.contains(where: { s == $0 + base }) || s == names[i] + long || s == names[i] + long + "s" {
                    return Unit(prefixIndex: i, base: base, power: power)
                }
            }
        }
        return nil
    }

    /// Pint's factor from `from` to `to` (same base and power).
    static func factor(_ from: Unit, _ to: Unit) -> Double {
        let n = FormatoUnitsFactors.powers.count
        let table = from.power > 0 ? FormatoUnitsFactors.positive : FormatoUnitsFactors.negative
        return Double(bitPattern: table[from.prefixIndex * n + to.prefixIndex])
    }

    /// RosettaSciIO's `convert_units(value, units, to_units)`. nil when either unit is not handled or the two differ in
    /// base or power (Pint would raise a dimensionality error).
    public static func convertUnits(_ value: Double, from: String, to: String) -> Double? {
        guard let a = parse(from), let b = parse(to), a.base == b.base, a.power == b.power else { return nil }
        if a.base.isEmpty { return value * 1.0 }
        return value * factor(a, b)
    }

    /// RosettaSciIO Velox's `_convert_scale_units(value, units, factor)`, its `factor` exactly as RosettaSciIO passes it
    /// (an axis size, or twice a frame count): returns the compacted value and Pint's short form of the compact unit.
    /// nil when `units` is not handled, and where Pint raises (the value times the factor under- or overflows in the base unit).
    public static func convertScaleUnits(_ value: Double, units: String, factor: Int) -> (value: Double, units: String)? {
        guard let unit = parse(units) else { return nil }
        let half = Double(factor) / 2                       // `factor /= 2`
        let scaled = value * half                           // `factor * v`
        // `to_compact` returns the quantity unchanged when it is unitless, zero, NaN or infinite.
        if unit.base.isEmpty || scaled == 0 || scaled.isNaN || scaled.isInfinite {
            return (scaled / half, unit.shortForm)
        }
        // `_get_compact_base`: the quantity in the unprefixed base, and the power of its one unit.
        let base = Unit(prefixIndex: unprefixed, base: unit.base, power: unit.power)
        let magnitude = scaled * self.factor(unit, base)
        // Pint takes `math.log10` of this magnitude and `math.floor` of the result: a magnitude that under- or overflowed to
        // 0 or infinity raises there (ValueError, OverflowError). Not converted (Gate B F1).
        guard magnitude != 0, magnitude.isFinite else { return nil }
        let l = log10(abs(magnitude)) / Double(unit.power) / 3
        let power = Int(unit.power > 0 ? l.rounded(.down) : l.rounded(.up)) * 3
        // `_pick_compact_unit`: bisect_left over the prefix powers, the last one past the end.
        var index = FormatoUnitsFactors.powers.firstIndex(where: { $0 >= power }) ?? FormatoUnitsFactors.powers.count
        if index >= FormatoUnitsFactors.powers.count { index = FormatoUnitsFactors.powers.count - 1 }
        let compact = Unit(prefixIndex: index, base: unit.base, power: unit.power)
        let converted = scaled * self.factor(unit, compact)   // `quantity.to(new_unit)`, from the original unit
        return (converted / half, compact.shortForm)
    }
}
