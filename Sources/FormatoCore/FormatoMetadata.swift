//
//  FormatoMetadata.swift
//  Role: Metadata with provenance. Each entry is a value under RosettaSciIO's metadata
//        key, with where in the file it came from and the rule that made it. An entry without a source does not exist: a
//        value the file does not state is absent, never defaulted.
//

import Foundation

public nonisolated enum FormatoValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    case flag(Bool)

    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
}

/// Where a metadata value came from.
public nonisolated struct FormatoProvenance: Sendable, Equatable {
    /// The file's display name (never the whole path).
    public let file: String
    /// The place inside the file: a DM tag path (`ImageList.2.ImageTags.Microscope Info.Voltage`), a Velox metadata JSON path
    /// (`Data/Image/<id>/Metadata[0].Optics.AccelerationVoltage`), or a description of a structural fact (`ImageList.2.Name`).
    public let source: String
    /// How the value was made from the source, naming the reference rule (`rsciio digitalmicrograph mapping: value / 1000`).
    public let rule: String

    public init(file: String, source: String, rule: String) {
        self.file = file
        self.source = source
        self.rule = rule
    }
}

public nonisolated struct FormatoMetadataEntry: Sendable, Equatable {
    /// RosettaSciIO's metadata path, e.g. `Acquisition_instrument.TEM.beam_energy`.
    public let key: String
    public let value: FormatoValue
    /// The value's units where the key implies some (`kV` for a beam energy); nil otherwise.
    public let units: String?
    public let provenance: FormatoProvenance

    public init(key: String, value: FormatoValue, units: String?, provenance: FormatoProvenance) {
        self.key = key
        self.value = value
        self.units = units
        self.provenance = provenance
    }
}

/// An ordered list of entries, at most one per key.
public nonisolated struct FormatoMetadata: Sendable, Equatable {
    public private(set) var entries: [FormatoMetadataEntry]

    public init(_ entries: [FormatoMetadataEntry] = []) {
        self.entries = []
        for e in entries { set(e) }
    }

    /// Adds `entry`, replacing an entry with the same key in place.
    public mutating func set(_ entry: FormatoMetadataEntry) {
        if let i = entries.firstIndex(where: { $0.key == entry.key }) { entries[i] = entry } else { entries.append(entry) }
    }

    public subscript(key: String) -> FormatoMetadataEntry? { entries.first { $0.key == key } }
    public var keys: [String] { entries.map(\.key) }
}
