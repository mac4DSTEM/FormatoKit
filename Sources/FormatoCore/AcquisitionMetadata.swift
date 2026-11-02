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

/// A pixel size in one stated unit: the length of a row step and of a column step.
public nonisolated struct PixelSize: Sendable, Equatable {
    /// The size along the rows' direction (one step to the next row; the file's height).
    public let rows: Double
    /// The size along a row (one step to the next column; the file's width).
    public let columns: Double
    /// The unit as the file writes it ("m"), never converted.
    public let units: String

    public init(rows: Double, columns: Double, units: String) {
        self.rows = rows; self.columns = columns; self.units = units
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
    /// integer for MRC, with a note that no published reader decodes it.
    public var mode: MetadataReading<String>?

    // MARK: Added in 0.3.1 (additive). Read by the `.rosettaSciIO` convention only, where RosettaSciIO 049e7d70 maps the key
    // and the file carries it; the `.app` convention leaves them nil (the consumer's readers do not read them). They are
    // not in `Field`, so `unread` and the panel's nine rows are unchanged. A value is as RosettaSciIO's mapping returns
    // it; where its unit conversion differs between formats the `note` names what was done to the stored number.

    /// The microscope model, where `instrument` holds another name: Velox `.rosettaSciIO` puts `InstrumentClass` in
    /// `instrument` (RosettaSciIO's microscope) and the stored `InstrumentModel` here.
    public var instrumentModel: MetadataReading<String>?
    /// Stage alpha tilt in degrees (SEM: the stage's single tilt, noted).
    public var stageTiltAlphaDeg: MetadataReading<Double>?
    /// Stage beta tilt in degrees.
    public var stageTiltBetaDeg: MetadataReading<Double>?
    /// Stage rotation in degrees (SEM).
    public var stageRotationDeg: MetadataReading<Double>?
    /// Stage position, the number RosettaSciIO's `Stage.x`, `.y`, `.z` holds; the note names the conversion applied to the stored value.
    public var stageX: MetadataReading<Double>?
    public var stageY: MetadataReading<Double>?
    public var stageZ: MetadataReading<Double>?
    /// Beam (probe) current in nA.
    public var beamCurrentNA: MetadataReading<Double>?
    /// SEM working distance in mm (stored in m: ×1e3).
    public var workingDistanceMM: MetadataReading<Double>?
    /// The operator (RosettaSciIO's `General.authors`).
    public var operatorName: MetadataReading<String>?
    /// The specimen description (RosettaSciIO's `Sample.description`).
    public var sampleDescription: MetadataReading<String>?
    /// Signal-type groups of a DM file, keyed by RosettaSciIO's metadata path below `Acquisition_instrument.` (and below its
    /// microscope key): "Detector.EELS.frame_number", "Detector.EDS.live_time", "Spectrometer.central_wavelength" ... Numbers and
    /// texts as the tag holds them (RosettaSciIO's `None` mapping), or as its named function returns them (`docs/parity.md`).
    public var signalNumbers: [String: MetadataReading<Double>] = [:]
    public var signalTexts: [String: MetadataReading<String>] = [:]
    /// EELS collection semi-angle in mrad. A Velox EELS spectrum image (`velox(eelsSpectrumImage:)`, `.rosettaSciIO` only) also
    /// fills it, where RosettaSciIO maps nothing: from the value pyEELSMODEL reads, named in the `note`.
    public var collectionAngleMrad: MetadataReading<Double>?

    // MARK: Added in 0.11.0 (additive). Read by the Velox reader under `.rosettaSciIO`; every other reader and the `.app` convention
    // leave it nil.

    /// The pixel size of the image at the specimen (Velox `BinaryResult.PixelSize`), in the unit the file states, as stored:
    /// RosettaSciIO uses it as the axis scale, not as metadata, so the `note` says what the file does not settle.
    public var pixelSize: MetadataReading<PixelSize>?
    /// Convergence semi-angle in mrad. A Velox EELS spectrum image (`velox(eelsSpectrumImage:)`, `.rosettaSciIO` only) also fills
    /// it, with a note that no published reader reads the stored value.
    public var convergenceAngleMrad: MetadataReading<Double>?

    // MARK: Added after 0.11.0 (additive). Read by the DM reader from an image object (`AcquisitionMetadata.dm(_:convention:)`), and
    // by the TIFF reader from a GMS TIFF's tag 65027 stream by the same rules, under both conventions; every other reader, and
    // `dm(numbers:strings:)`, leave it nil.

    /// The camera's own pixel pitch, where the file records it: the sensor's physical pixel, before any binning; not the pixel
    /// at the specimen (`pixelSize`). DM: `Acquisition.Device.CCD.Pixel Size (um)`, two numbers stored as (x, y), so `columns`
    /// is the first and `rows` the second, units "um" as the tag names them; the note says so when the two differ. Not the
    /// binned frame pixel (`Acquisition.Frame.CCD.Pixel Size (um)`). Nil when the tag is absent, does not hold exactly two
    /// numbers, or holds one that is not finite and positive. RosettaSciIO maps the tag for a CL signal only (its
    /// `Detector.pixel_size`, also in `signalNumbers`); on any other signal `.rosettaSciIO` notes that no published reader reads it. The
    /// `.app` convention reads it too (an extension of the consumer's rule set, which has no pitch), unlabelled.
    public var cameraPixelPitch: MetadataReading<PixelSize>?

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
    /// The note `cameraPixelPitch` carries when its two stored numbers differ.
    public static let unequalPitchNote = "the two differ: columns from the first stored number, rows from the second (the stored order)"

    /// Rule (b): a strictly positive quantity, or nil.
    public static func positive(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// Python's `round(x, digits)` of a double: the exact decimal value rounded half-even, as `String(format:)` does.
    package static func roundLikePython(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.\(digits)f", x)) ?? x
    }

    /// NumPy's `degrees` of a double: `x * (180 / pi)`.
    package static func degreesLikeNumPy(_ x: Double) -> Double { x * (180.0 / Double.pi) }

    /// Python's `round(x, digits)` of a double.
    @available(*, deprecated, message: "An internal helper of the kit; it becomes package-only in 0.13.0.")
    public static func pythonRound(_ x: Double, _ digits: Int) -> Double { roundLikePython(x, digits) }

    /// NumPy's `degrees` of a double.
    @available(*, deprecated, message: "An internal helper of the kit; it becomes package-only in 0.13.0.")
    public static func numpyDegrees(_ x: Double) -> Double { degreesLikeNumPy(x) }

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

/// Which behaviour a format's acquisition-metadata reader follows where RosettaSciIO and the first consumer differ.
///
/// `.rosettaSciIO` (the default) follows RosettaSciIO at the pinned commit for every field RosettaSciIO maps: its tag
/// choice, its mode tests and its unit arithmetic, with no positivity rule (a stored zero is 0, not nil). A field
/// RosettaSciIO does not map is read by the consumer's rule and carries the format's wording of
/// ``AcquisitionMetadata/noPublishedReaderNote``.
/// `.app` is the consumer's own rule set (a to g above), pinned to its source; `docs/parity.md` lists the differences.
public nonisolated enum AcquisitionMetadataConvention: Sendable, Equatable {
    case rosettaSciIO
    case app
}

extension AcquisitionMetadata {
    /// The note of a value no RosettaSciIO mapping reads: it is read as the file stores it. Each format's reader attaches
    /// its own wording of this note, naming where in the file the value is stored.
    public static let noPublishedReaderNote = "no published reader reads this field; read as the file stores it"
    /// The same note under its older name.
    public static let unvalidatedNote = noPublishedReaderNote
}
