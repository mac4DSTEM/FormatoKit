//
//  AcquisitionMetadataTIFF.swift
//  Role: the acquisition values a TIFF records, as `AcquisitionMetadata`: the Velox XML of tag 34683 (Thermo/FEI TEM,
//        Ceta) and the FEI SEM INI of tags 34680/34682 (Helios, SFEG).  The container is `TIFFFile`; no
//        pixel is read here, so a metadata reading can never move a pixel or a calibration.
//
//  CONVENTIONS (`AcquisitionMetadataConvention`). Everything below describes `.app`. `.rosettaSciIO` (default) differs:
//  - FEI SEM INI: RosettaSciIO 049e7d70 `tiff/_api.py` `mapping_fei` (:1130-1159) over the kit's tifffile-exact
//    `fei_metadata` sections: `Beam.HV` * 1e-3 kV (float() or nothing), `Scan.Dwelltime` as stored (seconds, shown in
//    microseconds), `System.SystemType` as the instrument, `User.Date` + `User.Time` (dateutil, the layouts the kit
//    ports) joined into one stamp; no positivity rule (a stored 0 is 0), values as tifffile's `astype` makes them;
//  - Velox XML: the same schema's EMD mapping (`emd/_emd_velox.py` `_get_mapping`, :934-948): `Optics.AccelerationVoltage`
//    / 1e3 and `Optics.CameraLength` * 1e3 with NO mode gate and no positivity rule; every other value is read by the
//    consumer's rule and keeps its `unvalidatedNote`;
//  - the DM tag stream (tag 65027) goes through `AcquisitionMetadata.dm` with the same convention.
//
//  WHAT IS READ, first directory only, in the order FEI SEM, Velox, DM (the first two are the order
//  the TIFF calibration code tries them in). A TIFF with none of the three conventions — an ImageJ file, a plain
//  one, a DM export whose block is not a DM tag stream — reads EMPTY here. The standard TIFF tags (272 Model,
//  305 Software, 306 DateTime) describe the file's writer, not the acquisition, so they are not read. A non-TIFF
//  throws what `TIFFFile` throws.
//
//  THE DM TAG TREE, tag 65027. A TIFF saved by Digital Micrograph holds in private tag 65027
//  (type 1, BYTE; tifffile labels it JEOL_Header, a guess) a complete DM4 byte stream whose root group IS the image's
//  ImageTags (RosettaSciIO's test_loading_image_saved_with_DM.tif: 10585 bytes, 200 kV, 51×, a 0.5 s exposure). It is
//  read ONLY when none of 34680, 34682 and 34683 exists (FEI SEM, then Velox, then DM: a file that carries an FEI or
//  Velox convention is read as that, whatever else it carries), the tag is type 1, its bytes lie inside the file and
//  number at most `maxDMTagStream`, and the kit's tag walker (`DM4Experiment.tagTree(data:)`, the one DM parser here)
//  accepts them; the two maps it returns go through the same rules as a .dm3/.dm4 image object
//  (`AcquisitionMetadata.dm(numbers:strings:)`: its keys are relative to the stream's root, as that function wants).
//  A block the walker refuses, a tag of another type or one over the cap reads EMPTY, never throws. A 34683 that exists
//  but is not text also reads empty: the DM tree is not tried behind a Velox tag.
//
//  VELOX (an XML document; XPath under <Metadata>; loaded by `GuardedXML`, the one loader the Velox calibration uses too, which refuses a document that nests too deep, runs on too long or declares an entity: such a tag reads as no
//  tag). The element names and values below were read off the owner's six Ceta TIFFs (Talos F200X, 2026-06-05) with
//  tifffile; a string value of more than 256 characters reads as absent (`GuardedXML.bounded`):
//    highTensionKV   Optics/AccelerationVoltage, V → kV (/1e3).
//    magnification   Optics/NominalMagnification (rule g: the indicated one; the file stores no calibrated one).
//    cameraLengthMM  Optics/CameraLength, m → mm (×1e3), ONLY where the mode makes it real (rule c): ProjectorMode
//                    "Diffraction" or OperatingMode "STEM". All six files say OperatingMode "TEM", ProjectorMode
//                    "Imaging" and still store a CameraLength (0.844 / 1.365 m): a stale setting, so nil here. The
//                    two mode values that open the gate are a design choice; no file here holds one.
//    detector        BinaryResult/Detector.
//    exposureS       ExposureTime (s) of the Detectors/* element whose DetectorName is BinaryResult/Detector, never
//                    another detector's (the Ceta files list nine detectors; only the imaging one has an exposure).
//    dwellUS         never read: these files store ScanSettings/FrameTime (36.9 s, 0.78 s), a frame time, not a dwell,
//                    and no Velox STEM TIFF exists here to show where a dwell would sit.
//    acquired        Acquisition/AcquisitionStartDatetime, ISO local time with no zone → "YYYY-MM-DD HH:MM:SS" (rule e).
//                    The second stored stamp, Acquisition/AcquisitionDatetime, is kept as `otherCopy` when it names a
//                    different second (rule f); equal on all six files. A second stamp whose year is before 1990 is an
//                    unset field, not a copy, and reads nil (below). A stamp with a zone designator ("Z", "+02:00"),
//                    the second stamp included, is a different quantity from the one registered ("local, zone not
//                    stored") and reads nil. No fallback to AcquisitionDatetime when the start is absent: that is
//                    another stamp, not a copy.
//    instrument      Instrument/InstrumentModel ("Talos F200X"; not InstrumentClass).
//    mode            Optics/OperatingMode as stored ("TEM"), the registered path. The
//                    projector mode is read only to decide rule (c); it is not part of the mode shown.
//  Which Velox paths a published reader maps: RosettaSciIO 049e7d70 rsciio/emd/_emd_velox.py maps
//  Optics.AccelerationVoltage (lines 938–941, / 1e3) and Optics.CameraLength (942–945, × 1e3, in no mode gate): those
//  two carry no `TIFFNote.unvalidated`, every other value does — the same schema, no reader. In particular the date:
//  the reference reads Acquisition.AcquisitionStartDatetime.DateTime (902–903, 916–918, 934–937), the EMD's unix-time
//  sub-key shown in the VIEWER's zone and mapped to General.time_zone; the TIFF's XML text of that element is ISO
//  local text with no DateTime child (measured on the six Ceta files), a path no published reader reads. (It also
//  maps Instrument.InstrumentClass and a boolean StemMagnification, and takes the detector name from
//  Detectors/*/DetectorName by DetectorIndex (326–330, 528–533), none of which is a path read here.)
//
//  THE UNSET SECOND STAMP. In RosettaSciIO's Velox EMDs (the same XML schema, namespace …/Metadata/v1/2013/07) an
//  unset Acquisition.AcquisitionDatetime is stored as unix 0: eight STEM files that carry a start stamp have it, three
//  more files that carry none have it too, and fei_emd_spectrum.emd, whose second stamp is a real one 11 s after the
//  start, shows that a genuine differing stamp must stay (read 2026-10-12). How a TIFF's XML writes the unset field is
//  INFERRED from those files: no Velox STEM TIFF has been seen, and the six Ceta files have two equal stamps. Written
//  as local ISO text, unix 0 would read 1970-01-01 plus the writer's zone offset and a zeroed date year 1, so the floor
//  is the YEAR, 1990: the Velox schema postdates 1990, so an earlier second stamp is no acquisition. Only the second
//  stamp is floored; the EMD files omit an unset start instead of writing 0.
//
//  FEI SEM (an INI text; tags 34680 then 34682, a later section replacing an earlier — tifffile's `fei_metadata`).
//  The reading is a port of tifffile 2026.9.20 `read_fei_metadata` over `bytes2str`, to the code point: the tag's bytes
//  up to the first NUL, UTF-8 or else cp1252 (a tag with one of cp1252's five undefined bytes is skipped, as tifffile
//  raises there), lines split where Python's `str.splitlines` splits (including U+001C–U+001E, U+0085, U+2028,
//  U+2029), trimmed as Python's `str.strip` trims, `[name]` starting a new section (a repeated name replaces the
//  earlier), the first "=" splitting key from value, a line without one skipped, a LATER REPEATED KEY REPLACING THE
//  EARLIER EVEN WHEN ITS VALUE IS EMPTY (`HV=5000` then `HV=` reads HV as empty, i.e. not recorded).
//    highTensionKV   [Beam] HV, V → kV.            dwellUS     [Scan] Dwelltime, s → µs (×1e6).
//    acquired        [User] Date "MM/DD/YYYY" + [User] Time "hh:mm:ss AM|PM" (rule e).
//    detector        [Detectors] Name.             instrument  [System] SystemType (kept as stored: the Helios string
//                                                              holds a literal quote, `Helios NanoLab" 660`).
//  Never read: magnification — the INI stores none ([Image] MagCanvasRealWidth is the display canvas's width in
//  metres and [EBeam] HFW a field width; a ratio of them would be derived, not stored; MagnificationMode is a code);
//  camera length, exposure and mode (no such key: [Scan] FrameTime is a frame time, [Detectors] Mode is the signal);
//  [PrivateFei] TimeOfCreation (a second stamp, dd.mm.yyyy hh:mm:ss, not a registered path).
//  RosettaSciIO 049e7d70 rsciio/tiff/_api.py `mapping_fei` (lines 1130–1159) maps Beam.HV (× 1e-3 via
//  `_parse_beam_energy_FEI`, lines 1081–1085: float() or None), Scan.Dwelltime (as is), User.Date and User.Time
//  (dateutil) and System.SystemType; it does not map [Detectors] Name, so the detector carries `TIFFNote.unvalidated`.
//  DEVIATION: HV is divided by 1e3 here, multiplied by 1e-3 there — the same number to within one ulp.
//  DEVIATION: a stored 0 (HV or Dwelltime) is 0.0 there and "not recorded" here (rule b).
//  DEVIATION: the dwell is stated in µs here, seconds there (the registered unit).
//  DEVIATION: dateutil parses any date shape and silently picks an order; only "a/b/yyyy" and "h:mm:ss [AM|PM]" (or a
//  24-hour clock) are read here and anything else is nil. The order is month-first, as the FEI INI date is by format
//  and as dateutil's default reads it (the registered format), so no note says it was assumed; a first field above 12
//  can only be a day, as dateutil reads it. The date carries only "local time, zone not stored".
//  DEVIATION: an INI tag is read only when its TIFF type is ASCII or UNDEFINED (the gate the calibration
//  applies to the same tag); tifffile reads the same bytes whatever the type, so a BYTE-typed tag reads there.
//  DEVIATION: a number is read by `AcquisitionMetadata.number` — ASCII digits, a sign, a point, an exponent — where
//  tifffile's `astype` and the reference's `float()` also read "5_000" and non-ASCII decimal digits: those read as not
//  recorded here.
//  DEVIATION: tifffile's `astype` turns a value that looks like a number into a number and keeps the rest as text; the
//  text values read here (detector, instrument) stay text, so "007" is "007" here and 7 there.
//
//  RULES applied are named by their letter (AcquisitionMetadata.swift): (a) every read goes through `text`/`number`,
//  (b) every quantity through `positive`, applied to the number AS SHOWN, i.e. after its unit conversion (a stored
//  5e-324 V is 0.0 kV and a stored 1e306 m or s is inf mm or µs: not recorded; as `AcquisitionMetadata+MRC.swift`
//  does), (c) the camera length gate, (e) the date, (f) the second stamp, (g) the magnification path. Every read is
//  bounds-checked and falls to nil: a malformed file never traps.
//

import Foundation
import FormatoCore
import FormatoDM

nonisolated extension AcquisitionMetadata {
    /// The notes this reader attaches, worded once. Private: the other readers word their own, and the tests pin
    /// the texts as literals.
    private enum TIFFNote {
        static let unvalidated = "unvalidated: no published reader reads it"
    }

    /// The acquisition values a TIFF records; an empty `AcquisitionMetadata` when it records none. Throws only
    /// what `TIFFFile` throws for a file that is not a readable TIFF.
    public static func tiff(data: Data, convention: AcquisitionMetadataConvention = .rosettaSciIO) throws -> AcquisitionMetadata {
        let file = try TIFFFile(data: data)
        guard let page = file.directories.first else { return AcquisitionMetadata() }
        return tiff(page: page, convention: convention)
    }

    /// The file at `path`, memory-mapped.
    public static func tiff(path: String, convention: AcquisitionMetadataConvention = .rosettaSciIO) throws -> AcquisitionMetadata {
        let file = try TIFFFile(path: path)
        guard let page = file.directories.first else { return AcquisitionMetadata() }
        return tiff(page: page, convention: convention)
    }

    /// First directory, in the order FEI SEM, Velox, DM.
    static func tiff(page: TIFFDirectory, convention: AcquisitionMetadataConvention) -> AcquisitionMetadata {
        if page[34680] != nil || page[34682] != nil {
            if convention == .rosettaSciIO { return feiReference(page) }
            var sections: [String: [String: String]] = [:]
            for tag in [34680, 34682] {
                if let ini = iniText(page[tag]) { sections.merge(feiSections(ini)) { _, later in later } }
            }
            return fei(sections)
        }
        if let xml = xmlText(page[34683]) { return velox(xml, convention: convention) }
        if page[34683] == nil, let stream = dmTagStream(page[65027]),
           let tree = try? DM4Experiment.tagTree(data: stream) {
            return dm(numbers: tree.numbers, strings: tree.strings, convention: convention)
        }
        return AcquisitionMetadata()
    }

    /// The FEI SEM INI under `.rosettaSciIO`: `mapping_fei` over the kit's `fei_metadata` sections.
    private static func feiReference(_ page: TIFFDirectory) -> AcquisitionMetadata {
        let sections = TIFFSignals.feiMetadata(page)
        var out = AcquisitionMetadata()
        if let hv = sections["Beam"]?["HV"]?.asFloat { out.highTensionKV = MetadataReading(hv * 1e-3) }
        if let dwell = sections["Scan"]?["Dwelltime"]?.numberValue { out.dwellUS = MetadataReading(dwell * 1e6) }
        if case .string(let date)? = sections["User"]?["Date"], case .string(let time)? = sections["User"]?["Time"] {
            // dateutil: the kit's port of the layouts it reads (month first, or ISO), else this file's day-first-above-12 reading.
            if let d = TIFFSignals.feiDate(date), let t = TIFFSignals.feiTime(time) {
                out.acquired = MetadataReading(d + " " + t, note: localTimeNote)
            } else if let shown = feiDate(date: text(date), time: text(time)) {
                out.acquired = MetadataReading(shown, note: localTimeNote)
            }
        }
        if let type = sections["System"]?["SystemType"] { out.instrument = MetadataReading(pythonText(type)) }
        // The 0.3.1 fields (`mapping_fei` :1135-1158): the SEM stage as tifffile's `astype` made it, the working distance
        // (m to mm) and beam current (A to nA) through `float()`, and the user.
        if let x = sections["Stage"]?["StageX"]?.numberValue { out.stageX = MetadataReading(x, note: feiStored) }
        if let y = sections["Stage"]?["StageY"]?.numberValue { out.stageY = MetadataReading(y, note: feiStored) }
        if let z = sections["Stage"]?["StageZ"]?.numberValue { out.stageZ = MetadataReading(z, note: feiStored) }
        if let r = sections["Stage"]?["StageR"]?.numberValue { out.stageRotationDeg = MetadataReading(r, note: feiStored) }
        if let t = sections["Stage"]?["StageT"]?.numberValue {
            out.stageTiltAlphaDeg = MetadataReading(t, note: "the SEM stage's single tilt; " + feiStored)
        }
        if let wd = sections["Stage"]?["WorkingDistance"]?.asFloat { out.workingDistanceMM = MetadataReading(wd * 1e3) }
        if let current = sections["EBeam"]?["BeamCurrent"]?.asFloat { out.beamCurrentNA = MetadataReading(current * 1e9) }
        if case .string(let user)? = sections["User"]?["User"] { out.operatorName = MetadataReading(user) }
        if case .string(let name)? = sections["Detectors"]?["Name"], let name = text(name) {
            out.detector = MetadataReading(name, note: unvalidatedNote)
        }
        return out
    }

    private static let feiStored = "as stored in the INI, no conversion"

    /// `str(value)` of a value tifffile's `astype` made.
    private static func pythonText(_ value: FormatoPythonValue) -> String {
        switch value {
        case .int(let i): String(i)
        case .float(let d): String(d)
        case .bool(let b): b ? "True" : "False"
        case .string(let s): s
        }
    }

    /// An ASCII or UNDEFINED entry as UTF-8 text, trailing NULs dropped.
    private static func xmlText(_ tag: TIFFTag?) -> String? {
        guard let tag, tag.type == 2 || tag.type == 7 else { return nil }
        return String(decoding: tag.raw.reversed().drop(while: { $0 == 0 }).reversed(), as: UTF8.self)
    }

    // MARK: - DM tag tree (tag 65027)

    /// The longest tag 65027 block read: 16 MiB. The real block is 10 KB; a larger one is no tag tree of an image's
    /// ImageTags (it would hold pixels or an unbounded array), and reading it would copy and walk that much.
    private static let maxDMTagStream = 1 << 24

    /// The bytes of tag 65027, or nil unless it is a BYTE (type 1) entry of 1 ... `maxDMTagStream` bytes.
    private static func dmTagStream(_ tag: TIFFTag?) -> Data? {
        guard let tag, tag.type == 1, tag.count >= 1, tag.count <= maxDMTagStream, tag.raw.count == tag.count else { return nil }
        return tag.raw
    }

    // MARK: - Velox

    private static func velox(_ xml: String, convention: AcquisitionMetadataConvention) -> AcquisitionMetadata {
        var out = AcquisitionMetadata()
        // GuardedXML refuses a document that nests deeper, runs on longer or declares any entity (a refused tag reads as
        // no tag) and never opens an external one: with XMLDocument's default options a DOCTYPE that names a local file
        // puts that file's text into the element (measured: <!ENTITY x SYSTEM "file://…"> read back as the file).
        guard let document = GuardedXML.document(xml) else { return out }

        // The trimmed text of the first element at a fixed path under <Metadata> (rule a), absent when over 256
        // characters. The XPath is always one of this function's own literals, never built from file text.
        func stored(_ path: String) -> String? {
            GuardedXML.bounded(text((try? document.nodes(forXPath: "/Metadata/" + path))?.first?.stringValue))
        }
        func child(_ element: XMLElement, _ name: String) -> String? {
            GuardedXML.bounded(text(element.elements(forName: name).first?.stringValue))
        }
        // A reading with the notes that apply: its own, then "unvalidated" unless a published reader maps its path.
        let readByReference: Set<String> = ["Optics/AccelerationVoltage", "Optics/CameraLength", "Instrument/InstrumentClass", "Stage/AlphaTilt",
                                            "Stage/BetaTilt", "Stage/Position/x", "Stage/Position/y", "Stage/Position/z"]
        func reading<V: Sendable & Equatable>(_ value: V, _ path: String, note: String? = nil,
                                              otherCopy: V? = nil) -> MetadataReading<V> {
            MetadataReading(value, note: joined(note, readByReference.contains(path) ? nil : TIFFNote.unvalidated),
                            otherCopy: otherCopy)
        }

        // Rule (b) is applied to the number as shown, after the unit conversion: a stored 5e-324 V is 0.0 kV, which is
        // "not recorded", and a stored 1e306 m would be inf mm.
        let referenceRules = convention == .rosettaSciIO
        // `.rosettaSciIO`: the EMD mapping's float(x) / 1e3 and float(x) * 1e3 keep a stored zero.
        if let kv = number(stored("Optics/AccelerationVoltage")).map({ $0 / 1e3 }), referenceRules || kv.isFinite && kv > 0 {
            out.highTensionKV = reading(kv, "Optics/AccelerationVoltage")
        }
        if let nominal = positive(number(stored("Optics/NominalMagnification"))) {
            out.magnification = reading(nominal, "Optics/NominalMagnification")
        }

        // Rule (c): the camera length is real only in a diffraction projector mode or the STEM operating mode.
        // DEVIATION: RosettaSciIO 049e7d70 emd/_emd_velox.py:942–945 maps Optics.CameraLength in every mode (no published
        // reader reads the TIFF tag; the EMD mapping is the reference for the schema); here only in a diffraction projector
        // mode or STEM. The six Ceta files (OperatingMode TEM, ProjectorMode Imaging) store a CameraLength and read nil.
        let operating = stored("Optics/OperatingMode"), projector = stored("Optics/ProjectorMode")
        let diffraction = projector?.caseInsensitiveCompare("Diffraction") == .orderedSame
        let stem = operating?.caseInsensitiveCompare("STEM") == .orderedSame
        if referenceRules || diffraction || stem, let mm = number(stored("Optics/CameraLength")).map({ $0 * 1e3 }),
           referenceRules || mm.isFinite && mm > 0 {
            out.cameraLengthMM = reading(mm, "Optics/CameraLength")
        }
        if let operating { out.mode = reading(operating, "Optics/OperatingMode") }

        // The detector the image came from, and that detector's exposure: the Detectors/* element whose DetectorName
        // is BinaryResult/Detector (RosettaSciIO's own lookup, `_get_detector_metadata_dict`, matches by name too).
        // Its children are walked as elements, so no file text ever enters an XPath.
        let detector = stored("BinaryResult/Detector")
        if let detector {
            out.detector = reading(detector, "BinaryResult/Detector")
            let listed = (try? document.nodes(forXPath: "/Metadata/Detectors/*")) ?? []
            for case let element as XMLElement in listed {
                guard child(element, "DetectorName") == detector, let seconds = positive(number(child(element, "ExposureTime")))
                else { continue }
                out.exposureS = reading(seconds, "Detectors/*/ExposureTime")
                break
            }
        }

        // Rule (e), and rule (f) against the second stored stamp. Equality is on the shown text (whole seconds). A second
        // stamp before 1990 is an unset field (see THE UNSET SECOND STAMP above: the Velox schema postdates 1990, and the
        // unset form is inferred from same-schema EMD files, not seen in a TIFF), so it is no copy.
        if let start = isoLocal(stored("Acquisition/AcquisitionStartDatetime")) {
            var second = isoLocal(stored("Acquisition/AcquisitionDatetime"))
            if let year = second.flatMap({ Int($0.prefix(4)) }), year < 1990 { second = nil }
            out.acquired = reading(start, "Acquisition/AcquisitionStartDatetime", note: localTimeNote,
                                   otherCopy: second == start ? nil : second)
        }
        let model = stored("Instrument/InstrumentModel")
        if referenceRules {
            // The EMD mapping's microscope is `Instrument.InstrumentClass`; the stored model is kept beside it (0.3.1).
            if let cls = stored("Instrument/InstrumentClass") { out.instrument = reading(cls, "Instrument/InstrumentClass") }
            if let model { out.instrumentModel = reading(model, "Instrument/InstrumentModel") }
            // The EMD mapping's stage (`_emd_velox.py:951-972`): radians to degrees rounded to 3 decimals; metres rounded to 6.
            let degrees = "degrees from the stored radians, rounded to 3 decimals, as RosettaSciIO"
            if let a = number(stored("Stage/AlphaTilt")) {
                out.stageTiltAlphaDeg = reading(pythonRound(numpyDegrees(a), 3), "Stage/AlphaTilt", note: degrees)
            }
            if let b = number(stored("Stage/BetaTilt")) {
                out.stageTiltBetaDeg = reading(pythonRound(numpyDegrees(b), 3), "Stage/BetaTilt", note: degrees)
            }
            let metres = "metres as stored, rounded to 6 decimals, as RosettaSciIO"
            if let x = number(stored("Stage/Position/x")) { out.stageX = reading(pythonRound(x, 6), "Stage/Position/x", note: metres) }
            if let y = number(stored("Stage/Position/y")) { out.stageY = reading(pythonRound(y, 6), "Stage/Position/y", note: metres) }
            if let z = number(stored("Stage/Position/z")) { out.stageZ = reading(pythonRound(z, 6), "Stage/Position/z", note: metres) }
        } else if let model {
            out.instrument = reading(model, "Instrument/InstrumentModel")
        }
        return out
    }

    // MARK: - FEI SEM

    private static func fei(_ sections: [String: [String: String]]) -> AcquisitionMetadata {
        var out = AcquisitionMetadata()
        func stored(_ section: String, _ key: String) -> String? { text(sections[section]?[key]) }
        // "unvalidated" unless mapping_fei maps the path (Beam.HV, Scan.Dwelltime, User.Date/Time, System.SystemType).
        func reading<V: Sendable & Equatable>(_ value: V, mapped: Bool, note: String? = nil) -> MetadataReading<V> {
            MetadataReading(value, note: joined(note, mapped ? nil : TIFFNote.unvalidated))
        }

        // Rule (b) after the unit conversion, as for the Velox values: a stored 5e-324 V is 0.0 kV, a stored 1e306 s is
        // inf µs: neither is shown.
        if let kv = positive(number(stored("Beam", "HV")).map { $0 / 1e3 }) {
            out.highTensionKV = reading(kv, mapped: true)
        }
        if let us = positive(number(stored("Scan", "Dwelltime")).map { $0 * 1e6 }) {
            out.dwellUS = reading(us, mapped: true)
        }
        if let shown = feiDate(date: stored("User", "Date"), time: stored("User", "Time")) {
            out.acquired = reading(shown, mapped: true, note: localTimeNote)
        }
        if let name = stored("Detectors", "Name") { out.detector = reading(name, mapped: false) }
        if let type = stored("System", "SystemType") { out.instrument = reading(type, mapped: true) }
        return out
    }

    /// The text of one FEI INI tag as tifffile's `bytes2str` decodes it: the bytes up to the first NUL, as UTF-8 or
    /// else as cp1252. nil when the entry is not text, or holds one of cp1252's five undefined bytes (0x81, 0x8D, 0x8F,
    /// 0x90, 0x9D): tifffile raises there and `fei_metadata` has no sections for the tag.
    private static func iniText(_ tag: TIFFTag?) -> String? {
        guard let tag, tag.type == 2 || tag.type == 7 else { return nil }
        var bytes = tag.raw[...]
        if let nul = bytes.firstIndex(of: 0) { bytes = bytes[..<nul] }
        return String(validating: bytes, as: UTF8.self) ?? String(data: Data(bytes), encoding: .windowsCP1252)
    }

    /// One FEI INI text as tifffile's `read_fei_metadata` reads it, by Unicode scalar as Python reads by code point:
    /// lines as `str.splitlines` splits them and `str.strip` trims them, `[name]` starts a new, empty section (a
    /// repeated name replaces the earlier one), the first "=" splits key from value (both trimmed), a line without one
    /// is skipped, and a line "Key=" stores the empty string, replacing an earlier value of the key.
    private static func feiSections(_ ini: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in ini.unicodeScalars.split(whereSeparator: isPythonLineBreak) {
            let line = trimmed(raw)
            if line.first == "[" {
                let name = String(String.UnicodeScalarView(line.dropFirst().dropLast()))
                current = name
                sections[name] = [:]
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = String(String.UnicodeScalarView(trimmed(line[..<equals])))
            let value = String(String.UnicodeScalarView(trimmed(line[line.index(after: equals)...])))
            sections[current]?[key] = value
        }
        return sections
    }

    /// Python's `str.splitlines` boundaries (\r\n is two of them: the empty line between reads as no line).
    private static func isPythonLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// Python's `str.isspace`.
    private static func isPythonSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// `str.strip()`: the scalars without the Python whitespace at either end.
    private static func trimmed(_ scalars: Substring.UnicodeScalarView) -> Substring.UnicodeScalarView {
        var view = scalars
        while let first = view.first, isPythonSpace(first) { view = view.dropFirst() }
        while let last = view.last, isPythonSpace(last) { view = view.dropLast() }
        return view
    }

    // MARK: - Dates (rule e)

    /// "YYYY-MM-DDTHH:MM:SS[.fff]" (a space may stand for the T) → "YYYY-MM-DD HH:MM:SS"; nil for anything else,
    /// a zone designator and an impossible date included.
    private static func isoLocal(_ s: String?) -> String? {
        guard let s, let split = s.firstIndex(where: { $0 == "T" || $0 == " " }) else { return nil }
        let ymd = s[..<split].split(separator: "-", omittingEmptySubsequences: false)
        let rest = s[s.index(after: split)...].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let hms = (rest.first ?? "").split(separator: ":", omittingEmptySubsequences: false)
        guard ymd.count == 3, hms.count == 3, rest.count == 1 || digits(rest[1], length: 1...9) != nil,
              let year = digits(ymd[0], length: 4...4), let month = digits(ymd[1], length: 2...2),
              let day = digits(ymd[2], length: 2...2), let hour = digits(hms[0], length: 2...2),
              let minute = digits(hms[1], length: 2...2), let second = digits(hms[2], length: 2...2)
        else { return nil }
        return stamp(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// FEI [User] Date + Time → the shown stamp. The registered date is month first, as the FEI INI is by format; a
    /// first field above 12 can only be a day, as dateutil reads it. The time is 12-hour with AM or PM (12 AM is hour 0,
    /// 12 PM hour 12) or, without a suffix, a 24-hour clock.
    private static func feiDate(date: String?, time: String?) -> String? {
        guard let date, let time else { return nil }
        let fields = date.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 3, let first = digits(fields[0], length: 1...2),
              let second = digits(fields[1], length: 1...2), let year = digits(fields[2], length: 4...4) else { return nil }
        let (month, day) = first > 12 ? (second, first) : (first, second)

        let pieces = time.split(whereSeparator: \.isWhitespace)
        guard pieces.count == 1 || pieces.count == 2 else { return nil }
        let clock = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3, var hour = digits(clock[0], length: 1...2),
              let minute = digits(clock[1], length: 2...2), let seconds = digits(clock[2], length: 2...2) else { return nil }
        if pieces.count == 2 {
            let afternoon: Bool
            switch pieces[1].uppercased() {
            case "AM": afternoon = false
            case "PM": afternoon = true
            default: return nil
            }
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (afternoon ? 12 : 0)
        }
        return stamp(year: year, month: month, day: day, hour: hour, minute: minute, second: seconds)
    }

    /// `YYYY-MM-DD HH:MM:SS`, or nil for a date or a time that does not exist.
    private static func stamp(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> String? {
        guard (1...9999).contains(year), (1...12).contains(month), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthLength = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...monthLength).contains(day) else { return nil }
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)) \(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
    }

    /// An unsigned decimal of exactly the given digit count, or nil ("+5", " 5", "٣" and "5Z" are not digits).
    private static func digits(_ s: Substring, length: ClosedRange<Int>) -> Int? {
        guard length.contains(s.utf8.count), s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(s)
    }

    /// The notes of one reading, in a fixed order, joined with "; "; nil when none.
    private static func joined(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: "; ")
    }
}
