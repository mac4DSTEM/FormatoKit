//
//  AcquisitionMetadataDM.swift
//  The Digital Micrograph (DM3/DM4) reader of `AcquisitionMetadata`: a pure function over one image object's ImageTags
//  (`DM4ImageObject.imageTagNumbers` / `imageTagStrings`, keys relative to `ImageList.N.ImageTags.`; a TIFF tag 65027
//  stream's keys are the same). Two conventions (`AcquisitionMetadataConvention`):
//
//  `.rosettaSciIO` (default) is RosettaSciIO 049e7d70 `digitalmicrograph/_api.py` `get_mapping` (:887-1253) applied to
//  an image signal, the way HyperSpy applies a returned mapping (a source path is slugified: spaces to underscores,
//  parentheses dropped; a mapped value is stored when its tag exists):
//   - a stack-builder image (any `source.Tags at creation.` tag) is read from that copy INSTEAD of the direct tags;
//   - high tension = `Microscope Info.Voltage` / 1e3, no positivity rule;
//   - with a `Microscope Info` group: `Illumination Mode` == "TEM" with `Imaging Mode` == "DIFFRACTION" maps
//     `Indicated Magnification` to the camera length, TEM otherwise to the magnification; any other illumination mode
//     (STEM, SEM, none) maps `STEM Camera Length` to the camera length and `Indicated Magnification` to the magnification;
//   - the instrument is the first of `Session Info.Microscope`, `Microscope Info.Name`, `Microscope Info.Microscope`
//     that is not empty and not "[]", untrimmed, only inside that group;
//   - the mode is `Illumination Mode` reduced to "STEM" (contains STEM), "SEM" (contains SEM) or "TEM";
//   - the dwell is `DigiScan.Sample Time` (stored in microseconds, RosettaSciIO divides by 1e6) when the image has a
//     DigiScan group; the exposure is `Acquisition.Parameters.Detector.exposure (s)` only when it has none;
//   - the date and time are `DataBar.Acquisition Date` and `Time`, joined here into one stamp (RosettaSciIO keeps them
//     apart); dateutil parses any layout and guesses, so only the layouts below are read and the rest are nil.
//   Also read (0.3.1): the stage (`Stage Alpha`/`Beta` as stored, `Stage X`/`Y`/`Z` ×1e-3), `Probe Current (nA)`, `Session Info.
//   Operator`, and for an EELS signal (`Meta Data.Signal` "EELS", or Orsay's `spim.eels` group, read on the direct tags) the collection and
//   convergence semi-angles. The dwell and exposure follow the signal type as RosettaSciIO's chain does (EELS: its acquisition time as
//   the dwell with DigiScan tags, else the exposure; X-ray: neither; CL: the DigiScan sample time). The EELS frame number,
//   aperture and spectrometer, and the EDS and CL groups, stay unread.
//   Fields RosettaSciIO does not map (the detector) are read by the consumer's rule with `unvalidatedNote`. The
//   signal-type specific mappings (EELS, EDS, CL, SI) are not applied: this reads an image object.
//
//  `.app` is the consumer's rule set (AcquisitionMetadata.swift, rules a to g), pinned to its source:
//  - high tension `Microscope Info.Voltage` V -> kV; magnification `Indicated Magnification` (never "Actual"), not
//    given in TEM diffraction, where the tag holds the camera length; camera length only for an illumination mode
//    starting "STEM" (`STEM Camera Length`) or TEM diffraction (`Indicated Magnification`), "mm (assumed)";
//  - detector `Acquisition.Device.Name`; dwell `DigiScan.Sample Time` in us; exposure `Acquisition.Parameters.Detector.
//    exposure (s)` with `DataBar.Exposure Time (s)` as its second copy; date from `DataBar` as below; the mode is both
//    stored mode strings joined by " . "; the instrument as RosettaSciIO's order with each text trimmed first;
//  - every key is read directly first, then under `source.Tags at creation.` only when the direct key is ABSENT;
//    a key present but empty, zero or unparseable is the file's statement and is not replaced from the copy.
//
//  DATE AND TIME. DM writes the system's short date and time, so the layout is the user's locale: seen "8/8/2016"
//  "4:26:37 PM", "27.08.2016" "20:54:33", "27/08/2016" "08:55:59 p.m.". Read: three numbers separated by "/", "." or
//  "-", the last of four digits; a time of h:mm:ss, 24-hour, or 12-hour with am/pm in any case, with or without dots.
//  Month first unless the first field exceeds 12; "month-first order assumed" when both of the first two fields are 12
//  or less. Anything else (a year first, a two-digit year, no seconds, a date that does not exist, a date without a
//  time) is nil, never a guess.
//

import Foundation
import FormatoCore

extension AcquisitionMetadata {
    /// The acquisition values of one DM image object under the consumer's rules (`.app`), from its ImageTags maps
    /// (keys relative to `ImageList.N.ImageTags.`). Total and pure: every missing, empty or unreadable tag is a nil field.
    static func dmApp(numbers: [String: Double], strings: [String: String]) -> AcquisitionMetadata {
        let tags = DMImageTags(numbers: numbers, strings: strings)
        var meta = AcquisitionMetadata()

        // The mode decides what (c) allows. "STEM…" is a prefix test (STEM NANOPROBE, STEM, …); "TEM" and
        // "DIFFRACTION" are whole-string tests, as in RosettaSciIO :966–970.
        let illumination = tags.string("Microscope Info.Illumination Mode")
        let imaging = tags.string("Microscope Info.Imaging Mode")
        let isSTEM = illumination?.hasPrefix("STEM") ?? false
        let isTEMDiffraction = illumination == "TEM" && imaging == "DIFFRACTION"
        let indicated = positive(tags.number("Microscope Info.Indicated Magnification"))

        // High tension: stored in V, shown in kV. Rule (b) is applied to the number as shown, after the conversion: a
        // stored 5e-324 V is 0.0 kV, which is "not recorded". (The other quantities are stored in their shown unit, so
        // `positive` runs on what is stored.)
        if let kv = positive(tags.number("Microscope Info.Voltage").map { $0 / 1e3 }) {
            meta.highTensionKV = MetadataReading(kv)
        }

        // Magnification (g): the indicated one. In TEM diffraction the same tag is the camera length (c).
        if !isTEMDiffraction, let m = indicated {
            meta.magnification = MetadataReading(m)
        }

        // Camera length (c) with its unassumed unit (d).
        let cameraLength: Double?
        if isSTEM {
            cameraLength = positive(tags.number("Microscope Info.STEM Camera Length"))
        } else if isTEMDiffraction {
            cameraLength = indicated
        } else {
            cameraLength = nil
        }
        if let cl = cameraLength {
            meta.cameraLengthMM = MetadataReading(cl, note: DMNote.cameraLengthUnit)
        }

        // Detector: no published reader maps it.
        if let name = tags.string("Acquisition.Device.Name") {
            meta.detector = MetadataReading(name, note: DMNote.unvalidated)
        }

        // Dwell: stored in µs, shown in µs.
        if let us = positive(tags.number("DigiScan.Sample Time")) {
            meta.dwellUS = MetadataReading(us)
        }

        // Exposure (f): the Detector copy first, the DataBar copy second; one alone is used.
        let detectorExposure = positive(tags.number("Acquisition.Parameters.Detector.exposure (s)"))
        let dataBarExposure = positive(tags.number("DataBar.Exposure Time (s)"))
        if let first = detectorExposure {
            meta.exposureS = MetadataReading(first, otherCopy: differingCopy(first, dataBarExposure))
        } else if let second = dataBarExposure {
            meta.exposureS = MetadataReading(second, note: DMNote.unvalidated)
        }

        // Acquisition date (e), the DataBar stamp: both strings must read, or neither is shown.
        if let dateText = tags.string("DataBar.Acquisition Date"), let timeText = tags.string("DataBar.Acquisition Time"),
           let date = DMDateTime.date(dateText), let time = DMDateTime.time(timeText) {
            var notes = [localTimeNote]
            if date.orderAssumed { notes.append(DMNote.monthFirst) }
            meta.acquired = MetadataReading(DMDateTime.stamp(date, time), note: notes.joined(separator: "; "))
        }

        meta.instrument = instrumentName(tags)

        let modes = [illumination, imaging].compactMap { $0 }
        if !modes.isEmpty { meta.mode = MetadataReading(modes.joined(separator: " · ")) }

        return meta
    }

    /// The instrument as RosettaSciIO's `_get_microscope_name` reads it (:820–837), behind its `Microscope Info`
    /// gate (:963): the first location, in this order, whose text is not empty and not "[]".
    static func instrumentName(_ tags: DMImageTags) -> MetadataReading<String>? {
        guard tags.hasGroup("Microscope Info") else { return nil }
        for location in ["Session Info.Microscope", "Microscope Info.Name", "Microscope Info.Microscope"] {
            if let name = tags.string(location), name != "[]" { return MetadataReading(name) }
        }
        return nil
    }
}

/// The notes this reader attaches, worded once (the texts are fixed by the registration).
nonisolated enum DMNote {
    static let cameraLengthUnit = "mm (assumed)"
    static let monthFirst = "month-first order assumed"
    static let unvalidated = "unvalidated: no published reader reads it"
}

/// The two ImageTags maps with the stack-builder fallback: the direct key, else the same key under
/// `source.Tags at creation.`, and only when the direct key is absent from its map.
nonisolated struct DMImageTags {
    let numbers: [String: Double]
    let strings: [String: String]

    private static let creationPrefix = "source.Tags at creation."

    func number(_ key: String) -> Double? {
        numbers[key] ?? numbers[Self.creationPrefix + key]
    }

    /// Rule (a): trimmed, and nil when empty. A key that is present but empty is not replaced from the copy.
    func string(_ key: String) -> String? {
        AcquisitionMetadata.text(strings[key] ?? strings[Self.creationPrefix + key])
    }

    /// Whether any scalar tag of the group `name` ("Microscope Info") is carried, directly or under the copy.
    func hasGroup(_ name: String) -> Bool {
        let direct = name + ".", copy = Self.creationPrefix + name + "."
        return numbers.keys.contains { $0.hasPrefix(direct) || $0.hasPrefix(copy) }
            || strings.keys.contains { $0.hasPrefix(direct) || $0.hasPrefix(copy) }
    }
}

/// DM's date and time strings (rule e).
nonisolated enum DMDateTime {
    typealias Day = (year: Int, month: Int, day: Int, orderAssumed: Bool)
    typealias Clock = (hour: Int, minute: Int, second: Int)

    /// 1 to `maxDigits` ASCII digits, as a number; nil for anything else (a sign, a letter, a space, nothing).
    private static func int(_ s: Substring, maxDigits: Int) -> Int? {
        guard !s.isEmpty, s.count <= maxDigits, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        if month == 2 {
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }

    /// Three numbers split on "/", "." or "-", the last of four digits. Month first unless the first exceeds 12.
    static func date(_ s: String) -> Day? {
        let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { "/.-".contains($0) })
        guard parts.count == 3, parts[2].count == 4,
              let a = int(parts[0], maxDigits: 2), let b = int(parts[1], maxDigits: 2),
              let year = int(parts[2], maxDigits: 4) else { return nil }
        let dayFirst = a > 12
        let month = dayFirst ? b : a
        let day = dayFirst ? a : b
        guard (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        // Ambiguous only when month-first was chosen and the second field could have been a month too.
        return (year, month, day, orderAssumed: !dayFirst && b <= 12)
    }

    /// h:mm:ss, 24-hour; or 12-hour followed by am, pm, a.m. or p.m. (any case, spaces and dots ignored).
    static func time(_ s: String) -> Clock? {
        let clock = s.prefix { $0.isASCII && ($0 == ":" || $0.isNumber) }
        let marker = s.dropFirst(clock.count).filter { !$0.isWhitespace && $0 != "." }.lowercased()
        let fields = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let hour = int(fields[0], maxDigits: 2), let minute = int(fields[1], maxDigits: 2),
              let second = int(fields[2], maxDigits: 2), minute < 60, second < 60 else { return nil }
        switch marker {
        case "":
            return hour < 24 ? (hour, minute, second) : nil
        case "am", "pm":
            // 12 AM is hour 0, 12 PM is hour 12.
            return (1...12).contains(hour) ? (hour % 12 + (marker == "pm" ? 12 : 0), minute, second) : nil
        default:
            return nil
        }
    }

    /// `YYYY-MM-DD HH:MM:SS`.
    static func stamp(_ d: Day, _ t: Clock) -> String {
        func pad(_ n: Int, _ width: Int) -> String {
            let digits = String(n)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(d.year, 4))-\(pad(d.month, 2))-\(pad(d.day, 2)) \(pad(t.hour, 2)):\(pad(t.minute, 2)):\(pad(t.second, 2))"
    }
}

extension AcquisitionMetadata {
    /// The acquisition values of one DM image object from its ImageTags maps (keys relative to `ImageList.N.ImageTags.`).
    /// Total and pure: every missing, empty or unreadable tag is a nil field.
    public static func dm(numbers: [String: Double], strings: [String: String],
                          convention: AcquisitionMetadataConvention = .rosettaSciIO) -> AcquisitionMetadata {
        switch convention {
        case .app: return dmApp(numbers: numbers, strings: strings)
        case .rosettaSciIO: return dmReference(numbers: numbers, strings: strings)
        }
    }

    /// The acquisition values of a DM image object (`DM4Experiment.list`).
    public static func dm(_ object: DM4ImageObject, convention: AcquisitionMetadataConvention = .rosettaSciIO) -> AcquisitionMetadata {
        dm(numbers: object.imageTagNumbers, strings: object.imageTagStrings, convention: convention)
    }

    private static func dmReference(numbers: [String: Double], strings: [String: String]) -> AcquisitionMetadata {
        let creation = "source.Tags at creation."
        let stacked = numbers.keys.contains { $0.hasPrefix(creation) } || strings.keys.contains { $0.hasPrefix(creation) }
        let prefix = stacked ? creation : ""
        func number(_ key: String) -> Double? { numbers[prefix + key] }
        func string(_ key: String) -> String? { strings[prefix + key] }
        func hasGroup(_ name: String) -> Bool {
            let group = prefix + name + "."
            return numbers.keys.contains { $0.hasPrefix(group) } || strings.keys.contains { $0.hasPrefix(group) }
        }
        var meta = AcquisitionMetadata()
        /// A mapping with no function: the tag as stored, a number or a text (an empty text is kept, as RosettaSciIO keeps it).
        func raw(_ path: String, _ key: String) {
            if let n = number(path) { meta.signalNumbers[key] = MetadataReading(n) }
            else if let t = string(path) { meta.signalTexts[key] = MetadataReading(t) }
        }

        if let volts = number("Microscope Info.Voltage") { meta.highTensionKV = MetadataReading(volts / 1e3) }

        if let illumination = string("Microscope Info.Illumination Mode") {
            let reduced = illumination.contains("STEM") ? "STEM" : illumination.contains("SEM") ? "SEM" : "TEM"
            meta.mode = MetadataReading(reduced)
        }

        if hasGroup("Microscope Info") {
            let isTEM = string("Microscope Info.Illumination Mode") == "TEM"
            let isDiffraction = string("Microscope Info.Imaging Mode") == "DIFFRACTION"
            let indicated = number("Microscope Info.Indicated Magnification")
            if isTEM {
                if isDiffraction {
                    if let indicated { meta.cameraLengthMM = MetadataReading(indicated, note: DMNote.cameraLengthUnit) }
                } else if let indicated {
                    meta.magnification = MetadataReading(indicated)
                }
            } else {
                if let length = number("Microscope Info.STEM Camera Length") {
                    meta.cameraLengthMM = MetadataReading(length, note: DMNote.cameraLengthUnit)
                }
                if let indicated { meta.magnification = MetadataReading(indicated) }
            }
            for location in ["Session Info.Microscope", "Microscope Info.Name", "Microscope Info.Microscope"] {
                if let name = string(location), !name.isEmpty, name != "[]" {
                    meta.instrument = MetadataReading(name)
                    break
                }
            }
        }

        // `signal_type` (:601-613) reads the DIRECT tags, even for a stack-builder image; the dwell and exposure follow it
        // (:1025-1240): EELS maps its own acquisition group, X-ray (EDS_TEM) maps neither, CL maps the DigiScan sample time,
        // and an image (no signal type) maps the DigiScan sample time, or else the detector exposure.
        let signal = strings["Meta Data.Signal"]
        func directGroup(_ name: String) -> Bool {
            numbers.keys.contains { $0.hasPrefix(name + ".") } || strings.keys.contains { $0.hasPrefix(name + ".") }
        }
        let signalType = signal == "X-ray" ? "EDS_TEM"
            : (signal == "CL" || directGroup("Acquisition.Monarc Spectrometer")) ? "CL"
            : (signal == "EELS" || directGroup("spim.eels")) ? "EELS" : ""
        switch signalType {
        case "EELS":
            // `_get_exposure_time` over the EELS.Acquisition group: the integration time, else the exposure × the frames.
            let eelsSeconds: Double? = number("EELS.Acquisition.Integration time (s)")
                ?? number("EELS.Acquisition.Exposure (s)").map { $0 * (number("EELS.Acquisition.Number of frames") ?? 1) }
            if let seconds = eelsSeconds {
                if hasGroup("DigiScan") { meta.dwellUS = MetadataReading(seconds * 1e6, note: "EELS acquisition time (s) × 1e6") }
                else { meta.exposureS = MetadataReading(seconds, note: "EELS acquisition") }
            }
        case "EDS_TEM": break
        case "CL":
            if let us = number("DigiScan.Sample Time") { meta.dwellUS = MetadataReading(us) }
        default:
            if hasGroup("DigiScan") {
                if let us = number("DigiScan.Sample Time") { meta.dwellUS = MetadataReading(us) }
            } else if let seconds = number("Acquisition.Parameters.Detector.exposure (s)") {
                meta.exposureS = MetadataReading(seconds)
            }
        }

        // The date and time: RosettaSciIO maps several sources to General.date and General.time, applied in mapping order, so
        // the LAST source that parses wins (DataBar, then the SI group, then the signal type's own group).
        var dateSources = ["DataBar.Acquisition Date"], timeSources = ["DataBar.Acquisition Time"]
        switch signalType {
        case "EELS": dateSources.append("EELS.Acquisition.Date"); timeSources.append("EELS.Acquisition.Start time")
        default: break
        }
        let lastDate = dateSources.reversed().lazy.compactMap { string($0).flatMap(DMDateTime.date) }.first
        let lastTime = timeSources.reversed().lazy.compactMap { string($0).flatMap(DMDateTime.time) }.first
        if let date = lastDate, let time = lastTime {
            var notes = [localTimeNote]
            if date.orderAssumed { notes.append(DMNote.monthFirst) }
            meta.acquired = MetadataReading(DMDateTime.stamp(date, time), note: notes.joined(separator: "; "))
        }

        // The 0.3.1 fields (`get_mapping` :911-960, unconditional on the Microscope Info group): the stage as the tags hold it
        // (the position ×1e-3), the probe current in nA as stored, the operator (a non-empty text, untrimmed).
        func reading(_ key: String, scale: Double = 1, note: String? = nil) -> MetadataReading<Double>? {
            number(key).map { MetadataReading($0 * scale, note: note) }
        }
        let stagePath = "Microscope Info.Stage Position.Stage "
        do {
            meta.stageTiltAlphaDeg = reading(stagePath + "Alpha")
            meta.stageTiltBetaDeg = reading(stagePath + "Beta")
            let scaled = "stored value × 1e-3, as RosettaSciIO"
            meta.stageX = reading(stagePath + "X", scale: 1e-3, note: scaled)
            meta.stageY = reading(stagePath + "Y", scale: 1e-3, note: scaled)
            meta.stageZ = reading(stagePath + "Z", scale: 1e-3, note: scaled)
        }
        meta.beamCurrentNA = reading("Microscope Info.Probe Current (nA)")
        if let operatorText = string("Session Info.Operator"), !operatorText.isEmpty { meta.operatorName = MetadataReading(operatorText) }
        if let specimen = string("Session Info.Specimen"), !specimen.isEmpty { meta.sampleDescription = MetadataReading(specimen) }
        // EELS angles, only for an EELS signal (`signal_type` :601-613 reads the DIRECT tags, even for a stack).
        if signalType == "EELS" {
            meta.collectionAngleMrad = reading("EELS.Experimental Conditions.Collection semi-angle (mrad)")
            meta.convergenceAngleMrad = reading("EELS.Experimental Conditions.Convergence semi-angle (mrad)")
            raw("EELS.Acquisition.Number of frames", "Detector.EELS.frame_number")
            // `Aperture_label` with "mm" removed, through `_parse_string(convert_to_float=True)` (a string tag only).
            if let label = strings[prefix + "EELS Spectrometer.Aperture label"], !label.isEmpty,
               let mm = formatoPythonFloat(label.replacingOccurrences(of: "mm", with: "")) {
                meta.signalNumbers["Detector.EELS.aperture_size"] = MetadataReading(mm)
            }
            raw("EELS Spectrometer.Instrument name", "Detector.EELS.spectrometer")
        }

        // RosettaSciIO maps no detector: the camera name as stored, labelled.
        if let name = text(string("Acquisition.Device.Name")) { meta.detector = MetadataReading(name, note: unvalidatedNote) }
        return meta
    }
}
