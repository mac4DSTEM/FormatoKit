//
//  VeloxSpectrumSignals.swift
//  Role: A Velox file's single spectra (`Data/Spectrum`) as FormatoCore signals, as RosettaSciIO's `rsciio.emd.file_reader` returns
//        them with `select_type="single_spectrum"` (`FeiEMDReader._read_single_spectrum` / `_read_spectrum`): the stored counts as
//        `dataset[:].T`, a `Stack` axis when the dataset holds more than one spectrum, an `Energy` axis in keV from
//        `_get_dispersion_offset`, the title "EDS", signal type `EDS_TEM`, the file name, the acquisition date, time and time zone,
//        and the mapping HyperSpy applies to `original_metadata` (`_get_mapping`) for every key the spectrum's metadata holds.
//        RosettaSciIO reads spectra only from a file whose `Data` has no `Image` group (type `Spectrum`) or has both `Image` and
//        `SpectrumImage` (type `SpectrumStream`); in any other file it returns none, and so does this.
//        Eager: a spectrum is a few thousand counts. Registered deviations (the SI path's, docs/parity.md): the four metadata
//        groups (`Displays`, `Operations`, `SharedProperties`, `Features`) are not parsed, so a malformed entry there does not
//        refuse the read; `Sample.elements` (the element selection) is not mapped.
//

import Foundation
import FormatoCore
import FormatoHDF5

public nonisolated struct VeloxSpectrumSignals: Sendable {
    public let path: String
    /// RosettaSciIO's dictionaries in its order (the `Spectrum` group's children by name). Empty where it returns none.
    public let signals: [FormatoSignal]

    /// `timeZone` is the zone RosettaSciIO's "local time" is: nil is this process's (`tzlocal()`), a value is shown on that clock
    /// (the zone's abbreviation is Foundation's, which can differ from the tz database's, e.g. "GMT+1" for "CET").
    public init(path: String, timeZone: TimeZone? = nil, policy: VeloxReadPolicy = VeloxReadPolicy(),
                cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws {
        self.path = path
        signals = try withoutActuallyEscaping(cancelled) { cancelled in
            try VeloxSpectrumRead(path: path, zone: timeZone, policy: policy, cancelled: cancelled).run()
        }
    }
}

private nonisolated struct VeloxSpectrumRead {
    let path: String
    let zone: TimeZone?
    let policy: VeloxReadPolicy
    let cancelled: @Sendable () -> Bool
    let file: VeloxFile
    let fileName: String

    init(path: String, zone: TimeZone?, policy: VeloxReadPolicy, cancelled: @escaping @Sendable () -> Bool) throws {
        self.path = path
        self.zone = zone
        self.policy = policy
        self.cancelled = cancelled
        file = try VeloxFile(path: path)
        fileName = formatoDisplayFileName(path)
    }

    func raises(_ why: String) -> FormatoReadError {
        .unsupported("Velox spectrum of \(fileName): \(why) (RosettaSciIO raises).")
    }

    func isDataset(_ path: String) -> Bool { (try? file.open(path)).map { file.close($0); return true } ?? false }

    func run() throws -> [FormatoSignal] {
        try FormatoCancellation.check(cancelled)
        guard let versionText = file.readString("/Version"),
              let version = (try? JSONSerialization.jsonObject(with: Data(versionText.utf8))) as? [String: Any],
              veloxAcceptsFormat(version["format"] as? String) else { throw VeloxEMDError.notVeloxFile(fileName) }
        guard file.exists("/Data"), !isDataset("/Data") else { throw raises("no Data group") }
        // `_check_im_type`: Image + SpectrumImage is a stream, Image alone is images, no Image is a spectrum.
        let hasImage = file.exists("/Data/Image"), hasSpectrumImage = file.exists("/Data/SpectrumImage")
        if hasImage && !hasSpectrumImage { return [] }
        guard file.exists("/Data/Spectrum") else { return [] }
        guard !isDataset("/Data/Spectrum") else { throw raises("Data/Spectrum is a dataset") }
        var out: [FormatoSignal] = []
        for key in file.children(of: "/Data/Spectrum") {
            try FormatoCancellation.check(cancelled)
            out.append(try spectrum(key))
        }
        return out
    }

    func spectrum(_ key: String) throws -> FormatoSignal {
        let group = "/Data/Spectrum/" + key
        guard file.exists(group + "/Data") else { throw raises("\(group) has no Data") }
        guard file.exists(group + "/Metadata") else { throw raises("\(group) has no Metadata") }
        let json: Data
        do { json = try file.readMetadataJSON(group: group, column: 0) } catch { throw raises("the metadata of \(group): \(error.localizedDescription)") }
        guard let om = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw raises("the metadata of \(group) is not a JSON object")
        }
        let data = try readData(group + "/Data")
        let source = String(group.dropFirst()) + "/Metadata[0]."

        // `_get_detector_information(original_metadata)`: indexes Detectors, a KeyError when the named detector is missing.
        if let binary = om["BinaryResult"] {
            guard let binary = binary as? [String: Any] else { throw raises("BinaryResult is not an object") }
            if let index = binary["DetectorIndex"], !(index is NSNull) {
                guard let text = pythonFormat(index) else { throw raises("DetectorIndex is not an integer or string") }
                guard let detectors = om["Detectors"] as? [String: Any], detectors["Detector-" + text] != nil else {
                    throw raises("DetectorIndex names Detector-\(text), which Detectors lacks")
                }
            }
        } else {
            guard let detectors = om["Detectors"] as? [String: Any], detectors["Detector-0"] != nil else {
                throw raises("no BinaryResult and no Detectors.Detector-0")
            }
        }
        let energy = try dispersionOffset(om: om, json: json)   // its unit is not used: RosettaSciIO's axis says "keV" whatever it found
        var axes: [FormatoAxis] = []
        if data.stack > 1 {
            axes.append(FormatoAxis(name: "Stack", size: data.stack, scale: 1, offset: 0, units: "", navigate: true))
        }
        axes.append(FormatoAxis(name: "Energy", size: data.bins, scale: energy.scale, offset: energy.offset, units: "keV", navigate: false))
        let shape = data.stack > 1 ? [data.stack, data.bins] : [data.bins]
        let array = try FormatoArray(dataType: data.type, shape: shape, bytes: data.bytes)
        let md = try metadata(om: om, source: source)
        return FormatoSignal(title: md["General.title"]?.value.text ?? "EDS", signalType: "EDS_TEM", axes: axes, metadata: md, data: array)
    }

    /// `dataset[:].T` of the stored `(bins, stack)` (or `(bins,)`).
    func readData(_ dataset: String) throws -> (type: FormatoDataType, bins: Int, stack: Int, bytes: Data) {
        let d = try file.open(dataset)
        defer { file.close(d) }
        guard d.dims.count == 1 || d.dims.count == 2 else { throw raises("\(dataset) has rank \(d.dims.count) (RosettaSciIO's axes cover rank 1 and 2)") }
        let bins = d.dims[0], stack = d.dims.count == 2 ? d.dims[1] : 1
        guard bins > 0, stack > 0 else { throw raises("\(dataset) is empty") }
        let h5 = file.h5
        let (type, memory): (FormatoDataType, hid_t)
        switch (d.typeClass, d.byteSize, d.isSigned) {
        case (0, 1, false): (type, memory) = (.uint8, h5.uint8)
        case (0, 2, false): (type, memory) = (.uint16, h5.uint16)
        case (0, 4, false): (type, memory) = (.uint32, h5.uint32)
        case (0, 8, false): (type, memory) = (.uint64, h5.uint64)
        case (0, 1, true): (type, memory) = (.int8, h5.int8)
        case (0, 2, true): (type, memory) = (.int16, h5.int16)
        case (0, 4, true): (type, memory) = (.int32, h5.int32)
        case (0, 8, true): (type, memory) = (.int64, h5.int64)
        case (1, 4, _): (type, memory) = (.float32, h5.float32)
        case (1, 8, _): (type, memory) = (.float64, h5.float64)
        default: throw FormatoReadError.unsupportedDataType("Velox spectrum \(dataset) of \(fileName)")
        }
        let (count, overflow) = bins.multipliedReportingOverflow(by: stack)
        let (total, overflow2) = count.multipliedReportingOverflow(by: type.byteSize)
        guard !overflow, !overflow2, total <= policy.arrayByteLimit else {
            throw VeloxEMDError.readFailed("a spectrum dataset of \(bins) x \(stack) values is larger than the read limit")
        }
        var stored = [UInt8](repeating: 0, count: total)
        try stored.withUnsafeMutableBytes {
            try file.readSlab(d, type: memory, start: d.dims.map { _ in 0 }, count: d.dims, into: $0.baseAddress!)
        }
        guard stack > 1 else { return (type, bins, stack, Data(stored)) }
        let size = type.byteSize
        var out = [UInt8](repeating: 0, count: total)
        for s in 0..<stack {
            for b in 0..<bins {
                let from = (b * stack + s) * size, to = (s * bins + b) * size
                for k in 0..<size { out[to + k] = stored[from + k] }
            }
        }
        return (type, bins, stack, Data(out))
    }

    /// `_get_dispersion_offset` with `rebin_energy` 1: the first `Detectors` entry, in written order, whose DetectorName contains
    /// `BinaryResult.Detector`; a KeyError anywhere gives (1, 0).
    func dispersionOffset(om: [String: Any], json: Data) throws -> (scale: Double, offset: Double) {
        let fallback = (scale: 1.0, offset: 0.0)
        guard let detectorsValue = om["Detectors"] else { return fallback }
        guard let detectors = detectorsValue as? [String: Any] else { throw raises("Detectors is not an object (.items())") }
        let written = VeloxMetadata.detectorKeyOrder(jsonData: json) ?? []
        let order = written.filter { detectors[$0] != nil } + detectors.keys.filter { !written.contains($0) }.sorted()
        for key in order {
            guard let binary = om["BinaryResult"] as? [String: Any], let wanted = binary["Detector"] else { return fallback }
            guard let entry = detectors[key] as? [String: Any] else { throw raises("Detectors.\(key) is not an object") }
            guard let nameValue = entry["DetectorName"] else { return fallback }
            guard let wantedText = wanted as? String, let name = nameValue as? String else {
                throw raises("BinaryResult.Detector or Detectors.\(key).DetectorName is not a string")
            }
            guard wantedText.isEmpty || name.range(of: wantedText, options: .literal) != nil else { continue }
            guard let dispersionValue = entry["Dispersion"] else { return fallback }
            guard let dispersion = veloxPythonFloat(dispersionValue) else { throw raises("Detectors.\(key).Dispersion: float() refuses it") }
            guard let offsetValue = entry["OffsetEnergy"] else { return fallback }
            guard let offset = veloxPythonFloat(offsetValue) else { throw raises("Detectors.\(key).OffsetEnergy: float() refuses it") }
            return (dispersion / 1000.0 * 1.0, offset / 1000.0)
        }
        return fallback
    }

    // MARK: metadata

    func entry(_ key: String, _ value: FormatoValue, units: String? = nil, source: String, rule: String) -> FormatoMetadataEntry {
        FormatoMetadataEntry(key: key, value: value, units: units, provenance: FormatoProvenance(file: fileName, source: source, rule: rule))
    }

    /// `_get_metadata_dict` then `_get_mapping`, in RosettaSciIO's order. Where Python indexes a missing key or `float()` refuses, the read is refused.
    func metadata(om: [String: Any], source: String) throws -> FormatoMetadata {
        var md = FormatoMetadata()
        md.set(entry("General.original_filename", .text(fileName), source: "(the file name)", rule: "rsciio emd: os.path.split(filename)[1]"))
        md.set(entry("General.title", .text("EDS"), source: "(the single spectrum)", rule: "rsciio emd velox _read_single_spectrum: detector_name = 'EDS'"))

        // The start time: `om["Acquisition"]` (KeyError without it), else `CustomProperties` "Detectors[BM-Ceta].TimeStamp" / 1e6.
        guard let acquisition = om["Acquisition"] as? [String: Any] else { throw raises("no Acquisition object") }
        var unix: Double?
        var unixSource = ""
        if let start = acquisition["AcquisitionStartDatetime"] {
            guard let stamp = start as? [String: Any], let raw = stamp["DateTime"] else { throw raises("AcquisitionStartDatetime has no DateTime") }
            guard let seconds = veloxPythonFloat(raw) else { throw raises("AcquisitionStartDatetime.DateTime: float() refuses it") }
            unix = seconds
            unixSource = source + "Acquisition.AcquisitionStartDatetime.DateTime"
        } else {
            guard let custom = om["CustomProperties"] else { throw raises("no CustomProperties object") }
            if let custom = custom as? [String: Any], let stamp = custom["Detectors[BM-Ceta].TimeStamp"] as? [String: Any] {
                guard let raw = stamp["value"], let micro = veloxPythonFloat(raw) else { throw raises("Detectors[BM-Ceta].TimeStamp.value: float() refuses it") }
                unix = micro / 1e6
                unixSource = source + "CustomProperties.Detectors[BM-Ceta].TimeStamp.value"
            }
        }
        let zoneName = zone.map { $0.abbreviation(for: Date()) ?? $0.identifier } ?? VeloxLocalClock.processZoneName()
        if let unix {
            guard let iso = VeloxLocalClock.isoformat(unix: unix, zone: zone) else { throw raises("the time stamp \(unix) is outside Python's datetime range") }
            let halves = iso.split(separator: "T", omittingEmptySubsequences: false)
            guard halves.count == 2 else { throw raises("the time stamp does not split into a date and a time") }
            let rule = "rsciio emd velox _convert_datetime: fromtimestamp(float(x), local zone).isoformat().split('+')[0]"
            md.set(entry("General.date", .text(String(halves[0])), source: unixSource, rule: rule))
            md.set(entry("General.time", .text(String(halves[1])), source: unixSource, rule: rule))
            md.set(entry("General.time_zone", .text(zoneName), source: unixSource,
                         rule: "rsciio emd velox: tzlocal().tzname(datetime.today())"))
        }

        // The mapping (`_get_mapping()`: map_selected_element aside), in RosettaSciIO's order, each applied when its path holds a value.
        func node(_ path: String) -> Any? {
            var current: Any? = om
            for part in path.split(separator: ".", omittingEmptySubsequences: false) {
                guard let dict = current as? [String: Any], let next = dict[String(part)] else { return nil }
                current = next
            }
            return current
        }
        func number(_ path: String, _ key: String, units: String? = nil, rule: String, _ transform: (Double) -> Double) throws {
            guard let raw = node(path), !(raw is NSNull) else { return }
            guard let x = veloxPythonFloat(raw) else { throw raises("\(path): float() refuses it") }
            md.set(entry(key, .number(transform(x)), units: units, source: source + path, rule: rule))
        }
        func text(_ path: String, _ key: String, units: String? = nil, rule: String, _ format: (Double) -> String) throws {
            guard let raw = node(path), !(raw is NSNull) else { return }
            guard let x = veloxPythonFloat(raw) else { throw raises("\(path): float() refuses it") }
            md.set(entry(key, .text(format(x)), units: units, source: source + path, rule: rule))
        }
        let degrees = { (x: Double) in AcquisitionMetadata.pythonRound(AcquisitionMetadata.numpyDegrees(x), 3) }
        try number("Optics.AccelerationVoltage", "Acquisition_instrument.TEM.beam_energy", units: "kV", rule: "rsciio emd velox mapping: float(x) / 1e3") { $0 / 1e3 }
        try number("Optics.CameraLength", "Acquisition_instrument.TEM.camera_length", units: "mm", rule: "rsciio emd velox mapping: float(x) * 1e3") { $0 * 1e3 }
        try number("CustomProperties.StemMagnification.value", "Acquisition_instrument.TEM.magnification", rule: "rsciio emd velox mapping: float") { $0 }
        if let cls = node("Instrument.InstrumentClass"), !(cls is NSNull) {
            if let t = cls as? String {
                md.set(entry("Acquisition_instrument.TEM.microscope", .text(t), source: source + "Instrument.InstrumentClass", rule: "rsciio emd velox mapping: as stored"))
            } else {
                throw raises("Instrument.InstrumentClass is not a string")
            }
        }
        try number("Stage.AlphaTilt", "Acquisition_instrument.TEM.Stage.tilt_alpha", units: "°", rule: "rsciio emd velox mapping: round(np.degrees(float(x)), 3)", degrees)
        try number("Stage.BetaTilt", "Acquisition_instrument.TEM.Stage.tilt_beta", units: "°", rule: "rsciio emd velox mapping: round(np.degrees(float(x)), 3)", degrees)
        for axis in ["x", "y", "z"] {
            try number("Stage.Position.\(axis)", "Acquisition_instrument.TEM.Stage.\(axis)", units: "m", rule: "rsciio emd velox mapping: round(float(x), 6)") {
                AcquisitionMetadata.pythonRound($0, 6)
            }
        }
        if let frames = node("ImportedDataParameter.Number_of_frames"), !(frames is NSNull) {
            let value: FormatoValue
            switch frames {
            case let s as String: value = .text(s)
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): value = .flag(n.boolValue)
            case let n as NSNumber: value = .number(n.doubleValue)
            default: throw raises("ImportedDataParameter.Number_of_frames is a list or an object")
            }
            md.set(entry("Acquisition_instrument.TEM.Detector.EDS.number_of_frames", value, source: source + "ImportedDataParameter.Number_of_frames",
                         rule: "rsciio emd velox mapping: as stored"))
        }
        try number("DetectorMetadata.ElevationAngle", "Acquisition_instrument.TEM.Detector.EDS.elevation_angle", units: "°",
                   rule: "rsciio emd velox mapping: round(float(x), 3)") { AcquisitionMetadata.pythonRound($0, 3) }
        try number("DetectorMetadata.Gain", "Signal.Noise_properties.Variance_linear_model.gain_factor", rule: "rsciio emd velox mapping: float") { $0 }
        try number("DetectorMetadata.Offset", "Signal.Noise_properties.Variance_linear_model.gain_offset", rule: "rsciio emd velox mapping: float") { $0 }
        try text("DetectorMetadata.AzimuthAngle", "Acquisition_instrument.TEM.Detector.EDS.azimuth_angle", units: "°",
                 rule: "rsciio emd velox mapping: '{:.3f}'.format(np.degrees(float(x)))") { String(format: "%.3f", AcquisitionMetadata.numpyDegrees($0)) }
        try text("DetectorMetadata.LiveTime", "Acquisition_instrument.TEM.Detector.EDS.live_time", units: "s",
                 rule: "rsciio emd velox mapping: '{:.6f}'.format(float(x))") { String(format: "%.6f", $0) }
        try text("DetectorMetadata.RealTime", "Acquisition_instrument.TEM.Detector.EDS.real_time", units: "s",
                 rule: "rsciio emd velox mapping: '{:.6f}'.format(float(x))") { String(format: "%.6f", $0) }
        if let name = node("DetectorMetadata.DetectorName"), !(name is NSNull) {
            guard let t = name as? String else { throw raises("DetectorMetadata.DetectorName is not a string") }
            md.set(entry("General.title", .text(t), source: source + "DetectorMetadata.DetectorName", rule: "rsciio emd velox mapping: as stored"))
        }
        return md
    }
}

/// Python's `datetime.fromtimestamp(t, tz).isoformat()` on a local zone, and that zone's name.
nonisolated enum VeloxLocalClock {
    /// `tzlocal().tzname(...)` for this process: the tz database's abbreviation ("CEST"), as `localtime_r` reports it.
    static func processZoneName() -> String {
        var t = time(nil)
        var parts = tm()
        localtime_r(&t, &parts)
        return parts.tm_zone.map { String(cString: $0) } ?? TimeZone.current.identifier
    }

    /// `YYYY-MM-DDTHH:MM:SS[.ffffff]` and, for an offset that is not positive or zero, its `-HH:MM`: RosettaSciIO cuts at the first "+",
    /// so a negative offset stays on the string. nil outside years 1 to 9999 or for a non-finite stamp.
    static func isoformat(unix: Double, zone: TimeZone?) -> String? {
        guard unix.isFinite, abs(unix) < 2.5e11 else { return nil }
        // CPython: modf, then round(frac * 1e6) half-even, carrying into the seconds.
        var whole = unix.rounded(.towardZero)
        let frac = unix - whole
        var micro = Int((frac * 1e6).rounded(.toNearestOrEven))
        if micro >= 1_000_000 { whole += 1; micro -= 1_000_000 } else if micro < 0 { whole -= 1; micro += 1_000_000 }
        let seconds = Int(whole)
        var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0, offset = 0
        if let zone {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let date = Date(timeIntervalSince1970: whole)
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard let y = c.year, let mo = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let s = c.second else { return nil }
            (year, month, day, hour, minute, second) = (y, mo, d, h, mi, s)
            offset = zone.secondsFromGMT(for: date)
        } else {
            var t = time_t(seconds)
            var parts = tm()
            guard localtime_r(&t, &parts) != nil else { return nil }
            (year, month, day, hour, minute, second) = (Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
                                                         Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
            offset = Int(parts.tm_gmtoff)
        }
        guard (1...9999).contains(year) else { return nil }
        func pad(_ n: Int, _ width: Int) -> String {
            let digits = String(n)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        var out = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
        if micro != 0 { out += "." + pad(micro, 6) }
        if offset < 0 {
            let a = -offset
            out += "-\(pad(a / 3600, 2)):\(pad((a % 3600) / 60, 2))" + (a % 60 != 0 ? ":\(pad(a % 60, 2))" : "")
        }
        return out
    }
}
