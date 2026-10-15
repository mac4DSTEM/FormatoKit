//
//  DMSignals.swift
//  Role: A DM3 or DM4 file's image objects as FormatoCore signals, as RosettaSciIO 049e7d70's
//        `rsciio.digitalmicrograph.file_reader` returns them (docs/registration-step-1.md §3.2, amendment A1): the data as
//        stored, shape = `Dimensions` reversed, the axes (scale, offset = -origin * scale, units, name, navigate), the signal
//        type, the title, and the metadata of step 1 with the tag path each value came from. Lazy: the data is read from
//        the file by slab, never whole unless asked (`FormatoFileArray`).
//        What it builds on is `DM4Experiment.list`'s walk (inherited, unchanged): one parser.
//        RosettaSciIO's `post_process` (HyperSpy's `to_signal1D` for a spectrum image, then `squeeze`) is HyperSpy's step,
//        not the reader's, and is not applied: the signal is the file reader's dictionary.
//

import Foundation
import FormatoCore

public nonisolated struct DMFile: Sendable {
    public let path: String
    /// Every image object, in `ImageList` order, except those the root `Thumbnails.N.ImageIndex` list names: RosettaSciIO's
    /// exclusion rule exactly (`DM4Experiment.list` keeps them, with role `.thumbnail` from that list).
    public let objects: [DM4ImageObject]

    /// Lists the file (header only: the walk seeks past every data block).
    public init(path: String) throws {
        try self.init(path: path, options: DMReadOptions())
    }

    /// As `init(path:)`, with the walk's `options` (how much of a string the walk keeps).
    public init(path: String, options: DMReadOptions) throws {
        self.path = path
        self.objects = try DM4Experiment.list(path: path, options: options).filter { $0.roleSource != .thumbnailIndex }
    }

    /// The stored element type of a DM type code, or nil for a type FormatoKit does not read (3 and 13 complex, 4, 5 and
    /// 27, 28 packed complex, 8 and 23 RGB, 14 bool, and any unknown code).
    public static func dataType(code: Int) -> FormatoDataType? {
        switch code {
        case 1: return .int16
        case 2: return .float32
        case 6: return .uint8
        case 7: return .int32
        case 9: return .int8
        case 10: return .uint16
        case 11: return .uint32
        case 12: return .float64
        default: return nil
        }
    }

    /// RosettaSciIO's `signal_type`: "X-ray" -> "EDS_TEM"; "CL" or an `Acquisition.Monarc Spectrometer` group -> "CL";
    /// "EELS" or Orsay's `spim.eels` group -> "EELS"; else "".
    public static func signalType(of object: DM4ImageObject) -> String {
        let signal = object.imageTagStrings["Meta Data.Signal"] ?? ""
        if signal == "X-ray" { return "EDS_TEM" }
        if signal == "CL" || hasGroup(object, "Acquisition.Monarc Spectrometer") { return "CL" }
        if signal == "EELS" || hasGroup(object, "spim.eels") { return "EELS" }
        return ""
    }

    /// Whether `ImageTags.<group>` holds anything the walk kept (a number or a string under it).
    static func hasGroup(_ object: DM4ImageObject, _ group: String) -> Bool {
        let prefix = group + "."
        return object.imageTagNumbers.keys.contains { $0.hasPrefix(prefix) } || object.imageTagStrings.keys.contains { $0.hasPrefix(prefix) }
            || object.imageTagNumbers[group] != nil || object.imageTagStrings[group] != nil
    }

    /// The axes in array order (slowest first), RosettaSciIO's `get_axes_dict`. Built for every object, also one whose
    /// data type is refused (amendment A1.1).
    public static func axes(of object: DM4ImageObject) -> [FormatoAxis] {
        let n = object.dimensions.count
        // DM order (fastest first), a missing calibration as scale 1, origin 0, units "" (RosettaSciIO pads the same values
        // after the listed calibrations, amendment A1.4); then reversed into array order.
        let calibrations: [(origin: Double, scale: Double, units: String)] = (0..<n).map { i in
            guard i < object.axes.count, let a = object.axes[i] else { return (0, 1, "") }
            return (a.origin, a.scale, a.units)
        }
        let shape = Array(object.dimensions.reversed())
        let cal = Array(calibrations.reversed())
        let scales = cal.map(\.scale)
        let offsets = cal.map { (-1 * $0.origin) * $0.scale }     // `-1 * origins[::-1] * self.scales`
        let units = cal.map(\.units)

        // `names`: the energy axis by its units, found by `units.index(...)` (the first match); then x, y, z from the fastest.
        // RosettaSciIO tests `signal_type in ("EDS", "EDX")`, which its own `signal_type` ("EDS_TEM") never equals, so an
        // EDS energy axis is named like a spatial one there; ported as it is (amendment A4), named in docs/parity.md.
        var names = [String?](repeating: nil, count: n)
        var indices = Array(0..<n)
        let type = signalType(of: object)
        let energy: (String, String)? = type == "EELS" ? ("eV", "Energy loss") : type == "EDS" || type == "EDX" ? ("keV", "Energy")
            : type == "CL" ? ("nm", "Wavelength") : nil
        if let (unit, name) = energy, let i = units.firstIndex(of: unit) {
            names[indices.remove(at: i)] = name
        }
        for (index, name) in zip(indices.reversed(), ["x", "y", "z"]) { names[index] = name }

        // `navigate`.
        var navigate = [Bool](repeating: true, count: n)
        let format = object.imageTagStrings["Meta Data.Format"]
        let spectrumLike = (format == "Spectrum image" || format == "Spectrum") || hasGroup(object, "spim")
        if n == 1 {
            navigate[n - 1] = false
        } else if spectrumLike && n == 2 {
            navigate[n - 1] = false
        } else if n >= 2 {
            navigate[n - 2] = false; navigate[n - 1] = false
        }
        return (0..<n).map { k in
            FormatoAxis(name: names[k], size: shape[k], scale: scales[k], offset: offsets[k], units: units[k], navigate: navigate[k])
        }
    }

    /// The metadata of step 1, each value with the tag path it came from (amendment A1.5).
    public func metadata(of object: DM4ImageObject) -> FormatoMetadata {
        let file = formatoDisplayFileName(path)
        let tags = "ImageList.\(object.index).ImageTags."
        func p(_ source: String, _ rule: String) -> FormatoProvenance { FormatoProvenance(file: file, source: source, rule: rule) }
        var m = FormatoMetadata()
        m.set(FormatoMetadataEntry(key: "General.title", value: .text(object.name), units: nil,
                                   provenance: p("ImageList.\(object.index).Name", "rsciio digitalmicrograph: the object's Name, \"\" when absent")))
        m.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(file), units: nil,
                                   provenance: p("(the file name)", "rsciio digitalmicrograph: os.path.split(filename)[1]")))
        m.set(FormatoMetadataEntry(key: "Signal.signal_type", value: .text(Self.signalType(of: object)), units: nil,
                                   provenance: p(tags + "Meta Data.Signal", "rsciio digitalmicrograph: signal_type rule")))
        // `get_mapping`: the stack builder's tags under `source.Tags at creation`; SEM when `Microscope Info.Illumination
        // Mode` (of the object's own tags) contains "SEM" but not "STEM", else TEM; beam energy = Voltage / 1e3.
        let inner = Self.hasGroup(object, "source") ? "source.Tags at creation." : ""
        if let volts = object.imageTagNumbers[inner + "Microscope Info.Voltage"] {
            let mode = object.imageTagStrings["Microscope Info.Illumination Mode"]
            let microscope = mode.map { !$0.contains("STEM") && $0.contains("SEM") } == true ? "SEM" : "TEM"
            m.set(FormatoMetadataEntry(key: "Acquisition_instrument.\(microscope).beam_energy", value: .number(volts / 1e3),
                                       units: "kV", provenance: p(tags + inner + "Microscope Info.Voltage",
                                                                  "rsciio digitalmicrograph mapping: value / 1e3")))
        }
        return m
    }

    /// The lazy signal of the object with one-based `index`. Throws `FormatoReadError.unsupportedDataType` for a type
    /// FormatoKit does not read, `.truncated` when the declared data does not fit the file, `.unsupported` for no such object.
    public func signal(index: Int) throws -> FormatoLazySignal {
        guard let object = objects.first(where: { $0.index == index }) else {
            throw FormatoReadError.unsupported("\(formatoDisplayFileName(path)) has no image object \(index).")
        }
        guard let type = Self.dataType(code: object.dataType) else {
            throw FormatoReadError.unsupportedDataType("Image object \(index) (\(object.name)), DM type \(object.dataType),")
        }
        let shape = Array(object.dimensions.reversed())
        let count = try FormatoArray.elementCount(shape)
        let (bytes, overflow) = count.multipliedReportingOverflow(by: type.byteSize)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        guard !overflow, object.dataByteCount == bytes, object.dataOffset >= 0, let size, object.dataOffset <= size - bytes else {
            throw FormatoReadError.truncated(formatoDisplayFileName(path))
        }
        return FormatoLazySignal(title: object.name, signalType: Self.signalType(of: object), axes: Self.axes(of: object),
                                 metadata: metadata(of: object),
                                 array: FormatoFileArray(path: path, offset: object.dataOffset, dataType: type, shape: shape))
    }
}
