//
//  AcquisitionMetadata.swift
//  What a file says about how its image was acquired: high tension, magnification, camera length, detector, dwell,
//  exposure, date, instrument, mode. Each value is as the file stores it, converted to one stated unit, and nil when the
//  file does not record it. One reader per format fills it (FormatoDM, FormatoMRC, FormatoTIFF, FormatoEMD); a metadata
//  reading never moves a pixel or a calibration.
//
//  RULES (each reader states where a rule applies to its format):
//  (a) an absent tag, an empty string or an unparseable value ("notafloat") is nil, never 0;
//  (b) a strictly positive quantity (high tension, magnification, camera length, dwell, exposure) stored as zero,
//      negative or non-finite is nil;
//  (c) camera length only where the mode makes it real; magnification not in a diffraction mode that stores the
//      camera length in its place;
//  (d) a unit the file does not store is stated in `note` ("mm (assumed)");
//  (e) a date is `YYYY-MM-DD HH:MM:SS` on the clock the file was written with; its zone is not stored, so the note says
//      so, and an ambiguous day/month order in a DM date says which was assumed;
//  (f) two stored copies of one number that differ by more than 1e-6 relative are both kept: the first-listed in
//      `value`, the other in `otherCopy`; a second stored timestamp is kept when it differs at the shown second, and a
//      second stamp before 1990 is an unset field, not a copy;
//  (g) magnification is the indicated (nominal) one, never a calibrated "actual" one.
//
//  These rules are the nil and unit rules of the first consumer's readers; where RosettaSciIO's metadata differs, the
//  RosettaSciIO behaviour is the reader's primary API and this rule set a named option (docs/parity.md).
//

import Foundation

/// One value the file records, with what a reader must be told beside it.
public nonisolated struct MetadataReading<Value: Sendable & Equatable>: Sendable, Equatable {
    /// The value, in its field's stated unit.
    public let value: Value
    /// What the file does not settle about it, in plain words ("mm (assumed)"); nil when nothing needs saying.
    public let note: String?
    /// A second stored copy (rule f): for a number, one that differs from `value` by more than 1e-6 relative; for a
    /// date, one that differs at the shown second (a second stamp before 1990 is unset, not a copy); nil otherwise.
    public let otherCopy: Value?

    public init(_ value: Value, note: String? = nil, otherCopy: Value? = nil) {
        self.value = value
        self.note = note
        self.otherCopy = otherCopy
    }
}

public nonisolated struct AcquisitionMetadata: Sendable, Equatable {
    /// High tension in kV (stored in V: /1e3).
    public var highTensionKV: MetadataReading<Double>?
    /// The indicated magnification, × (rule g).
    public var magnification: MetadataReading<Double>?
    /// Camera length in mm (stored in m: ×1e3; DM stores no unit — rule d).
    public var cameraLengthMM: MetadataReading<Double>?
    /// The detector or camera, as the file names it.
    public var detector: MetadataReading<String>?
    /// Pixel dwell in µs (stored in s: ×1e6; DM stores µs).
    public var dwellUS: MetadataReading<Double>?
    /// Exposure in s.
    public var exposureS: MetadataReading<Double>?
    /// The acquisition date the file stamps on the image, `YYYY-MM-DD HH:MM:SS` (rule e). Velox: its start stamp; DM:
    /// the DataBar stamp, taken seconds after the acquisition began (it is not the start); MRC: the FEI timestamp.
    public var acquired: MetadataReading<String>?
    /// The instrument, as the file names it.
    public var instrument: MetadataReading<String>?
    /// The operating mode as the file states it: a name ("STEM", "TEM · DIFFRACTION") for Velox and DM; the stored
    /// integer for MRC, labelled unvalidated (no pinned reference decodes it).
    public var mode: MetadataReading<String>?

    /// The fields this file's FORMAT reader cannot read yet, though the file may record them: shown "Not read from this
    /// format yet", never "Not recorded" (a reader that does not expose them yet). Empty for every other format.
    public var unread: Set<Field> = []

    /// The nine fields, in the order the panel lists them.
    public enum Field: String, CaseIterable, Sendable {
        case highTension, magnification, cameraLength, detector, dwell, exposure, acquired, instrument, mode
    }

    public init() {}

    /// Nothing recorded: every field nil.
    public var isEmpty: Bool { self == AcquisitionMetadata() }

    /// The note a Velox or DM date carries (rule e).
    public static let localTimeNote = "local time, zone not stored"
    /// The note an MRC date carries (rule e): the pinned files disagree on the clock (local vs UTC).
    public static let writerClockNote = "clock of the writer, zone not stored"

    /// Rule (b): a strictly positive quantity, or nil.
    public static func positive(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// Rule (a): text with surrounding whitespace removed, or nil when nothing is left.
    public static func text(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Rule (a): a decimal number parsed from text, or nil when the text is absent, empty or not a decimal number.
    /// Only digits, a sign, a point and an exponent pass: Swift's `Double(String)` also reads C hex floats ("0x10" is
    /// 16) and "nan"/"inf", which the references' Python `float()` refuses or no quantity here can be.
    public static func number(_ s: String?) -> Double? {
        guard let t = text(s), t.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
        return Double(t)
    }

    /// Rule (f): `second` when it differs from `first` by more than 1e-6 relative, else nil.
    public static func differingCopy(_ first: Double, _ second: Double?) -> Double? {
        guard let second, second.isFinite else { return nil }
        let scale = max(abs(first), abs(second))
        return scale > 0 && abs(first - second) > 1e-6 * scale ? second : nil
    }
}
