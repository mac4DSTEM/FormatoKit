//
//  FormatoAxis.swift
//  Role: One dimension of a signal (docs/registration-step-1.md §3.1): uniform, `value(i) = offset + i * scale`, with its
//        units as the reference writes them and whether it navigates (a position) or is the signal (what is measured at a
//        position): RosettaSciIO's axes dictionary, one field each.
//

import Foundation

public nonisolated struct FormatoAxis: Sendable, Equatable {
    /// "x", "y", "Energy loss", "Time", ...; nil where the reference names none.
    public let name: String?
    public let size: Int
    public let scale: Double
    public let offset: Double
    /// As the reference writes them: "nm", "µm" (U+00B5), "1/nm", "eV", "" for none.
    public let units: String
    public let navigate: Bool

    public init(name: String?, size: Int, scale: Double, offset: Double, units: String, navigate: Bool) {
        self.name = name
        self.size = size
        self.scale = scale
        self.offset = offset
        self.units = units
        self.navigate = navigate
    }

    /// The calibrated value of index `i`.
    public func value(at i: Int) -> Double { offset + Double(i) * scale }

    /// Equal including the bit patterns of scale and offset (so −0.0 differs from 0.0, and NaN equals the same NaN).
    public func isBitwiseEqual(to other: FormatoAxis) -> Bool {
        name == other.name && size == other.size && units == other.units && navigate == other.navigate
            && scale.bitPattern == other.scale.bitPattern && offset.bitPattern == other.offset.bitPattern
    }
}
