//
//  VeloxSpectrumImageSignals.swift
//  Role: A Velox file's spectrum images as FormatoCore signals, as RosettaSciIO 049e7d70's `rsciio.emd.file_reader` returns
//        them with `select_type="spectrum_image"` and `lazy=False`: the EELS spectrum images
//        (`Data/EelsSpectrumImage`, read as stored) then the EDS one(s), decoded from the spectrum streams by RosettaSciIO's
//        `_fill_array_with_stream[_sum_frames]` line for line, every count a `+= 1` in the target type; its six options as
//        parameters with its defaults. Eager, as RosettaSciIO's non-lazy path.
//        The streams are read here through `VeloxFile`, not through the moved `VeloxEMDReader.readSpectrumImage`, whose rules
//        (the ScanSize x ScanArea grid, the CSR store, every stream summed) are the inherited reader's and stay as they are.
//        Every refusal names RosettaSciIO's raise, or the deliberate deviation it is.
//

import Foundation
import FormatoCore
import FormatoHDF5

/// RosettaSciIO's six spectrum-image arguments of `rsciio.emd.file_reader`, with its defaults.
public nonisolated struct VeloxSpectrumImageOptions: Sendable, Equatable {
    /// `first_frame`: the first frame counted (0-based).
    public var firstFrame: Int
    /// `last_frame`: the frame at which counting stops (exclusive); nil is the recorded `endFramePosition`, else the frames
    /// the first stream's markers make. RosettaSciIO's quirk is kept: 0 never stops, so it counts every frame.
    public var lastFrame: Int?
    /// `sum_frames`: one spectrum image summed over the frames (true), or a frame axis first (false).
    public var sumFrames: Bool
    /// `sum_EDS_detectors`: every stream added into the first stream's (true), or one signal per stream (false).
    public var sumEDSDetectors: Bool
    /// `rebin_energy`: channels summed in groups of this many; must divide the bin count.
    public var rebinEnergy: Int
    /// `SI_dtype`: the counts' type; nil is the first stream's `StreamEncoding`. Counts wrap (integers) or stop growing
    /// (float32 at 2^24, float64 at 2^53) exactly as `+= 1` in that type does.
    public var dataType: FormatoDataType?
    /// FormatoKit's own policies: the unit of a pixel, the grid, the array cap, the block size. Not RosettaSciIO
    /// arguments; the default is 0.1.1's behaviour, and a non-default path that changes the result says so in the metadata.
    public var policy: VeloxReadPolicy

    public init(firstFrame: Int = 0, lastFrame: Int? = nil, sumFrames: Bool = true, sumEDSDetectors: Bool = true,
                rebinEnergy: Int = 1, dataType: FormatoDataType? = nil, policy: VeloxReadPolicy = VeloxReadPolicy()) {
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.sumFrames = sumFrames
        self.sumEDSDetectors = sumEDSDetectors
        self.rebinEnergy = rebinEnergy
        self.dataType = dataType
        self.policy = policy
    }
}

public nonisolated struct VeloxSpectrumImageSignals: Sendable {
    public let path: String
    public let options: VeloxSpectrumImageOptions
    /// RosettaSciIO's dictionaries in its order: the EELS spectrum images (name order), then the EDS signal (or one per stream
    /// with `sumEDSDetectors` false). Empty for a file that is not a spectrum-image file, or a pruned one without EELS.
    public let signals: [FormatoSignal]

    /// Reads every spectrum image of the file. Throws `FormatoReadError.unsupported` where RosettaSciIO raises (or a registered
    /// deviation refuses), `VeloxEMDError` where the file cannot be opened or is not Velox, `FormatoCancelled` when cancelled
    /// (polled at every block of a stream).
    public init(path: String, options: VeloxSpectrumImageOptions = VeloxSpectrumImageOptions(),
                cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws {
        self.path = path
        self.options = options
        signals = try withoutActuallyEscaping(cancelled) { cancelled in
            try VeloxSpectrumImageRead(path: path, options: options, cancelled: cancelled).run()
        }
    }
}

/// One read: the open file and the rules below.
private nonisolated struct VeloxSpectrumImageRead {
    let path: String
    let options: VeloxSpectrumImageOptions
    let cancelled: @Sendable () -> Bool
    let file: VeloxFile
    let fileName: String

    init(path: String, options: VeloxSpectrumImageOptions, cancelled: @escaping @Sendable () -> Bool) throws {
        self.path = path
        self.options = options
        self.cancelled = cancelled
        file = try VeloxFile(path: path)
        fileName = formatoDisplayFileName(path)
    }

    /// Where RosettaSciIO raises.
    func raises(_ why: String) -> FormatoReadError {
        .unsupported("Velox spectrum image of \(fileName): \(why) (RosettaSciIO raises).")
    }

    /// Where RosettaSciIO reads and FormatoKit refuses on purpose.
    func deviation(_ why: String) -> FormatoReadError {
        .unsupported("Velox spectrum image of \(fileName): \(why) (refused here on purpose).")
    }

    func isDataset(_ path: String) -> Bool { (try? file.open(path)).map { file.close($0); return true } ?? false }

    func run() throws -> [FormatoSignal] {
        try FormatoCancellation.check(cancelled)
        guard let versionText = file.readString("/Version"),
              let version = (try? JSONSerialization.jsonObject(with: Data(versionText.utf8))) as? [String: Any],
              veloxAcceptsFormat(version["format"] as? String) else { throw VeloxEMDError.notVeloxFile(fileName) }
        // `_check_im_type` on `f.get("Data")`: no Data group raises.
        guard file.exists("/Data"), !isDataset("/Data") else { throw raises("no Data group") }
        let hasImage = file.exists("/Data/Image"), hasSpectrumImage = file.exists("/Data/SpectrumImage")
        let spectrumStreamType = hasImage && hasSpectrumImage

        // §3.2: the four groups, the label map and the first image's title rule (VeloxTitles), then that image's axes.
        let titles = try HDF5Serial.run { try VeloxTitles(file: file, fileName: fileName, firstImageOnly: true) }
        var grid: (ny: Int, nx: Int)?
        if hasImage {
            guard !isDataset("/Data/Image") else { throw raises("Data/Image is a dataset") }
            guard let first = file.children(of: "/Data/Image").first else {
                // `_read_images` reads nothing; the stream path then indexes `spatial_shape`, never set (AttributeError).
                if spectrumStreamType { throw raises("no image under Data/Image gives the spectrum-image grid") }
                return []
            }
            let image = try firstImage(first)
            // `_read_image_data(h5data, read_stack=False)` reads `h5data[:, :, 0]`: IndexError without a frame.
            if hasSpectrumImage, image.frameCount == 0 { throw raises("the first image \(first) has no frame") }
            let images = VeloxImageSignals(reader: VeloxEMDReader(path: path), images: [image],
                                           readsWholeStacks: !hasSpectrumImage, titles: titles, policy: options.policy)
            _ = try images.describe(image)
            grid = (image.height, image.width)
        }
        guard spectrumStreamType, let grid else { return [] }

        // `_read_spectrum_stream`: the EELS spectrum images first, then the EDS stream(s).
        var out: [FormatoSignal] = []
        if file.exists("/Data/EelsSpectrumImage") { out += try eelsSignals() }
        out += try edsSignals(grid: grid)
        return out
    }

    /// The first image as `VeloxImageInfo`: a group with a rank-3 `Data` and a `Metadata` (a deliberate deviation).
    func firstImage(_ id: String) throws -> VeloxImageInfo {
        let group = "/Data/Image/" + id
        guard file.exists(group + "/Data"), file.exists(group + "/Metadata") else { throw raises("the first image \(id) lacks Data or Metadata") }
        let dataset = try file.open(group + "/Data")
        defer { file.close(dataset) }
        guard dataset.dims.count == 3 else { throw deviation("the first image \(id) is not a rank-3 stack") }
        let json = try file.readMetadataJSON(group: group, column: 0)
        guard let metadata = try? VeloxMetadata.parse(jsonData: json) else { throw raises("the metadata of image \(id) is not a JSON object") }
        return VeloxImageInfo(id: id, detectorName: metadata.binaryResultDetector ?? "", height: dataset.dims[0], width: dataset.dims[1],
                              frameCount: dataset.dims[2], elementType: nil, metadata: metadata)
    }

    // MARK: EDS (§3.4 to §3.7)

    func edsSignals(grid: (ny: Int, nx: Int)) throws -> [FormatoSignal] {
        let o = options
        guard o.rebinEnergy >= 1 else { throw raises("rebin_energy \(o.rebinEnergy) (a modulo by zero, or a negative array extent)") }
        if let t = o.dataType, t.components != 1 { throw deviation("SI_dtype \(t.rawValue) is not a numeric type") }

        // §3.4: number_of_frames from the first SpectrumImage child's settings, none on any failure.
        var numberOfFrames: Int?
        if let si = file.children(of: "/Data/SpectrumImage").first,
           let text = file.readString("/Data/SpectrumImage/\(si)/SpectrumImageSettings"),
           let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            switch pythonInt(object["endFramePosition"]) {
            case .value(let n): numberOfFrames = n
            case .tooLarge:
                // Python keeps the integer: as last_frame it overflows numba's int64 (OverflowError) or the array extent
                // (ValueError); an explicit last_frame is compared with it (a negative one raises "cannot be greater").
                let negative = ((object["endFramePosition"] as? NSNumber)?.doubleValue ?? 0) < 0
                    || ((object["endFramePosition"] as? String)?.trimmingCharacters(in: .whitespaces).hasPrefix("-") ?? false)
                if o.lastFrame == nil || negative { throw raises("endFramePosition is beyond a 64-bit integer") }
            case .invalid: break
            }
        }
        var lastFrame = o.lastFrame ?? numberOfFrames
        if let last = o.lastFrame, let n = numberOfFrames, n != 0, last > n {
            throw raises("last_frame \(last) is greater than the \(n) frames of the file")
        }

        guard file.exists("/Data/SpectrumStream") else { return [] }   // pruned
        guard !isDataset("/Data/SpectrumStream") else { throw raises("Data/SpectrumStream is a dataset") }
        let streams = file.children(of: "/Data/SpectrumStream")
        guard !streams.isEmpty else { return [] }                         // pruned (version 11)

        // The grid is the first image's; refused where the stream's ScanSize x ScanArea says otherwise (the policy's
        // `spectrumImageGrid` makes that a choice).
        let head = "/Data/SpectrumStream/" + streams[0]
        let headJSON = try file.readMetadataJSON(group: head, column: 0)
        guard let om = (try? JSONSerialization.jsonObject(with: headJSON)) as? [String: Any] else {
            throw raises("the metadata of stream \(streams[0]) is not a JSON object")
        }
        var chosen = grid
        var gridEntry: FormatoMetadataEntry?
        if let derived = (try? VeloxMetadata.parse(jsonData: headJSON))?.derivedGrid, derived != grid {
            let both = "the first image is \(grid.ny) x \(grid.nx) pixels, the stream's ScanSize x ScanArea \(derived.ny) x \(derived.nx)"
            let source = String(head.dropFirst()) + "/Metadata[0].Scan"
            switch o.policy.spectrumImageGrid {
            case .firstImageChecked:
                throw deviation(both)
            case .firstImage:
                gridEntry = veloxPolicyEntry("grid", value: "\(grid.ny) x \(grid.nx)", file: fileName, source: source,
                                             rule: "spectrumImageGrid = firstImage decodes onto the first image's grid (ny x nx), as RosettaSciIO does, where FormatoKit's default refuses: \(both)")
            case .scanSizeTimesArea:
                chosen = derived
                gridEntry = veloxPolicyEntry("grid", value: "\(derived.ny) x \(derived.nx)", file: fileName, source: source,
                                             rule: "spectrumImageGrid = scanSizeTimesArea decodes onto the stream's ScanSize x ScanArea grid (ny x nx), not the first image's: \(both)")
            }
        }
        let (ny, nx) = chosen
        guard ny >= 1, nx >= 1 else { throw raises("an image of \(ny) x \(nx) pixels") }
        // ny * nx checked before any arithmetic on it; RosettaSciIO's arrays raise there too.
        let (pixels, pixelsOverflow) = ny.multipliedReportingOverflow(by: nx)
        guard !pixelsOverflow else { throw raises("a grid of \(ny) x \(nx) pixels (no array that large)") }

        // Stream 0 (FeiSpectrumStream): bincount, the divisor check, the type.
        let settings0 = try acquisitionSettings(head)
        let bins0 = try binCount(settings0, stream: streams[0])
        let dataType: FormatoDataType
        if let t = o.dataType {
            dataType = t
        } else {
            guard let encoding = settings0["StreamEncoding"] else { throw raises("stream \(streams[0]) has no StreamEncoding") }
            guard let name = encoding as? String, let t = FormatoDataType(rawValue: name), t.components == 1 else {
                throw deviation("StreamEncoding \(encoding) is not one of the ten numeric type names")
            }
            dataType = t
        }
        if lastFrame == nil {
            // `ceil((stream_data == 65535).sum() / (ny * nx))` over stream 0.
            var markers = 0
            try forEachBlock(of: head + "/Data") { block in
                for v in block where v == 65535 { markers += 1 }
                return true
            }
            lastFrame = markers == 0 ? 0 : (markers - 1) / pixels + 1
        }
        let last = lastFrame!
        let first = o.firstFrame
        if !o.sumFrames {
            guard last - first >= 1 else {
                throw deviation("first_frame \(first) and last_frame \(last) leave no frame")
            }
            guard last != 0 else { throw deviation("last_frame 0 never stops with frames not summed") }
        }

        // §3.6: the axes, from stream 0's metadata.
        let (axes, unitsAsWritten) = try edsAxes(om: om, json: headJSON, ny: ny, nx: nx, frames: o.sumFrames ? nil : last - first, bins: bins0)
        try VeloxTitles.checkMetadataDict(om, id: "stream " + streams[0], refuse: { raises($0) })
        var metadata = try edsMetadata(om: om, group: head)
        if let unit = unitsAsWritten {
            metadata.set(VeloxPixelCalibration.entry(unit: unit, file: fileName, source: String(head.dropFirst()) + "/Metadata[0].BinaryResult.PixelUnitX"))
        }
        if let gridEntry { metadata.set(gridEntry) }

        let layout = VeloxStreamFill.Layout(ny: ny, nx: nx, first: first, last: last, rebin: o.rebinEnergy, sumFrames: o.sumFrames)
        var out: [FormatoSignal] = []
        if o.sumEDSDetectors {
            let array = try VeloxCountArray(dataType: dataType, shape: layout.shape(bins: bins0), maximumBytes: o.policy.arrayByteLimit)
            for name in streams {
                try fill(array, stream: "/Data/SpectrumStream/\(name)/Data", layout: layout, bins: bins0)
            }
            out.append(FormatoSignal(title: "EDS", signalType: "EDS_TEM", axes: axes, metadata: metadata, data: try array.finish()))
        } else {
            for (k, name) in streams.enumerated() {
                let group = "/Data/SpectrumStream/" + name
                let bins = k == 0 ? bins0 : try binCount(try acquisitionSettings(group), stream: name)
                // FeiSpectrumStream parses each stream's Metadata.
                if k > 0 { _ = try streamMetadata(group, name: name) }
                guard bins == bins0 else {
                    throw deviation("stream \(name) has \(bins) channels, stream \(streams[0]) \(bins0): the energy axis would not fit")
                }
                let array = try VeloxCountArray(dataType: dataType, shape: layout.shape(bins: bins), maximumBytes: o.policy.arrayByteLimit)
                try fill(array, stream: group + "/Data", layout: layout, bins: bins)
                out.append(FormatoSignal(title: "EDS", signalType: "EDS_TEM", axes: axes, metadata: metadata, data: try array.finish()))
            }
        }
        return out
    }

    func acquisitionSettings(_ group: String) throws -> [String: Any] {
        guard let text = file.readString(group + "/AcquisitionSettings"),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw raises("\(group)/AcquisitionSettings is not one JSON object")
        }
        return object
    }

    func binCount(_ settings: [String: Any], stream: String) throws -> Int {
        guard let bins = pythonIntValue(settings["bincount"]) else { throw raises("stream \(stream): bincount is missing or not an integer") }
        guard bins >= 0 else { throw raises("stream \(stream): bincount \(bins) (a negative array extent)") }
        guard bins % options.rebinEnergy == 0 else { throw raises("rebin_energy \(options.rebinEnergy) does not divide stream \(stream)'s \(bins) channels") }
        return bins
    }

    func streamMetadata(_ group: String, name: String) throws -> [String: Any] {
        let json = try file.readMetadataJSON(group: group, column: 0)
        guard let om = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw raises("the metadata of stream \(name) is not a JSON object")
        }
        return om
    }

    /// The stream's values, `Data[:, 0]`, block by block. Refused unless `Data` is (n, 1) unsigned 16-bit (registered, §3.5).
    func forEachBlock(of dataset: String, _ body: (UnsafeBufferPointer<UInt16>) throws -> Bool) throws {
        guard file.exists(dataset) else { throw raises("\(dataset) is missing") }
        let d = try file.open(dataset)
        defer { file.close(d) }
        guard d.dims.count == 2, d.dims[1] == 1, d.typeClass == hdf5IntegerClass, d.byteSize == 2, !d.isSigned else {
            throw deviation("\(dataset) is not one column of unsigned 16-bit integers")
        }
        let total = d.dims[0]
        let blockValues = min(max(total, 1), options.policy.blockValues)
        let buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: blockValues)
        defer { buffer.deallocate() }
        var at = 0
        while at < total {
            try FormatoCancellation.check(cancelled)
            let n = min(blockValues, total - at)
            try file.readSlab(d, type: file.h5.uint16, start: [at, 0], count: [n, 1], into: buffer)
            if try !body(UnsafeBufferPointer(start: buffer, count: n)) { return }
            at += n
        }
    }

    func fill(_ array: VeloxCountArray, stream: String, layout: VeloxStreamFill.Layout, bins: Int) throws {
        var state = VeloxStreamFill.State()
        try forEachBlock(of: stream) { block in
            try array.fill(block, layout: layout, bins: bins, state: &state)
            return !state.stopped
        }
        if state.outOfRange {
            throw deviation("\(stream) holds a channel beyond its \(bins) channels (RosettaSciIO's jitted fill writes outside the voxel)")
        }
    }

    /// §3.6.
    /// The axes, and the pixel unit as written when `FormatoUnconvertedUnits.keepAsWritten` kept it.
    func edsAxes(om: [String: Any], json: Data, ny: Int, nx: Int, frames: Int?, bins: Int) throws -> (axes: [FormatoAxis], unitsAsWritten: String?) {
        // 1. `_get_detector_information(om)`.
        if let binary = om["BinaryResult"] {
            guard let binary = binary as? [String: Any] else { throw raises("BinaryResult is not an object") }
            if let index = binary["DetectorIndex"], !(index is NSNull) {
                guard let text = pythonFormat(index) else { throw deviation("DetectorIndex is not an integer or string") }
                guard let detectors = om["Detectors"] as? [String: Any], detectors["Detector-" + text] != nil else {
                    throw raises("DetectorIndex names Detector-\(text), which Detectors lacks")
                }
            }
        } else {
            guard let detectors = om["Detectors"] as? [String: Any], detectors["Detector-0"] != nil else {
                throw raises("no BinaryResult and no Detectors.Detector-0")
            }
        }
        // 2. PixelSize, Offset, PixelUnitX.
        guard let binary = om["BinaryResult"] as? [String: Any] else { throw raises("no BinaryResult") }
        guard let size = binary["PixelSize"], let offset = binary["Offset"], let unitValue = binary["PixelUnitX"] else {
            throw raises("BinaryResult lacks PixelSize, Offset or PixelUnitX")
        }
        guard let unit = unitValue as? String else { throw deviation("PixelUnitX is not a string") }
        guard let size = size as? [String: Any], let offset = offset as? [String: Any],
              size["width"] != nil, size["height"] != nil, offset["x"] != nil, offset["y"] != nil else {
            throw raises("PixelSize or Offset lacks a key")
        }
        guard let width = veloxPythonFloat(size["width"]), let height = veloxPythonFloat(size["height"]),
              let ox = veloxPythonFloat(offset["x"]), let oy = veloxPythonFloat(offset["y"]) else {
            throw raises("PixelSize or Offset holds a value float() refuses")
        }
        // 3. x with factor shape[1]: nx when frames are summed, ny when not (RosettaSciIO's index).
        let factor = frames == nil ? nx : ny
        guard let x = VeloxPixelCalibration.make(width: width, height: height, offsetX: ox, offsetY: oy, unit: unit, factor: factor,
                                                 policy: options.policy) else {
            throw deviation("pixel units '\(unit)' or a pixel size this reader does not convert")
        }
        var axes: [FormatoAxis] = []
        // 4. Time.
        if let frames {
            guard let scan = om["Scan"] as? [String: Any], let raw = scan["FrameTime"] else {
                throw deviation("frames not summed and no Scan.FrameTime (RosettaSciIO's Time axis has no scale)")
            }
            guard let frameTime = veloxPythonFloat(raw), let time = FormatoUnits.convertScaleUnits(frameTime, units: "s", factor: frames) else {
                throw raises("Scan.FrameTime does not convert")
            }
            axes.append(FormatoAxis(name: "Time", size: frames, scale: time.value, offset: 0, units: time.units, navigate: true))
        }
        axes.append(FormatoAxis(name: "y", size: ny, scale: x.scaleY, offset: x.offsetY, units: x.units, navigate: true))
        axes.append(FormatoAxis(name: "x", size: nx, scale: x.scaleX, offset: x.offsetX, units: x.units, navigate: true))
        // 5. The energy axis.
        let energy = try dispersionOffset(om: om, json: json)
        axes.append(FormatoAxis(name: "X-ray energy", size: bins / options.rebinEnergy, scale: energy.scale, offset: energy.offset,
                                units: energy.units, navigate: false))
        return (axes, x.keptAsWritten ? unit : nil)
    }

    /// `_get_dispersion_offset`: the first `Detectors` entry, in written order, whose DetectorName contains
    /// `BinaryResult.Detector`; a KeyError anywhere gives (1, 0, no units).
    func dispersionOffset(om: [String: Any], json: Data) throws -> (scale: Double, offset: Double, units: String) {
        let fallback = (scale: 1.0, offset: 0.0, units: "")
        guard let detectorsValue = om["Detectors"] else { return fallback }
        guard let detectors = detectorsValue as? [String: Any] else { throw raises("Detectors is not an object (.items())") }
        let written = VeloxMetadata.detectorKeyOrder(jsonData: json) ?? []
        let order = written.filter { detectors[$0] != nil } + detectors.keys.filter { !written.contains($0) }.sorted()
        for key in order {
            // `om["BinaryResult"]["Detector"]`, evaluated per entry before the entry's own name.
            guard let binary = om["BinaryResult"] as? [String: Any], let wanted = binary["Detector"] else { return fallback }
            guard let entry = detectors[key] as? [String: Any] else { throw raises("Detectors.\(key) is not an object") }
            guard let nameValue = entry["DetectorName"] else { return fallback }
            guard let wantedText = wanted as? String, let name = nameValue as? String else {
                throw deviation("BinaryResult.Detector or Detectors.\(key).DetectorName is not a string")
            }
            guard wantedText.isEmpty || name.range(of: wantedText, options: .literal) != nil else { continue }
            guard let dispersionValue = entry["Dispersion"] else { return fallback }
            guard let dispersion = veloxPythonFloat(dispersionValue) else { throw raises("Detectors.\(key).Dispersion: float() refuses it") }
            let scale = dispersion / 1000.0 * Double(options.rebinEnergy)
            guard let offsetValue = entry["OffsetEnergy"] else { return fallback }
            guard let offset = veloxPythonFloat(offsetValue) else { throw raises("Detectors.\(key).OffsetEnergy: float() refuses it") }
            return (scale, offset / 1000.0, "keV")
        }
        return fallback
    }

    /// §3.7.
    func edsMetadata(om: [String: Any], group: String) throws -> FormatoMetadata {
        var md = FormatoMetadata()
        md.set(FormatoMetadataEntry(key: "General.title", value: .text("EDS"), units: nil,
                                    provenance: FormatoProvenance(file: fileName, source: "(the spectrum stream)",
                                                                  rule: "rsciio emd velox _read_spectrum_stream: detector_name = 'EDS'")))
        md.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(fileName), units: nil,
                                    provenance: FormatoProvenance(file: fileName, source: "(the file name)", rule: "rsciio emd: os.path.split(filename)[1]")))
        // The mapping `Optics.AccelerationVoltage -> float(x) / 1e3`, when the path holds a value (HyperSpy's lookup).
        if let optics = om["Optics"] as? [String: Any], let raw = optics["AccelerationVoltage"], !(raw is NSNull) {
            guard let volts = veloxPythonFloat(raw) else { throw raises("an AccelerationVoltage float() refuses") }
            md.set(FormatoMetadataEntry(key: "Acquisition_instrument.TEM.beam_energy", value: .number(volts / 1e3), units: "kV",
                                        provenance: FormatoProvenance(file: fileName, source: String(group.dropFirst()) + "/Metadata[0].Optics.AccelerationVoltage",
                                                                      rule: "rsciio emd velox mapping: float(x) / 1e3")))
        }
        return md
    }

    // MARK: EELS (§3.8)

    func eelsSignals() throws -> [FormatoSignal] {
        guard !isDataset("/Data/EelsSpectrumImage") else { throw raises("Data/EelsSpectrumImage is a dataset") }
        // The pixel calibration: the first SpectrumImage child's BinaryResult.
        guard let si = file.children(of: "/Data/SpectrumImage").first else { throw raises("no Data/SpectrumImage child for the EELS pixel size") }
        let siGroup = "/Data/SpectrumImage/" + si
        guard let om = (try? JSONSerialization.jsonObject(with: try file.readMetadataJSON(group: siGroup, column: 0))) as? [String: Any] else {
            throw raises("the metadata of \(siGroup) is not a JSON object")
        }
        guard let binary = om["BinaryResult"] as? [String: Any] else { throw raises("\(siGroup) has no BinaryResult object") }
        guard let offset = binary["Offset"] as? [String: Any] else { throw deviation("\(siGroup) BinaryResult.Offset is not an object (len())") }
        let spatialDim = offset.count
        guard let size = binary["PixelSize"] as? [String: Any], let unitValue = binary["PixelUnitX"], size["width"] != nil, offset["x"] != nil else {
            throw raises("\(siGroup) BinaryResult lacks PixelSize.width, PixelUnitX or Offset.x")
        }
        guard let unitX = unitValue as? String else { throw deviation("PixelUnitX is not a string") }
        guard let width = veloxPythonFloat(size["width"]), let ox = veloxPythonFloat(offset["x"]) else {
            throw raises("PixelSize.width or Offset.x: float() refuses it")
        }
        // Policy `unconvertedUnits`: an unhandled unit is kept as written when every unit involved is that one string.
        let x: (value: Double, units: String), offsetX: Double
        var keptUnits = false
        switch FormatoUnits.scaleOutcome(width, units: unitX, factor: 1) {
        case .converted(let value, let units):
            guard let converted = FormatoUnits.convertUnits(ox, from: unitX, to: units) else {
                throw deviation("pixel units '\(unitX)' or a pixel size this reader does not convert")
            }
            (x, offsetX) = ((value, units), converted)
        case .unhandledUnit where options.policy.unconvertedUnits == .keepAsWritten:
            (x, offsetX) = ((width, unitX), ox)
            keptUnits = true
        case .unhandledUnit, .pintRaises:
            throw deviation("pixel units '\(unitX)' or a pixel size this reader does not convert")
        }
        var y: (scale: Double, offset: Double)?
        if spatialDim == 2 {
            guard size["height"] != nil, offset["y"] != nil, let unitYValue = binary["PixelUnitY"] else {
                throw raises("\(siGroup) BinaryResult lacks PixelSize.height, Offset.y or PixelUnitY")
            }
            guard let unitY = unitYValue as? String else { throw deviation("PixelUnitY is not a string") }
            guard let height = veloxPythonFloat(size["height"]), let oy = veloxPythonFloat(offset["y"]) else {
                throw raises("PixelSize.height or Offset.y: float() refuses it")
            }
            if keptUnits {
                guard unitY == unitX else {
                    throw deviation("pixel units '\(unitY)' this reader does not convert to '\(x.units)'")
                }
                y = (height, oy)
            } else {
                guard let sy = FormatoUnits.convertUnits(height, from: unitY, to: x.units),
                      let offY = FormatoUnits.convertUnits(oy, from: unitY, to: x.units) else {
                    throw deviation("pixel units '\(unitY)' this reader does not convert to '\(x.units)'")
                }
                y = (sy, offY)
            }
        }

        var out: [FormatoSignal] = []
        for id in file.children(of: "/Data/EelsSpectrumImage") {
            try FormatoCancellation.check(cancelled)
            let group = "/Data/EelsSpectrumImage/" + id
            let (stored, bytes) = try readWhole(group + "/Data")
            let shape = stored.shape
            var data: FormatoArray
            var axes: [FormatoAxis] = []
            if shape.count == 3 {
                guard let y else { throw raises("EELS \(id) is rank 3 and the pixel calibration has no y (offset_y unbound)") }
                data = try transposed201(FormatoArray(dataType: stored.type, shape: shape, bytes: bytes))
                axes.append(FormatoAxis(name: "y", size: data.shape[0], scale: y.scale, offset: y.offset, units: x.units, navigate: true))
                axes.append(FormatoAxis(name: "x", size: data.shape[1], scale: x.value, offset: offsetX, units: x.units, navigate: true))
            } else if shape.count == 2 {
                data = try FormatoArray(dataType: stored.type, shape: shape, bytes: bytes)
                axes.append(FormatoAxis(name: "x", size: data.shape[0], scale: x.value, offset: offsetX, units: x.units, navigate: true))
            } else {
                throw raises("EELS \(id) is rank \(shape.count) (unexpected dataset dimensionality)")
            }
            let acquisition = try jsonColumn(group + "/AcquisitionMetadata")
            guard let acq = acquisition as? [String: Any], let d = acq["Data"] as? [String: Any],
                  let offsetValue = d["offset"], let scaleValue = d["dispersion"] else {
                throw raises("EELS \(id): AcquisitionMetadata lacks Data.offset or Data.dispersion")
            }
            guard let energyOffset = jsonNumber(offsetValue), let energyScale = jsonNumber(scaleValue) else {
                throw deviation("EELS \(id): Data.offset or Data.dispersion is not a JSON number")
            }
            axes.append(FormatoAxis(name: "Energy-loss", size: data.shape.last!, scale: energyScale, offset: energyOffset, units: "eV", navigate: false))
            _ = try jsonColumn(group + "/Metadata")   // `_parse_metadata(..., bin_id)`: must be JSON
            var md = FormatoMetadata()
            md.set(FormatoMetadataEntry(key: "General.title", value: .text("EELS"), units: nil,
                                        provenance: FormatoProvenance(file: fileName, source: String(group.dropFirst()),
                                                                      rule: "rsciio emd velox _read_eels_spectrum_images: title 'EELS'")))
            md.set(FormatoMetadataEntry(key: "General.original_filename", value: .text(fileName), units: nil,
                                        provenance: FormatoProvenance(file: fileName, source: "(the file name)",
                                                                      rule: "rsciio emd velox: the file opened (its name here)")))
            if keptUnits {
                md.set(VeloxPixelCalibration.entry(unit: unitX, file: fileName, source: String(siGroup.dropFirst()) + "/Metadata[0].BinaryResult.PixelUnitX"))
            }
            out.append(FormatoSignal(title: "EELS", signalType: "EELS", axes: axes, metadata: md, data: data))
        }
        return out
    }

    /// A JSON value Python keeps as a number: an integer or a float, not a bool.
    func jsonNumber(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return formatoPythonFloat(n)   // an NSDecimalNumber from its exact text
    }

    /// `_parse_sub_data_group_metadata` of any (n, k) uint8 dataset: column 0, cut at the first NUL, as JSON.
    func jsonColumn(_ path: String) throws -> Any {
        guard file.exists(path) else { throw raises("\(path) is missing") }
        let d = try file.open(path)
        defer { file.close(d) }
        guard d.dims.count == 2, d.dims[1] >= 1, d.dims[0] <= VeloxFile.maxMetadataBytes else { throw raises("\(path) is not a metadata column") }
        var bytes = [UInt8](repeating: 0, count: d.dims[0])
        try bytes.withUnsafeMutableBytes {
            try file.readSlab(d, type: file.h5.uint8, start: [0, 0], count: [d.dims[0], 1], into: $0.baseAddress!)
        }
        if let end = bytes.firstIndex(of: 0) { bytes.removeSubrange(end...) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed) else { throw raises("\(path) is not JSON") }
        return value
    }

    /// A whole dataset in its stored type (the ten numeric types), little-endian.
    func readWhole(_ path: String) throws -> (stored: (type: FormatoDataType, shape: [Int]), bytes: Data) {
        guard file.exists(path) else { throw raises("\(path) is missing") }
        let d = try file.open(path)
        defer { file.close(d) }
        let h5 = file.h5
        let type: FormatoDataType, memory: hid_t
        switch (d.typeClass == hdf5IntegerClass, d.typeClass == hdf5FloatClass, d.byteSize, d.isSigned) {
        case (true, _, 1, false): (type, memory) = (.uint8, h5.uint8)
        case (true, _, 2, false): (type, memory) = (.uint16, h5.uint16)
        case (true, _, 4, false): (type, memory) = (.uint32, h5.uint32)
        case (true, _, 8, false): (type, memory) = (.uint64, h5.uint64)
        case (true, _, 1, true): (type, memory) = (.int8, h5.int8)
        case (true, _, 2, true): (type, memory) = (.int16, h5.int16)
        case (true, _, 4, true): (type, memory) = (.int32, h5.int32)
        case (true, _, 8, true): (type, memory) = (.int64, h5.int64)
        case (_, true, 4, _): (type, memory) = (.float32, h5.float32)
        case (_, true, 8, _): (type, memory) = (.float64, h5.float64)
        default: throw deviation("\(path) is stored as a type this reader does not read")
        }
        let count = try FormatoArray.elementCount(d.dims)
        let (bytes, overflow) = count.multipliedReportingOverflow(by: type.byteSize)
        guard !overflow, bytes <= options.policy.arrayByteLimit else { throw deviation("\(path) is larger than this reader accepts") }
        var out = Data(count: bytes)
        if count > 0 {
            try out.withUnsafeMutableBytes {
                try file.readSlab(d, type: memory, start: [Int](repeating: 0, count: d.dims.count), count: d.dims, into: $0.baseAddress!)
            }
        }
        return ((type, d.dims), out)
    }

    /// numpy's `transpose(2, 0, 1)`: out[i][j][k] = in[j][k][i].
    func transposed201(_ a: FormatoArray) throws -> FormatoArray {
        let (s0, s1, s2) = (a.shape[0], a.shape[1], a.shape[2])
        let size = a.dataType.byteSize
        var out = Data(count: a.bytes.count)
        a.bytes.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for i in 0..<s2 {
                    for j in 0..<s0 {
                        for k in 0..<s1 {
                            let from = ((j * s1 + k) * s2 + i) * size
                            let to = ((i * s0 + j) * s1 + k) * size
                            dst.baseAddress!.advanced(by: to).copyMemory(from: src.baseAddress!.advanced(by: from), byteCount: size)
                        }
                    }
                }
            }
        }
        return try FormatoArray(dataType: a.dataType, shape: [s2, s0, s1], bytes: out)
    }
}

/// HDF5's type classes (`H5T_INTEGER`, `H5T_FLOAT`), as the moved reader's private constants.
private let hdf5IntegerClass: Int32 = 0
private let hdf5FloatClass: Int32 = 1

/// Python's `int()` and `float()` read any Unicode decimal digit ("٣", "３") as its ASCII digit:
/// the string with those digits mapped, for FormatoCore's ASCII rules. Velox only: TIFF and DM keep their own rule.
nonisolated func veloxPythonDigits(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        if !scalar.isASCII, scalar.properties.numericType == .decimal, let v = scalar.properties.numericValue, v >= 0, v <= 9 {
            out.append(Unicode.Scalar(UInt8(48 + Int(v))))
        } else {
            out.append(scalar)
        }
    }
    return String(out)
}

/// A string as Python's `int()` and `float()` see it: stripped of Unicode whitespace (`str.isspace`, not Foundation's set,
/// which also holds the zero-width space Python keeps), its Unicode digits mapped; nil when anything non-ASCII is left.
nonisolated func veloxPythonNumberText(_ s: String) -> String? {
    let scalars = s.unicodeScalars
    guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
          let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return nil }
    let t = veloxPythonDigits(String(scalars[first...last]))
    return t.unicodeScalars.allSatisfy(\.isASCII) ? t : nil
}

/// Python's `float(x)` on a JSON value, Unicode digits included.
nonisolated func veloxPythonFloat(_ value: Any?) -> Double? {
    if let s = value as? String { return veloxPythonNumberText(s).flatMap { formatoPythonFloat($0) } }
    return formatoPythonFloat(value)
}

/// Python's `int(x)` on a JSON value: an integer, a float truncated, a bool, or a string `int()` reads (Unicode digits and
/// underscores included). `.tooLarge` for an integer Python holds and Int does not (RosettaSciIO then raises downstream).
nonisolated enum PythonInt: Equatable { case value(Int), tooLarge, invalid }

nonisolated func pythonInt(_ value: Any?) -> PythonInt {
    switch value {
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .value(n.boolValue ? 1 : 0) }
        let d = (n as? NSDecimalNumber).flatMap { Double($0.stringValue) } ?? n.doubleValue
        guard d.isFinite else { return .invalid }                   // int(inf) raises OverflowError, int(nan) ValueError
        return Int(exactly: d.rounded(.towardZero)).map(PythonInt.value) ?? .tooLarge
    case let s as String:
        guard let t = veloxPythonNumberText(s) else { return .invalid }
        if let v = formatoPythonInt(t) { return Int(exactly: v).map(PythonInt.value) ?? .tooLarge }
        // formatoPythonInt refuses beyond Int64; an all-digit string is still an integer to Python.
        let body = t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "")
        let digits = body.hasPrefix("-") || body.hasPrefix("+") ? body.dropFirst() : Substring(body)
        return !digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? .tooLarge : .invalid
    default:
        return .invalid
    }
}

nonisolated func pythonIntValue(_ value: Any?) -> Int? {
    if case .value(let v) = pythonInt(value) { return v }
    return nil
}

// MARK: - The fill

/// RosettaSciIO's `_fill_array_with_stream_sum_frames` and `_fill_array_with_stream`, line for line, block by block.
package nonisolated enum VeloxStreamFill {
    package struct Layout: Sendable {
        package let ny: Int, nx: Int, first: Int, last: Int, rebin: Int, sumFrames: Bool
        package init(ny: Int, nx: Int, first: Int, last: Int, rebin: Int, sumFrames: Bool) {
            self.ny = ny; self.nx = nx; self.first = first; self.last = last; self.rebin = rebin; self.sumFrames = sumFrames
        }
        /// `(ny, nx, bins / rebin)`, or `(last - first, ny, nx, bins / rebin)`.
        package func shape(bins: Int) -> [Int] {
            sumFrames ? [ny, nx, bins / rebin] : [last - first, ny, nx, bins / rebin]
        }
    }

    /// The loop's state across blocks.
    package struct State: Sendable {
        var navigation = 0
        var frame = 0
        package var stopped = false
        /// A channel at or beyond the bin count was met where it would be written (deliberate deviation: refused).
        package var outOfRange = false
        package init() {}
    }

    /// Adds `block`'s events into `counts` (C order, the layout's shape), each one `increment`ed in place.
    @inline(__always)
    static func fill<T>(_ block: UnsafeBufferPointer<UInt16>, layout: Layout, bins: Int, counts: UnsafeMutablePointer<T>,
                        state: inout State, increment: (inout T) -> Void) {
        guard !state.stopped, !state.outOfRange else { return }
        let frameSize = layout.ny * layout.nx
        let outBins = bins / layout.rebin
        let frames = layout.last - layout.first
        var navigation = state.navigation, frame = state.frame
        for value in block {
            if navigation == frameSize {
                navigation = 0
                frame += 1
                if frame == layout.last { state.stopped = true; break }
            }
            if value != 65535 {
                if layout.first <= frame {
                    let channel = Int(value)
                    guard channel < bins else { state.outOfRange = true; break }
                    let index: Int
                    if layout.sumFrames {
                        index = navigation * outBins + channel / layout.rebin
                    } else {
                        let f = frame - layout.first
                        guard f < frames else { state.outOfRange = true; break }
                        index = (f * frameSize + navigation) * outBins + channel / layout.rebin
                    }
                    increment(&counts[index])
                }
            } else {
                navigation += 1
            }
        }
        state.navigation = navigation
        state.frame = frame
    }
}

/// The counts of one spectrum image in its target type, zeroed, filled in place; `finish()` hands its bytes to a FormatoArray
/// without a copy (freed here if never finished).
nonisolated final class VeloxCountArray {
    /// The default limit on one array: the machine's memory (RosettaSciIO's `np.zeros` raises beyond what it can map).
    static let physicalMemoryBytes = VeloxReadPolicy().arrayByteLimit

    let dataType: FormatoDataType
    let shape: [Int]
    private var storage: UnsafeMutableRawPointer?
    private let byteCount: Int

    /// `maximumBytes`: the policy's limit on one array.
    init(dataType: FormatoDataType, shape: [Int], maximumBytes: Int = VeloxCountArray.physicalMemoryBytes) throws {
        let count = try FormatoArray.elementCount(shape)
        let (bytes, overflow) = count.multipliedReportingOverflow(by: dataType.byteSize)
        guard !overflow, bytes <= maximumBytes else {
            let limit = maximumBytes == Self.physicalMemoryBytes ? "this Mac's memory" : "the \(maximumBytes) bytes the policy allows"
            throw FormatoReadError.unsupported("A spectrum image of shape \(shape) in \(dataType.rawValue) is larger than \(limit).")
        }
        self.dataType = dataType
        self.shape = shape
        byteCount = bytes
        storage = calloc(max(bytes, 1), 1)   // zero pages are mapped lazily: only voxels that receive counts are touched
        guard storage != nil else { throw FormatoReadError.unsupported("Could not allocate \(bytes) bytes for a spectrum image.") }
    }

    deinit { if let storage { free(storage) } }

    func fill(_ block: UnsafeBufferPointer<UInt16>, layout: VeloxStreamFill.Layout, bins: Int, state: inout VeloxStreamFill.State) throws {
        guard let storage else { return }
        func run<T>(_: T.Type, _ increment: (inout T) -> Void) {
            VeloxStreamFill.fill(block, layout: layout, bins: bins, counts: storage.assumingMemoryBound(to: T.self), state: &state, increment: increment)
        }
        // `+= 1` in the target type: integers wrap, floats round (and so stop at 2^24 and 2^53).
        switch dataType {
        case .uint8: run(UInt8.self) { $0 &+= 1 }
        case .uint16: run(UInt16.self) { $0 &+= 1 }
        case .uint32: run(UInt32.self) { $0 &+= 1 }
        case .uint64: run(UInt64.self) { $0 &+= 1 }
        case .int8: run(Int8.self) { $0 &+= 1 }
        case .int16: run(Int16.self) { $0 &+= 1 }
        case .int32: run(Int32.self) { $0 &+= 1 }
        case .int64: run(Int64.self) { $0 &+= 1 }
        case .float32: run(Float.self) { $0 += 1 }
        case .float64: run(Double.self) { $0 += 1 }
        case .rgb8, .rgba8, .rgb16, .rgba16: return
        }
    }

    /// The array; the storage now belongs to it (little-endian: native on the platforms this package builds for).
    func finish() throws -> FormatoArray {
        guard let storage else { throw FormatoReadError.unsupported("A spectrum image was finished twice.") }
        self.storage = nil
        let data = Data(bytesNoCopy: storage, count: byteCount, deallocator: .free)
        return try FormatoArray(dataType: dataType, shape: shape, bytes: data)
    }
}

/// RosettaSciIO's `stream_to_array` on values in memory: the kernel pins and the planted literals.
package nonisolated func veloxStreamToArray(_ values: [UInt16], ny: Int, nx: Int, channels: Int, firstFrame: Int, lastFrame: Int,
                                            rebinEnergy: Int, sumFrames: Bool, dataType: FormatoDataType) throws -> FormatoArray {
    let layout = VeloxStreamFill.Layout(ny: ny, nx: nx, first: firstFrame, last: lastFrame, rebin: rebinEnergy, sumFrames: sumFrames)
    let array = try VeloxCountArray(dataType: dataType, shape: layout.shape(bins: channels))
    var state = VeloxStreamFill.State()
    try values.withUnsafeBufferPointer { try array.fill($0, layout: layout, bins: channels, state: &state) }
    if state.outOfRange { throw FormatoReadError.unsupported("A channel beyond the \(channels) channels.") }
    return try array.finish()
}
