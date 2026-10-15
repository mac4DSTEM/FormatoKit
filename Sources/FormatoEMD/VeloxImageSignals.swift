//
//  VeloxImageSignals.swift
//  Role: A Velox file's images as FormatoCore signals, as RosettaSciIO 049e7d70's `rsciio.emd` reader returns them with
//        `select_type="images"` (docs/registration-step-1.md §3.3, amendments A1 and A4; docs/registration-step-3.md): shape
//        `(frames, y, x)` or `(y, x)`, the STORED type (step 3; Float32 until then), RosettaSciIO's title (step 3,
//        `VeloxTitles`), the Time, y and x axes with Pint's compact units, and the beam energy with its JSON path. Lazy: a
//        slab reads only the frames it covers, one `readImageFrameBytes` each.
//        RosettaSciIO reads every frame of an image only in a file without `Data/SpectrumImage` (`im_type == "Image"`);
//        in a spectrum-image file it reads the first frame (`load_SI_image_stack=False`, its default), and so does this.
//

import Foundation
import FormatoCore
import FormatoHDF5

public nonisolated struct VeloxImageSignals: Sendable {
    public let reader: VeloxEMDReader
    public let images: [VeloxImageInfo]
    /// True when the file has no `Data/SpectrumImage` group: RosettaSciIO then reads every frame of a stack.
    public let readsWholeStacks: Bool
    /// RosettaSciIO's title of each image (registration step 3 §3.2).
    let titles: VeloxTitles

    /// Throws `FormatoReadError.unsupported` where RosettaSciIO's title rule raises on the file (registration step 3 §3.2).
    public init(path: String, cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws {
        reader = VeloxEMDReader(path: path)
        images = try reader.images(cancelled: cancelled)
        readsWholeStacks = HDF5Serial.run { (try? VeloxFile(path: path)).map { !$0.exists("/Data/SpectrumImage") } ?? true }
        titles = try HDF5Serial.run { try VeloxTitles(file: try VeloxFile(path: path), fileName: formatoDisplayFileName(path)) }
    }

    /// RosettaSciIO's title of `image`, or nil when its metadata has none.
    public func title(of image: VeloxImageInfo) -> String? { titles.byImage[image.id]?.text }

    /// The lazy signal of `image`. Throws `FormatoReadError.unsupportedDataType` for a compound image (Velox's FFT and DPC),
    /// and `.unsupported` for units this port does not convert or a stack with no frame time.
    public func signal(_ image: VeloxImageInfo) throws -> FormatoLazySignal {
        guard let stored = image.elementType, let dataType = FormatoDataType(rawValue: stored.rawValue) else {
            throw FormatoReadError.unsupportedDataType("Velox image \(image.id) (\(image.detectorName))")
        }
        // RosettaSciIO's `_read_image` reads the image's own metadata (column 0) as a dictionary and indexes it; a key it
        // indexes that is missing, or a value `float()` refuses, raises there. The same rules here, on the same JSON, so a
        // value the file states but that does not parse is never replaced by a default (Gate B F2, F3).
        let file = formatoDisplayFileName(reader.path)
        let om = try rawMetadata(image)
        func refuse(_ why: String) -> FormatoReadError { .unsupported("Velox image \(image.id) of \(file): \(why).") }
        guard let binary = om["BinaryResult"] as? [String: Any] else { throw refuse("no BinaryResult") }
        let frames = readsWholeStacks ? image.frameCount : 1
        let stacked = frames > 1
        let shape = stacked ? [frames, image.height, image.width] : [image.height, image.width]
        var axes: [FormatoAxis] = []
        if stacked {
            // `"FrameTime" in om["Scan"]`, else `om["Detectors"][f"Detector-{BinaryResult['DetectorIndex']}"]["ExposureTime"]`.
            guard let scan = om["Scan"] as? [String: Any] else { throw refuse("a stack with no Scan group") }
            let raw: Any?
            if scan.keys.contains("FrameTime") {
                raw = scan["FrameTime"]
            } else {
                guard let index = binary["DetectorIndex"], let key = pythonFormat(index),
                      let detector = (om["Detectors"] as? [String: Any])?["Detector-" + key] as? [String: Any],
                      detector.keys.contains("ExposureTime") else { throw refuse("a stack with no frame time") }
                raw = detector["ExposureTime"]
            }
            guard let frameTime = formatoPythonFloat(raw),
                  let time = FormatoUnits.convertScaleUnits(frameTime, units: "s", factor: 2 * frames) else {
                throw refuse("a frame time that does not convert")
            }
            axes.append(FormatoAxis(name: "Time", size: frames, scale: time.value, offset: 0, units: time.units, navigate: true))
        }
        // `.get("PixelSize", {"height": 1.0, "width": 1.0})`, `.get("Offset", {"x": 0.0, "y": 0.0})`, `.get("PixelUnitX", "")`:
        // the defaults apply only when the key is absent.
        let size = binary.keys.contains("PixelSize") ? binary["PixelSize"] as? [String: Any] : ["width": 1.0, "height": 1.0]
        let offset = binary.keys.contains("Offset") ? binary["Offset"] as? [String: Any] : ["x": 0.0, "y": 0.0]
        guard let size, let offset else { throw refuse("PixelSize or Offset is not a dictionary") }
        guard let unit = binary.keys.contains("PixelUnitX") ? binary["PixelUnitX"] as? String : "" else {
            throw refuse("PixelUnitX is not a string")
        }
        guard let width = formatoPythonFloat(size["width"]), let height = formatoPythonFloat(size["height"]),
              let ox = formatoPythonFloat(offset["x"]), let oy = formatoPythonFloat(offset["y"]) else {
            throw refuse("PixelSize or Offset lacks a value float() reads")
        }
        guard let x = FormatoUnits.convertScaleUnits(width, units: unit, factor: image.width),
              let scaleY = FormatoUnits.convertUnits(height, from: unit, to: x.units),
              let offsetX = FormatoUnits.convertUnits(ox, from: unit, to: x.units),
              let offsetY = FormatoUnits.convertUnits(oy, from: unit, to: x.units) else {
            throw refuse("pixel units '\(unit)' or a pixel size this reader does not convert")
        }
        axes.append(FormatoAxis(name: "y", size: image.height, scale: scaleY, offset: offsetY, units: x.units, navigate: false))
        axes.append(FormatoAxis(name: "x", size: image.width, scale: x.value, offset: offsetX, units: x.units, navigate: false))

        var md = FormatoMetadata()
        let json = "Data/Image/\(image.id)/Metadata[0]."
        let title = titles.byImage[image.id]
        if let title, let text = title.text {
            md.set(FormatoMetadataEntry(key: "General.title", value: .text(text), units: nil,
                                        provenance: FormatoProvenance(file: file, source: title.source,
                                                                      rule: "rsciio emd velox: Operations name, DetectorInformation or display label (registration step 3 §3.2)")))
        }
        md.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(file), units: nil,
                                    provenance: FormatoProvenance(file: file, source: "(the file name)", rule: "rsciio emd: os.path.split(filename)[1]")))
        // The mapping `Optics.AccelerationVoltage -> float(x) / 1e3`, applied when the key is present (a value float()
        // refuses raises in HyperSpy's mapping, and is refused here).
        if let optics = om["Optics"] as? [String: Any], optics.keys.contains("AccelerationVoltage") {
            guard let volts = formatoPythonFloat(optics["AccelerationVoltage"]) else { throw refuse("an AccelerationVoltage float() refuses") }
            md.set(FormatoMetadataEntry(key: "Acquisition_instrument.TEM.beam_energy", value: .number(volts / 1e3), units: "kV",
                                        provenance: FormatoProvenance(file: file, source: json + "Optics.AccelerationVoltage",
                                                                      rule: "rsciio emd velox mapping: float(x) / 1e3")))
        }
        return FormatoLazySignal(title: title?.text ?? "", signalType: "", axes: axes, metadata: md,
                                 array: VeloxImageArray(reader: reader, id: image.id, shape: shape, stacked: stacked, dataType: dataType))
    }
}

extension VeloxImageSignals {
    /// Column 0 of the image's `Metadata`, parsed as RosettaSciIO's `_parse_metadata` does (JSON cut at the first NUL).
    func rawMetadata(_ image: VeloxImageInfo) throws -> [String: Any] {
        let data = try HDF5Serial.run { () throws -> Data in
            let file = try VeloxFile(path: reader.path)
            return try file.readMetadataJSON(group: "/Data/Image/" + image.id, column: 0)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatoReadError.unsupported("Velox image \(image.id): its metadata is not a JSON object.")
        }
        return object
    }
}

/// Python's `f"{x}"` for a JSON integer or string (the detector index of `Detector-{index}`); nil for anything else.
func pythonFormat(_ value: Any) -> String? {
    if let s = value as? String { return s }
    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) { return "\(n.int64Value)" }
    return nil
}

/// One Velox image as a lazy array in its stored type (step 3; Float32 until then): a slab reads the frames it covers, each
/// with one `readImageFrameBytes`.
public nonisolated struct VeloxImageArray: FormatoLazyArray {
    public let reader: VeloxEMDReader
    public let id: String
    public let shape: [Int]
    public let stacked: Bool
    public let dataType: FormatoDataType

    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.checkSlab(start: start, count: count, shape: shape)
        let frameShape = Array(shape.suffix(2))
        let frames = stacked ? Array(start[0]..<(start[0] + count[0])) : [0]
        var out = Data()
        for f in frames {
            let (stored, bytes) = try reader.readImageFrameBytes(id: id, frame: f)
            guard stored.rawValue == dataType.rawValue else {
                throw FormatoReadError.unsupported("Velox image \(id) changed its stored type while being read.")
            }
            let frame = try FormatoArray(dataType: dataType, shape: frameShape, bytes: Data(bytes))
            out.append(try frame.slab(start: Array(start.suffix(2)), count: Array(count.suffix(2))).bytes)
        }
        return try FormatoArray(dataType: dataType, shape: count, bytes: out)
    }
}
