//
//  VeloxImageSignals.swift
//  Role: A Velox file's images as FormatoCore signals, as RosettaSciIO 049e7d70's `rsciio.emd` reader returns them with
//        `select_type="images"` (docs/registration-step-1.md §3.3, amendments A1 and A4): shape `(frames, y, x)` or `(y, x)`,
//        the Time, y and x axes with Pint's compact units, and the beam energy with its JSON path. Lazy: a slab reads only
//        the frames it covers, one `readImageFrame` each.
//        DATA IS FLOAT32 at step 1 (the moved `readImageFrame`'s documented deviation, exact for 8- and 16-bit integers and
//        float32 storage; the pins name any file where it is not). RosettaSciIO keeps the stored type: step 2.
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

    public init(path: String, cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws {
        reader = VeloxEMDReader(path: path)
        images = try reader.images(cancelled: cancelled)
        readsWholeStacks = HDF5Serial.run { (try? VeloxFile(path: path)).map { !$0.exists("/Data/SpectrumImage") } ?? true }
    }

    /// The lazy signal of `image`. Throws `FormatoReadError.unsupportedDataType` for a compound image (Velox's FFT and DPC),
    /// and `.unsupported` for units this port does not convert or a stack with no frame time.
    public func signal(_ image: VeloxImageInfo) throws -> FormatoLazySignal {
        guard image.elementType != nil else {
            throw FormatoReadError.unsupportedDataType("Velox image \(image.id) (\(image.detectorName))")
        }
        let m = image.metadata
        let frames = readsWholeStacks ? image.frameCount : 1
        let stacked = frames > 1
        let shape = stacked ? [frames, image.height, image.width] : [image.height, image.width]
        var axes: [FormatoAxis] = []
        let file = formatoDisplayFileName(reader.path)
        if stacked {
            // `Scan.FrameTime` when the Scan group states it, else the ExposureTime of `Detector-<BinaryResult.DetectorIndex>`.
            let frameTime = m.frameTimeSeconds ?? m.detectors.first { $0.index == m.binaryResultDetectorIndex }?.exposureTimeSeconds
            guard let frameTime, let time = FormatoUnits.convertScaleUnits(frameTime, units: "s", factor: 2 * frames) else {
                throw FormatoReadError.unsupported("Velox image \(image.id) is a stack of \(frames) frames with no frame time.")
            }
            axes.append(FormatoAxis(name: "Time", size: frames, scale: time.value, offset: 0, units: time.units, navigate: true))
        }
        let size = m.pixelSizeMeters ?? (width: 1.0, height: 1.0)        // `.get("PixelSize", {"height": 1.0, "width": 1.0})`
        let offset = m.offset ?? (x: 0.0, y: 0.0)
        let unit = m.pixelUnit ?? ""
        guard let x = FormatoUnits.convertScaleUnits(size.width, units: unit, factor: image.width),
              let scaleY = FormatoUnits.convertUnits(size.height, from: unit, to: x.units),
              let offsetX = FormatoUnits.convertUnits(offset.x, from: unit, to: x.units),
              let offsetY = FormatoUnits.convertUnits(offset.y, from: unit, to: x.units) else {
            throw FormatoReadError.unsupported("Velox image \(image.id) has pixel units '\(unit)', which this reader does not convert.")
        }
        axes.append(FormatoAxis(name: "y", size: image.height, scale: scaleY, offset: offsetY, units: x.units, navigate: false))
        axes.append(FormatoAxis(name: "x", size: image.width, scale: x.value, offset: offsetX, units: x.units, navigate: false))

        var md = FormatoMetadata()
        let json = "Data/Image/\(image.id)/Metadata[0]."
        md.set(FormatoMetadataEntry(key: "General.title", value: .text(image.detectorName), units: nil,
                                    provenance: FormatoProvenance(file: file, source: json + "BinaryResult.Detector",
                                                                  rule: "the detector name (RosettaSciIO's Operations rule is step 2, amendment A4)")))
        md.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(file), units: nil,
                                    provenance: FormatoProvenance(file: file, source: "(the file name)", rule: "rsciio emd: os.path.split(filename)[1]")))
        if let volts = m.accelerationVoltageVolts {
            md.set(FormatoMetadataEntry(key: "Acquisition_instrument.TEM.beam_energy", value: .number(volts / 1e3), units: "kV",
                                        provenance: FormatoProvenance(file: file, source: json + "Optics.AccelerationVoltage",
                                                                      rule: "rsciio emd velox mapping: float(x) / 1e3")))
        }
        return FormatoLazySignal(title: image.detectorName, signalType: "", axes: axes, metadata: md,
                                 array: VeloxImageArray(reader: reader, id: image.id, shape: shape, stacked: stacked))
    }
}

/// One Velox image as a lazy Float32 array: a slab reads the frames it covers, each with one `readImageFrame`.
public nonisolated struct VeloxImageArray: FormatoLazyArray {
    public let reader: VeloxEMDReader
    public let id: String
    public let shape: [Int]
    public let stacked: Bool
    public var dataType: FormatoDataType { .float32 }

    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.checkSlab(start: start, count: count, shape: shape)
        let frameShape = Array(shape.suffix(2))
        let frames = stacked ? Array(start[0]..<(start[0] + count[0])) : [0]
        var out = Data()
        for f in frames {
            let pixels = try reader.readImageFrame(id: id, frame: f)
            var bytes = Data(capacity: pixels.count * 4)
            for v in pixels { var b = v.bitPattern.littleEndian; withUnsafeBytes(of: &b) { bytes.append(contentsOf: $0) } }
            let frame = try FormatoArray(dataType: .float32, shape: frameShape, bytes: bytes)
            out.append(try frame.slab(start: Array(start.suffix(2)), count: Array(count.suffix(2))).bytes)
        }
        return try FormatoArray(dataType: .float32, shape: count, bytes: out)
    }
}
