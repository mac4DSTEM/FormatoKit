//
//  FormatoPython.swift
//  Role: the few Python parsing rules the readers port exactly (registration step 1 A5, step 2 §3.3): `float(x)`, `int(s)`,
//        and tifffile's `asbool` and `astype`, so a reader accepts and refuses the same strings RosettaSciIO and tifffile do.
//        Package API: the format modules share them; no consumer calls them.
//

import Foundation

/// Python's `float(x)` on a JSON or INI value: a number (`true` is 1.0, as `float(True)`), or a string Python's float parser
/// accepts (surrounding whitespace, a sign, "nan", "inf", "infinity" in any case, underscores between digits). nil where
/// Python raises. A hex float, which Swift reads and Python does not, is refused.
package nonisolated func formatoPythonFloat(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
        // JSONSerialization keeps some JSON numbers as NSDecimalNumber, whose doubleValue can be one ulp from the correctly
        // rounded value Python's json gives (registration step 4 A1, F5): parse its exact decimal text instead.
        if let d = n as? NSDecimalNumber, let exact = Double(d.stringValue) { return exact }
        return n.doubleValue
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let b as Bool: return b ? 1 : 0
    case let s as String:
        guard var t = underscoresRemoved(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let negative = lower.hasPrefix("-")
        let body = lower.hasPrefix("+") || negative ? String(lower.dropFirst()) : lower
        if body == "nan" { return negative ? -Double.nan : .nan }
        if body == "inf" || body == "infinity" { return negative ? -.infinity : .infinity }
        guard !body.isEmpty, body.allSatisfy({ "0123456789.e+-".contains($0) }) else { return nil }
        return Double(t)
    default:
        return nil
    }
}

/// Python's `int(s)` for a string: surrounding whitespace, an optional sign, decimal digits with single underscores
/// between them. nil where Python raises (a decimal point, an exponent, an empty string, a value beyond Int64).
package nonisolated func formatoPythonInt(_ s: String) -> Int64? {
    guard let t = underscoresRemoved(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    let body = t.hasPrefix("+") || t.hasPrefix("-") ? t.dropFirst() : Substring(t)
    guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int64(t.hasPrefix("+") ? String(t.dropFirst()) : t)
}

/// tifffile's `asbool` with its default lists: "true" / "false" after strip and lower; nil otherwise.
package nonisolated func formatoPythonAsBool(_ s: String) -> Bool? {
    switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true": return true
    case "false": return false
    default: return nil
    }
}

/// A value as tifffile's `astype` leaves it: int, then float, then bool, else the string.
package nonisolated enum FormatoPythonValue: Sendable, Equatable {
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)

    /// `float(value)` of this value; nil where Python raises.
    package var asFloat: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .float(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return formatoPythonFloat(s)
        }
    }
}

/// tifffile's `astype(value)` with its default types (int, float, asbool, bytes2str).
package nonisolated func formatoPythonAsType(_ s: String) -> FormatoPythonValue {
    if let i = formatoPythonInt(s) { return .int(i) }
    if let d = formatoPythonFloat(s) { return .float(d) }
    if let b = formatoPythonAsBool(s) { return .bool(b) }
    return .string(s)
}

private func underscoresRemoved(_ t: String) -> String? {
    guard t.contains("_") else { return t }
    let chars = Array(t)
    for (i, c) in chars.enumerated() where c == "_" {
        guard i > 0, i < chars.count - 1, chars[i - 1].isASCII, chars[i - 1].isNumber,
              chars[i + 1].isASCII, chars[i + 1].isNumber else { return nil }
    }
    return t.filter { $0 != "_" }
}
