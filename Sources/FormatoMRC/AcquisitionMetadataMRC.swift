//
//  AcquisitionMetadataMRC.swift
//  Role: the acquisition metadata of a Thermo/FEI MRC2014 file — the FEI1/FEI2 extended header's first record, the
//        image's own — as `AcquisitionMetadata`. Checked against mrcfile 1.5.4's layout on
//        the two FEI2 files of RosettaSciIO's test data. This file reads no pixel and no calibration.
//
//  CONVENTIONS (`AcquisitionMetadataConvention`). `.app` is everything below: the Thermo/FEI FEI1/FEI2 extended
//  header's first record, read by bitmask. `.rosettaSciIO` (default) is RosettaSciIO 049e7d70 `mrc/_api.py`: the machine
//  stamp is ignored (little-endian, `endianness="<"`), and only a header whose NEXT (word 23) is exactly 128 * 1024 bytes
//  is an FEI header, read as the 128-byte per-section record (a_tilt ... magnification; `get_fei_dtype_list`). Its
//  mapping (`mapping`, :711-722) gives the magnification (`fei_header.magnification`, f4 at record byte 48) and the
//  camera exposure (`fei_header.exp_time`, f4 at byte 32, seconds); RosettaSciIO keeps all 1024 sections as arrays and
//  this reads the first section's values, no positivity rule. No other field is mapped; the FEI1/FEI2 files
//  (NEXT 888 * 1024 and the like) read as empty under `.rosettaSciIO`.
//
//  WHAT IS READ: the 1024-byte header as the image reader reads it ("MAP " id, machine stamp, NSYMBT = word 23 = the
//  extended header's length, EXTTYP at bytes 104..<108), then, only when EXTTYP is "FEI1" or "FEI2", the first
//  record of the extended header. A file with another (or no) extended header, one shorter than a record, or whose
//  first record does not state its own size, is "nothing recorded": an empty `AcquisitionMetadata`, not an error.
//  A header that is not MRC throws MRCError (.notMRC, .byteOrder, .truncated) . nx, ny, nz, the mode and the axis order are the image reader's business and are not checked here.
//
//  THE RECORD'S LAYOUT is mrcfile 1.5.4's (mrcfile/dtypes.py, packed, no alignment): FEI1 is 768 bytes
//  (`fei1_dtype_big_endian`, line 205), FEI2 888 bytes (`fei2_dtype_big_endian`, line 227; its extra fields start at
//  byte 768). The offsets below are the fields' offsets in that dtype, cited by the line that declares each:
//      Metadata size  i4 @0 (105)      Bitmask 1 u4 @8 (107)      Timestamp f8 @12 (108)
//      Microscope type S16 @20 (109)   HT f8 @84 (113)            Instrument mode i4 @244 (128)
//      Magnification f8 @289 (134)     Bitmask 2 u4 @297 (135)    Camera length f8 @301 (136)
//      Integration time f8 @419 (152)  Camera name S16 @435 (155) Bitmask 3 u4 @490 (168)
//      STEM Detector name S16 @519 (176)    Dwell time f8 @571 (184)    Bitmask 4 u4 @748 (201)
//      Detector commercial name S16 @804 (216, FEI2 only)
//  The record is valid only when its first int32, "Metadata size", equals the layout's size (mrcfile's own test,
//  mrcobject.py:217): FEI1 768, FEI2 888.
//
//  BYTE ORDER. mrcfile defines the dtype big-endian (dtypes.py:98-103 says the FEI document is unclear, except that
//  the four bitmasks are little-endian), but its `indexed_extended_header` (mrcobject.py:207-209) asks
//  `get_ext_header_dtype(exttyp, <the header's byte order>)` (dtypes.py:230-254), which rebuilds the dtype in the
//  header's order: a little-endian machine stamp (44 44, 44 41) gives an all-little-endian record, a big-endian one
//  (11 11) gives big-endian fields with the four bitmasks still little-endian. This file does the same. So the
//  files' little-endian record is not an exception to mrcfile — mrcfile reads these two files little-endian too
//  (HT 300000.0 on both: the same eight bytes read big-endian are 1.06e-314) — and the earlier note "although
//  mrcfile builds it big-endian" describes only its base dtype.
//
//  THE BITMASKS say which fields the writer filled. Rule: each field of a mask's span has one bit, in field order
//  from bit 0 of the mask that precedes it, EXCEPT that "Unused range" (S48 = six doubles) has six bits. So mask 1
//  covers Timestamp (bit 0) … Pixel size Y (15), the six unused (16–21), Defocus (22), STEM Defocus (23), Applied
//  defocus (24), Instrument mode (25), Projection mode (26), Objective lens mode (27), High magnification mode (28),
//  Probe mode (29), EFTEM On (30), Magnification (31); mask 2 Camera length (0) … Direct detector align frames (27),
//  four reserved (28–31); mask 3 six reserved, Phase Plate (6), STEM Detector name (7), Gain, Offset, five reserved,
//  Dwell time (15) … Input stack filename (31); mask 4 Alpha tilt min (0), Alpha tilt max (1), Scan rotation (2),
//  Diffraction pattern rotation (3), Image rotation (4), Scan mode enumeration (5), Acquisition time stamp (6),
//  Detector commercial name (7) … Objective aperture name (16). Evidence, since the FEI specification page was not
//  reachable: with this rule every mask spans exactly 32 bits (mask 4: 17) and, on both real files, over all 108
//  fields of the first record (and all 256 records of the 4D file) no field with a clear bit holds a nonzero byte;
//  with 0, 1 or 2 bits for "Unused range", four to five fields of HAADFscan.mrc (Defocus, STEM Defocus, Instrument
//  mode …) are nonzero under a clear bit and mask 1 spans 26 to 28 bits. Only the fields read below are used; a
//  field is read only when its bit is set — a clear bit is "not recorded" whatever bytes sit there. Magnification's
//  bit (31) is clear on both real files.
//
//  RULES (AcquisitionMetadata.swift) as applied here:
//  (a) a clear bit, blank text or an unusable timestamp is nil, never 0 or ""; text is cut at its first NUL, then
//      trimmed (a fixed-width field: DEVIATION from numpy's `S16`, which keeps bytes after an embedded NUL; no
//      difference on the two real files);
//  (b) HT, Magnification, Camera length, Dwell time and Integration time must be strictly positive AS SHOWN: the
//      test comes after the unit conversion (V to kV, m to mm, s to µs), as in the reference, so a finite stored
//      value that converts to 0 (a denormal HT) or to infinity (a huge camera length) is nil, never 0.0 or inf. A
//      recorded 0.0 (HAADFscan.mrc's Integration time) is nil. A date is held to the same spirit: finite, > 0,
//      before year 10000;
//  (c) camera length is shown as stored wherever its bit says so ("MRC when its bitmask says so"), with the
//      note `FEIRecord.modeUncheckedNote`, because the rule's guard (a camera length only where the mode makes it
//      real) is NOT applied: the record's Instrument mode and Projection mode are enumerations that no published
//      reader decodes, so there is no mode to test. OPEN DEVIATION from rule (c). The Velox TIFF path does guard (a
//      Ceta TIFF with OperatingMode TEM and ProjectorMode Imaging still stores a CameraLength of 0.844 or 1.365 m, so
//      a Velox MRC taken in TEM imaging probably does too), but no TEM-imaging MRC has been seen, and a positive
//      "STEM or diffraction" gate would remove the real camera length of 4DSTEMscan.mrc, whose mode bits (25, 26)
//      are clear. A TEM-imaging MRC is owed; with one, the two enumerations can be decoded and
//      the gate written as a negation. Magnification: STEM Magnification is 0.0 or unset, hence nil;
//  (d) no unit is assumed: the record states SI units (V, m, s);
//  (e) Timestamp is an OLE automation date: days since 1899-12-30 00:00, on the clock of the writer. It is turned into
//      a calendar date the way Python's `datetime(1899,12,30) + timedelta(days=x)` does: the day fraction to a whole
//      microsecond (half to even), then the seconds TRUNCATED (not rounded — a clock shows 13:13:07 until
//      13:13:08). ONLY THE EPOCH IS ESTABLISHED, by the 4D file's own second clock: its mask-4 "Acquisition time
//      stamp" (i8) is 1670242387346964 µs since 1970 UTC = 2022-12-05 12:13:07.346964, and the OLE value
//      44900.550779478755 is 2022-12-05 13:13:07.346964 on this epoch — the same instant to the microsecond, an hour
//      apart; mrcfile's comment "Not specified, but suspect this is in days after 1/1/1900" (dtypes.py:108) would
//      put it two days later. NOT established, and so not claimed, is the zone: the two pinned files are one scan
//      (HAADFscan.mrc 16 × 16, 4DSTEMscan.mrc 256 frames; HT 300000, dwell 0.01 and the same full-scan field of view
//      in both), yet they disagree. 4DSTEMscan.mrc's OLE value is 3600 s ahead of its UTC stamp (± 1 µs) on all 256
//      records (a local clock at UTC+1), but HAADFscan.mrc's OLE value, 2022-12-05 12:13:07, is that scan's UTC
//      time (0.347 s before the 4D file's UTC stamp): one of the two files writes the OLE value in UTC, and which
//      one is inference only. So the date digits are what the OLE field says and the note is `writerClockNote`
//      ("clock of the writer, zone not stored"), never `localTimeNote`. Showing the int64 UTC stamp where mask-4
//      bit 6 is set (the 4D file has it, HAADFscan.mrc does not) would settle the zone for those files and is an
//      owner decision, not made here;
//  (f) no value of the record is stored twice, so there is no `otherCopy` (the int64 "Acquisition time stamp" is the
//      same instant in UTC, not a second reading of the OLE one);
//  (g) the record holds one Magnification; it is read as the indicated one — the layout has no "actual".
//
//  MAPPING OF NAMES (no published reader maps these; mrcfile only reads the layout): HT → high tension; Camera
//  length → camera length; Dwell time → dwell; Timestamp → acquired; Microscope type → instrument; "Instrument
//  mode" → mode, the stored int32 as a decimal string (the record states an enumeration, no name; an unnamed
//  number is shown rather than a guessed name), labelled `unvalidatedNote`: mrcfile declares the field (int32 at
//  offset 244) and the harness compares the integer with it, but no pinned reader decodes or uses it; detector =
//  STEM Detector name, else Camera name, else Detector commercial name (FEI2). DEVIATION from the first sketch
//  (detector: STEM Detector name, else Camera name): the third source is needed because 4DSTEMscan.mrc names its
//  detector only there ("Ceta-S speed"). Exposure = "Integration time" (the layout has no field called exposure;
//  this is the camera field in seconds) — unvalidated and labelled so (`unvalidatedNote`): mrcfile declares the
//  field (f8 at offset 419, mask 2 bit 16) and the harness plants and compares it, but no pinned reader treats it
//  as an exposure and no real file records a positive value.
//
//  Real-file survey, 2026-10-12 (References/rosettasciio/rsciio/tests/data/mrc/): HAADFscan.mrc and 4DSTEMscan.mrc
//  are FEI2 (HAADFscan: NSYMBT 888 × 1024, i.e. not RosettaSciIO's 128 × 1024 — detect by EXTTYP, not by size);
//  the other eight .mrc there have NSYMBT 0 and no EXTTYP: nothing recorded.
//

import Foundation
import FormatoCore

extension AcquisitionMetadata {
    /// The FEI1/FEI2 record under the consumer's rules; empty when the file carries none. Throws `MRCError` when the
    /// header is not an MRC header.
    static func mrcApp(data: Data) throws -> AcquisitionMetadata {
        guard data.count >= 1024 else {
            throw MRCError.notMRC("\(data.count) bytes, shorter than an MRC header")
        }
        let header = [UInt8](data.prefix(1024))
        guard header[208..<212].elementsEqual(Array("MAP ".utf8)) else {
            throw MRCError.notMRC("no \"MAP \" id")
        }
        let stamp = Array(header[212..<216])
        let bigEndian: Bool
        switch (stamp[0], stamp[1]) {
        case (0x44, 0x44), (0x44, 0x41): bigEndian = false
        case (0x11, 0x11): bigEndian = true
        default: throw MRCError.byteOrder(stamp: stamp)
        }
        // NSYMBT, word 23 (bytes 92..<96), in the header's byte order.
        let extended = Int(Int32(bitPattern: FEIRecord.word(header, at: 92, bigEndian: bigEndian)))
        guard extended >= 0, extended <= data.count - 1024 else { throw MRCError.truncated }

        // Only the FEI1/FEI2 extended headers are read (mrcfile's two supported types); the size comes from the type.
        let exttyp = Array(header[104..<108])
        let recordSize: Int
        if exttyp.elementsEqual(Array("FEI1".utf8)) {
            recordSize = FEIRecord.fei1Size
        } else if exttyp.elementsEqual(Array("FEI2".utf8)) {
            recordSize = FEIRecord.fei2Size
        } else {
            return AcquisitionMetadata()
        }
        guard extended >= recordSize else { return AcquisitionMetadata() }
        let start = data.startIndex + 1024
        let record = FEIRecord(bytes: [UInt8](data[start ..< start + recordSize]), bigEndian: bigEndian)
        // mrcfile's own test that the extended header is that type: the record states its own size.
        guard record.int32(at: 0) == Int32(recordSize) else { return AcquisitionMetadata() }

        var result = AcquisitionMetadata()
        // RULE (b) is tested on the value as it is shown, after the unit conversion (the operation the reference
        // uses): a finite 5e-324 V is 0.0 kV and a finite 1e306 m is inf mm, and neither may be shown.
        if let kv = positive(record.double(FEIRecord.ht).map { $0 / 1e3 }) {
            result.highTensionKV = MetadataReading(kv)
        }
        if let magnification = positive(record.double(FEIRecord.magnification)) {
            result.magnification = MetadataReading(magnification)
        }
        // RULE (c), open deviation: shown as stored, the mode undecoded (header).
        if let mm = positive(record.double(FEIRecord.cameraLength).map { $0 * 1e3 }) {
            result.cameraLengthMM = MetadataReading(mm, note: FEIRecord.modeUncheckedNote)
        }
        if let name = [FEIRecord.stemDetectorName, FEIRecord.cameraName, FEIRecord.detectorCommercialName]
            .lazy.compactMap({ record.text($0) }).first {
            result.detector = MetadataReading(name)
        }
        if let us = positive(record.double(FEIRecord.dwellTime).map { $0 * 1e6 }) {
            result.dwellUS = MetadataReading(us)
        }
        if let integration = positive(record.double(FEIRecord.integrationTime)) {
            result.exposureS = MetadataReading(integration, note: FEIRecord.unvalidatedNote)
        }
        if let date = record.double(FEIRecord.timestamp).flatMap(FEIRecord.oleDate) {
            result.acquired = MetadataReading(date, note: writerClockNote)
        }
        if let instrument = record.text(FEIRecord.microscopeType) {
            result.instrument = MetadataReading(instrument)
        }
        if let mode = record.int32(FEIRecord.instrumentMode) {
            result.mode = MetadataReading(String(mode), note: FEIRecord.unvalidatedNote)
        }
        return result
    }
}

/// One FEI1/FEI2 extended-header record (mrcfile's layout) with bounds-checked reads: every accessor returns nil
/// for a field whose bit is clear or that lies outside the record, so a malformed file cannot trap.
nonisolated struct FEIRecord {
    static let fei1Size = 768
    static let fei2Size = 888
    /// The label of a value whose path no pinned reference reads (exposure, mode).
    static let unvalidatedNote = "unvalidated: no published reader reads it"
    /// RULE (c), open deviation: the label of a camera length shown without a mode test (Instrument mode and
    /// Projection mode are enumerations no published reader decodes).
    static let modeUncheckedNote = "unvalidated: the mode is not checked"

    /// A field: its byte offset in the record and the (mask, bit) that says it was written. Masks are 0...3 for
    /// Bitmask 1...4; their offsets are `maskOffsets`.
    struct Field {
        let offset: Int
        let mask: Int
        let bit: Int
    }
    static let maskOffsets = [8, 297, 490, 748]

    // mrcfile dtypes.py line in the comment; bits by the rule in the file header.
    static let timestamp = Field(offset: 12, mask: 0, bit: 0)                       // f8, 108
    static let microscopeType = Field(offset: 20, mask: 0, bit: 1)                  // S16, 109
    static let ht = Field(offset: 84, mask: 0, bit: 5)                              // f8, 113
    static let instrumentMode = Field(offset: 244, mask: 0, bit: 25)                // i4, 128
    static let magnification = Field(offset: 289, mask: 0, bit: 31)                 // f8, 134
    static let cameraLength = Field(offset: 301, mask: 1, bit: 0)                   // f8, 136
    static let integrationTime = Field(offset: 419, mask: 1, bit: 16)               // f8, 152
    static let cameraName = Field(offset: 435, mask: 1, bit: 19)                    // S16, 155
    static let stemDetectorName = Field(offset: 519, mask: 2, bit: 7)               // S16, 176
    static let dwellTime = Field(offset: 571, mask: 2, bit: 15)                     // f8, 184
    static let detectorCommercialName = Field(offset: 804, mask: 3, bit: 7)         // S16, 216 (FEI2 only)

    let bytes: [UInt8]
    let bigEndian: Bool

    /// A 32-bit word of `bytes` at `offset` in the given order; 0 when it does not fit (callers have checked).
    static func word(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[offset + (bigEndian ? i : 3 - i)]) }
        return v
    }

    /// True when the field's bit is set in its mask — the mask is always little-endian — and its whole extent
    /// `[offset, offset + width)` lies inside the record.
    private func isRecorded(_ field: Field, width: Int) -> Bool {
        guard field.offset >= 0, field.offset + width <= bytes.count else { return false }
        let at = Self.maskOffsets[field.mask]
        guard at + 4 <= bytes.count else { return false }
        return Self.word(bytes, at: at, bigEndian: false) >> UInt32(field.bit) & 1 == 1
    }

    /// The record's first int32 or any int32 at a plain offset (no bit): used for "Metadata size".
    func int32(at offset: Int) -> Int32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return Int32(bitPattern: Self.word(bytes, at: offset, bigEndian: bigEndian))
    }

    func int32(_ field: Field) -> Int32? {
        isRecorded(field, width: 4) ? int32(at: field.offset) : nil
    }

    func double(_ field: Field) -> Double? {
        guard isRecorded(field, width: 8) else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[field.offset + (bigEndian ? i : 7 - i)]) }
        return Double(bitPattern: v)
    }

    /// RULE (a): a 16-byte fixed-width text, cut at its first NUL, trimmed; nil when empty.
    func text(_ field: Field) -> String? {
        guard isRecorded(field, width: 16) else { return nil }
        let raw = bytes[field.offset ..< field.offset + 16].prefix { $0 != 0 }
        return AcquisitionMetadata.text(String(decoding: raw, as: UTF8.self))
    }

    /// RULE (e): an OLE automation date (days since 1899-12-30) as `YYYY-MM-DD HH:MM:SS`, or nil when it is not a
    /// usable date. The day fraction is rounded to a whole microsecond, half to even (what Python's
    /// `timedelta(days=x)` does — without it 44900.509108796294, which is 12:13:07 exactly, falls at 43986.9999998 s
    /// and reads :06), then the seconds are truncated.
    static func oleDate(_ days: Double) -> String? {
        guard days.isFinite, days > 0, days < 2_958_466 else { return nil }
        let microsPerDay = 86_400_000_000
        var wholeDays = Int(days.rounded(.down))
        var micros = Int(((days - Double(wholeDays)) * 86_400_000_000.0).rounded(.toNearestOrEven))
        if micros >= microsPerDay { wholeDays += 1; micros -= microsPerDay }
        // OLE day 25569 is 1970-01-01.
        let (year, month, day) = civil(daysSince1970: wholeDays - 25_569)
        guard year <= 9999 else { return nil }
        let seconds = micros / 1_000_000
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)) "
            + "\(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2))"
    }

    /// Civil date (proleptic Gregorian) of a day count from 1970-01-01 — H. Hinnant's `civil_from_days`, integer
    /// only, so no time zone or calendar object can enter.
    private static func civil(daysSince1970: Int) -> (year: Int, month: Int, day: Int) {
        let z = daysSince1970 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

extension AcquisitionMetadata {
    /// The acquisition values an MRC file records: see the conventions above. Throws `MRCError` for bytes that are not
    /// an MRC header.
    public static func mrc(data: Data, convention: AcquisitionMetadataConvention = .rosettaSciIO) throws -> AcquisitionMetadata {
        switch convention {
        case .app: return try mrcApp(data: data)
        case .rosettaSciIO: return try mrcReference(data: data)
        }
    }

    /// The file at `path`, memory-mapped.
    public static func mrc(path: String, convention: AcquisitionMetadataConvention = .rosettaSciIO) throws -> AcquisitionMetadata {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), error.localizedDescription)
        }
        return try mrc(data: data, convention: convention)
    }

    private static func mrcReference(data: Data) throws -> AcquisitionMetadata {
        guard data.count >= 1024 else {
            throw MRCError.notMRC("\(data.count) bytes, shorter than an MRC header")
        }
        var out = AcquisitionMetadata()
        let next = Int(FEIRecord.word([UInt8](data.prefix(1024)), at: 92, bigEndian: false))
        // `std_header["NEXT"] / 1024 == 128`, and the 1024 records must fit (else `f.tell()` differs and the header is dropped).
        guard next == 128 * 1024, data.count >= 1024 + next else { return out }
        let start = data.startIndex + 1024
        let record = [UInt8](data[start ..< start + 128])
        func float(at offset: Int) -> Double { Double(Float(bitPattern: FEIRecord.word(record, at: offset, bigEndian: false))) }
        // `fei_header` a_tilt, b_tilt, x_stage, y_stage, z_stage (offsets 0 ... 16, float32; mapping :711-716): as stored, no conversion.
        let stored = "as stored in the FEI header (float32), no conversion"
        out.stageTiltAlphaDeg = MetadataReading(float(at: 0), note: stored)
        out.stageTiltBetaDeg = MetadataReading(float(at: 4), note: stored)
        out.stageX = MetadataReading(float(at: 8), note: stored)
        out.stageY = MetadataReading(float(at: 12), note: stored)
        out.stageZ = MetadataReading(float(at: 16), note: stored)
        out.exposureS = MetadataReading(float(at: 32))
        out.magnification = MetadataReading(float(at: 48))
        return out
    }
}
