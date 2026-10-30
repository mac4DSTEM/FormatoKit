//
//  VeloxMetadata.swift
//  Role: The acquisition metadata a Velox file stores as JSON: detectors, energy axis, scan, stage, optics.
//        Moved out of VeloxEMDReader.swift unchanged; the format notes are at the top of that file.
//

import Foundation
import FormatoCore

// MARK: - Metadata

nonisolated func jsonDouble(_ value: Any?) -> Double? {
    if let s = value as? String { return Double(s) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

nonisolated func jsonBool(_ value: Any?) -> Bool? {
    if let s = value as? String { return s == "true" ? true : (s == "false" ? false : nil) }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
}

nonisolated func jsonInt(_ value: Any?) -> Int? {
    guard let d = jsonDouble(value) else { return nil }
    return Int(exactly: d.rounded()) ?? nil
}

/// One analytical (X-ray) detector segment: the Super-X is four of these.
public nonisolated struct VeloxDetectorInfo: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let type: String
    public let enabled: Bool?
    public let inserted: Bool?
    /// Radians, as stored.
    public let azimuthRadians: Double?
    public let elevationRadians: Double?
    /// Key `CollectionAngle`, in steradians AS STORED. Whether it is the segment's or the whole detector's differs by
    /// file (0.225, 0.7 and 4.35 seen): use it only as a relative weight among ONE file's segments, never summed to a total.
    public let solidAngleSteradians: Double?
    public let dispersionEV: Double?
    public let offsetEnergyEV: Double?
    /// Column-0 values of the stream's per-frame metadata, recorded as read. SEMANTICS UNVERIFIED for a stream: the meaning
    /// differs by file (cumulative in one, per-frame in another, 0 on the owner's file: formats.md §2.2), so
    /// they are reported and never interpreted or used. In the metadata of the `Data/SpectrumImage` group
    /// (`VeloxEMDReader.spectrumImageMetadata()`) they are the acquisition's totals, in seconds.
    public let realTimeColumn0: Double?
    public let liveTimeColumn0: Double?
    /// `ExposureTime` as stored (s). In RosettaSciIO 049e7d70's public files only camera (`ImagingDetector`) entries
    /// carry it, and not all of them (97 of 153 `Detectors` entries, counted over every Metadata column); the scanning
    /// and analytical entries carry none.
    public let exposureTimeSeconds: Double?

    public var azimuthDegrees: Double? { azimuthRadians.map { $0 * 180 / .pi } }
    public var elevationDegrees: Double? { elevationRadians.map { $0 * 180 / .pi } }
    public var isAnalytical: Bool { type == "AnalyticalDetector" }
}

/// Energy of channel `k` is `offsetKeV + k * scaleKeV`.
public nonisolated struct VeloxEnergyAxis: Equatable, Sendable {
    public let offsetKeV: Double
    public let scaleKeV: Double
    package init(offsetKeV: Double, scaleKeV: Double) {
        self.offsetKeV = offsetKeV; self.scaleKeV = scaleKeV
    }
}

/// The 2x3 affine Velox records per frame when it drift-corrects the SI. RECORDED
/// ONLY: the stream is the raw detector order and this reader applies nothing.
public nonisolated struct VeloxScanTransformation: Equatable, Sendable {
    public let a11: Double, a12: Double, a13: Double
    public let a21: Double, a22: Double, a23: Double
    package init(a11: Double, a12: Double, a13: Double, a21: Double, a22: Double, a23: Double) {
        self.a11 = a11; self.a12 = a12; self.a13 = a13; self.a21 = a21; self.a22 = a22; self.a23 = a23
    }
}

/// One X-ray detector segment's live and real time in seconds, as the file stores them.
public nonisolated struct VeloxSegmentTimes: Equatable, Sendable {
    public let name: String
    public let liveTimeSeconds: Double?
    public let realTimeSeconds: Double?
}

public nonisolated struct VeloxMetadata: Sendable {
    /// The `Detectors` entries in the order the metadata text writes their keys, as RosettaSciIO reads them (0.0.3; until
    /// then sorted by `Detector-<n>` index, the same order on every public and owner file).
    public let detectors: [VeloxDetectorInfo]
    /// The detector whose events the first stream carries (`BinaryResult.Detector`).
    public let binaryResultDetector: String?
    public let binaryResultDetectorIndex: Int?
    public let energyAxis: VeloxEnergyAxis?
    /// `ScanSize`, the full raster, not the spectrum image (that is `ScanSize x ScanArea`).
    public let scanSizeWidth: Int?
    public let scanSizeHeight: Int?
    /// Fractions of the full raster: left, top, right, bottom.
    public let scanArea: (left: Double, top: Double, right: Double, bottom: Double)?
    public let scanRotationRadians: Double?
    public let dwellTimeSeconds: Double?
    public let frameTimeSeconds: Double?
    public let accelerationVoltageVolts: Double?
    public let screenCurrentAmperes: Double?
    public let stageAlphaRadians: Double?
    public let stageBetaRadians: Double?
    public let stagePositionMeters: (x: Double, y: Double, z: Double)?
    /// `Stage.Position.x`, `.y`, `.z` each alone, metres as stored (nil when that coordinate is absent or not a number); RosettaSciIO
    /// maps each coordinate on its own, where `stagePositionMeters` needs all three.
    public let stageXMeters: Double?
    public let stageYMeters: Double?
    public let stageZMeters: Double?
    public let holderType: String?
    public let pixelSizeMeters: (width: Double, height: Double)?
    /// `BinaryResult.PixelUnitX`: the unit of the pixel width and of `offset.x`. (rsciio reads this one for both axes.)
    public let pixelUnit: String?
    /// `BinaryResult.PixelUnitY`: the unit of the pixel height and of `offset.y`. Velox writes it beside the X unit.
    public let pixelUnitY: String?
    /// `BinaryResult.Offset`, as stored: x in `pixelUnit`, y in `pixelUnitY`. nil unless both coordinates parse.
    public let offset: (x: Double, y: Double)?
    public let instrumentModel: String?
    /// `Instrument.InstrumentClass` as stored ("Talos"): what RosettaSciIO 049e7d70 maps as the microscope (`_emd_velox.py:947-950`).
    public let instrumentClass: String?
    public let acquisitionStartUnixTime: Double?
    public let scanTransformation: VeloxScanTransformation?
    // The six below (added in the inherited reader's 0.2.0: five at a consumer's request of 2026-10-13, `stemMagnification` at another of
    // 2026-10-14) are as stored: no unit conversion, no decoding, nil when absent or not a number. A Velox-TIFF
    // reader reads the same names from the same tree in XML. "Not a number": a string is parsed by Swift's `Double(_:)`
    // (no surrounding spaces, no `_`; "0x10" is 16), where RosettaSciIO uses Python's `float`; the two agree on every
    // string of RosettaSciIO 049e7d70's public Velox files (tools/velox-metadata-parity). A string that spells NaN or
    // infinity ("nan", "inf", "Infinity", in any case, signed) parses to a non-finite value in Swift and in Python
    // alike and is returned as that value, not as nil: a reader that needs a finite number checks `isFinite`. A JSON
    // number is taken as is (a JSON `true`/`false` as 1/0, as Python's `float(True)` is 1.0; Velox stores numbers as
    // strings). `exposureTimeSeconds` is a consumer's request (the entry named by `BinaryResult.Detector`) applied with
    // RosettaSciIO's name matching; it is not RosettaSciIO's `DetectorMetadata` (see the field).
    /// `Optics.NominalMagnification`. Absent from every STEM image of RosettaSciIO 049e7d70's public files.
    public let nominalMagnification: Double?
    /// `CustomProperties.StemMagnification.value`: what RosettaSciIO 049e7d70 maps as the magnification
    /// (`_emd_velox.py` `_get_mapping`, `float`). Not a STEM marker: in its public files the camera images carry it too
    /// ("0" on three of the four, "115000" on the fourth) and the EELS spectrometer's entries carry none. For a camera
    /// image the magnification is `nominalMagnification`. The entry's `type` is not consulted, as RosettaSciIO's
    /// `float` does not consult it: the three "0" are typed "bool" and read 0. That 0 is Velox's unset bool, not a
    /// magnification: this field returns it as stored, and a reader should treat a value <= 0 as absent.
    public let stemMagnification: Double?
    /// `Optics.CameraLength`, metres as stored (RosettaSciIO 049e7d70 `_emd_velox.py` maps it ×1e3 to mm, in every mode).
    public let cameraLengthMeters: Double?
    /// `Optics.OperatingMode` as stored. In an `.emd` it is a code ("1", "2" in the public files), not the name a Velox
    /// TIFF's XML holds ("TEM"); no published reader maps the codes, so none is decoded here.
    public let operatingMode: String?
    /// `Optics.ProjectorMode` as stored: a code in an `.emd` as well ("1", "2").
    public let projectorMode: String?
    /// `ExposureTime` (s) of the first `Detectors` entry, in the order the file writes the keys, whose `DetectorName`
    /// equals `BinaryResult.Detector`. The rule is a consumer's request, applied with the matching of RosettaSciIO 049e7d70's
    /// `_get_detector_metadata_dict` (`_emd_velox.py:51-57`): `==`, not the energy axis's `contains`, and the first
    /// entry as the file stores the keys (FormatoKit 0.0.3; until then index order, which differs
    /// only when two entries share a `DetectorName` out of index order; no public file writes its keys out of index order).
    /// This is not RosettaSciIO's `DetectorMetadata`: RosettaSciIO feeds `_get_detector_metadata_dict` another name,
    /// from `Operations` or from `Detectors["Detector-<DetectorIndex>"].DetectorName` (`_emd_velox.py:326-330`,
    /// `447-449`, `464-535`). `BinaryResult.DetectorIndex` is not consulted here: the public '1854 Camera Ceta.emd'
    /// stores index 0, "BF", and its camera, BM-Ceta, is `Detector-8`. nil when that entry has none, when no entry
    /// matches, or when `BinaryResult.Detector` is absent or empty (an entry without `DetectorName` is listed with the
    /// name "" and never matches).
    public let exposureTimeSeconds: Double?

    public var superXDetectors: [VeloxDetectorInfo] { detectors.filter { $0.isAnalytical } }

    /// The live and real time (s) of each X-ray segment that is not disabled, in the file's order, as stored. In the metadata of a
    /// `Data/SpectrumImage` group (`VeloxEMDReader.spectrumImageMetadata()`) these are the totals of the scan. RosettaSciIO maps
    /// neither for a spectrum image.
    public var segmentTimes: [VeloxSegmentTimes] {
        superXDetectors.filter { $0.enabled != false }.map {
            VeloxSegmentTimes(name: $0.name, liveTimeSeconds: $0.liveTimeColumn0, realTimeSeconds: $0.realTimeColumn0)
        }
    }
    /// The live time every enabled segment states (equal to the bit), nil where there is none, one lacks it or they differ.
    public var commonLiveTimeSeconds: Double? { Self.common(segmentTimes.map(\.liveTimeSeconds)) }
    /// The real time every enabled segment states, as `commonLiveTimeSeconds`.
    public var commonRealTimeSeconds: Double? { Self.common(segmentTimes.map(\.realTimeSeconds)) }
    private static func common(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !values.isEmpty, present.count == values.count, let first = present.first, present.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    public var alphaDegrees: Double? { stageAlphaRadians.map { $0 * 180 / .pi } }
    public var betaDegrees: Double? { stageBetaRadians.map { $0 * 180 / .pi } }

    /// The live and real time (s) of each X-ray segment that is not disabled and whose `DetectorName` contains `BinaryResult.Detector`
    /// (the name match of RosettaSciIO's energy axis, `_get_dispersion_offset`), in the file's order, as stored. For a single spectrum
    /// (`VeloxEMDReader.spectrumMetadata()`): RosettaSciIO's public `fei_emd_spectrum.emd` (Velox 4) names "SuperXG2", all four
    /// segments, each stating the same times; a Velox 6 spectrum names one ("SuperXG24"). Unlike the energy axis, every matching
    /// `AnalyticalDetector` entry is kept, not the first. Velox 4 to 13 store them as `Detectors.Detector-<n>.LiveTime` / `.RealTime`; RosettaSciIO maps only
    /// `DetectorMetadata.LiveTime` / `.RealTime`, which no public single spectrum has. Empty when `BinaryResult.Detector` is absent.
    public var binaryResultSegmentTimes: [VeloxSegmentTimes] {
        guard let named = binaryResultDetector else { return [] }
        return superXDetectors.filter { $0.enabled != false && (named.isEmpty || $0.name.contains(named)) }.map {
            VeloxSegmentTimes(name: $0.name, liveTimeSeconds: $0.liveTimeColumn0, realTimeSeconds: $0.realTimeColumn0)
        }
    }

    /// The grid `ScanSize x ScanArea` implies, `(ny, nx)`; nil unless both are
    /// integers to within 1/100 of a pixel (the Velox rasters are exact binary fractions).
    public var derivedGrid: (ny: Int, nx: Int)? {
        guard let w = scanSizeWidth, let h = scanSizeHeight, let a = scanArea else { return nil }
        let nx = Double(w) * (a.right - a.left), ny = Double(h) * (a.bottom - a.top)
        // Bounded before Int(): a ScanSize x ScanArea past 2^31 is no scan grid (it trapped).
        guard abs(nx - nx.rounded()) < 0.01, abs(ny - ny.rounded()) < 0.01, nx >= 1, ny >= 1, nx <= 2_147_483_648, ny <= 2_147_483_648 else { return nil }
        return (Int(ny.rounded()), Int(nx.rounded()))
    }

    public static func parse(jsonData: Data) throws -> VeloxMetadata {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw VeloxEMDError.missingMetadata("a JSON object as metadata")
        }
        return parse(root: root, detectorKeyOrder: detectorKeyOrder(jsonData: jsonData))
    }

    /// The keys of the root object's `Detectors` object in the order the text writes them (RosettaSciIO's `json.loads`
    /// keeps that order; a Swift dictionary does not). A key written twice keeps its first place, as in a Python dict; of
    /// two root `Detectors` the FIRST is listed, the one whose values `JSONSerialization` keeps (Python keeps the last: a
    /// deliberate deviation). Keys are compared decoded (`\u002d` is "-"); a leading
    /// UTF-8 BOM is skipped, as `JSONSerialization` accepts it. nil when there is no root `Detectors` object or the text is
    /// not one JSON object this scan can walk: the caller then keeps index order. Linear in the text; it parses only keys.
    package static func detectorKeyOrder(jsonData: Data) -> [String]? {
        let b = [UInt8](jsonData)
        let n = b.count
        var i = 0
        func whitespace() { while i < n, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 } }
        func skipString() -> Bool {   // at a quote: moves past the closing quote
            guard i < n, b[i] == 0x22 else { return false }
            i += 1
            while i < n {
                if b[i] == 0x5C { i += 2; continue }
                if b[i] == 0x22 { i += 1; return true }
                i += 1
            }
            return false
        }
        func string() -> String? {   // at a quote: the decoded string
            let start = i
            guard skipString() else { return nil }
            let body = b[(start + 1)..<(i - 1)]
            if !body.contains(0x5C) { return String(decoding: body, as: UTF8.self) }
            return (try? JSONSerialization.jsonObject(with: Data(b[start..<i]), options: .fragmentsAllowed)) as? String
        }
        func skipValue() -> Bool {
            guard i < n else { return false }
            switch b[i] {
            case 0x22: return skipString()
            case 0x7B, 0x5B:
                var depth = 0
                while i < n {
                    switch b[i] {
                    case 0x22: guard skipString() else { return false }; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:   // a number or a literal
                let start = i
                while i < n, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
                return i > start
            }
        }
        /// At `{`: the object's keys in written order, first place kept; each value skipped.
        func keys(visit: (String) -> Bool) -> Bool {
            guard i < n, b[i] == 0x7B else { return false }
            i += 1
            whitespace()
            if i < n, b[i] == 0x7D { i += 1; return true }
            while true {
                whitespace()
                guard let key = string() else { return false }
                whitespace()
                guard i < n, b[i] == 0x3A else { return false }
                i += 1
                whitespace()
                guard visit(key) else { return false }
                whitespace()
                guard i < n else { return false }
                if b[i] == 0x2C { i += 1; continue }
                guard b[i] == 0x7D else { return false }
                i += 1
                return true
            }
        }
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        whitespace()
        var order: [String]?
        let walked = keys { key in
            guard key == "Detectors", i < n, b[i] == 0x7B else { return skipValue() }
            var listed: [String] = [], seen = Set<String>()
            let ok = keys { k in
                if seen.insert(k).inserted { listed.append(k) }
                return skipValue()
            }
            if order == nil { order = listed }
            return ok
        }
        return walked ? order : nil
    }

    package static func parse(root: [String: Any], detectorKeyOrder: [String]? = nil) -> VeloxMetadata {
        func dict(_ parent: [String: Any]?, _ key: String) -> [String: Any]? { parent?[key] as? [String: Any] }
        // `Detector-<n>` in the order the text writes the keys, as rsciio's `json.loads` keeps them and its rules take the
        // first match in (since FormatoKit 0.0.3; until then the index order). A Swift dictionary has no
        // order, so `detectorKeyOrder` scans the text; a key it does not list (no text, or a text the scan cannot walk)
        // goes after the listed ones, in index order.
        let written = Dictionary((detectorKeyOrder ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var detectors: [VeloxDetectorInfo] = []
        var place: [Int] = []
        if let all = root["Detectors"] as? [String: Any] {
            for (key, value) in all {
                guard key.hasPrefix("Detector-"), let index = Int(key.dropFirst("Detector-".count)),
                      let d = value as? [String: Any] else { continue }
                place.append(written[key] ?? Int.max)
                detectors.append(VeloxDetectorInfo(
                    index: index, name: d["DetectorName"] as? String ?? "", type: d["DetectorType"] as? String ?? "",
                    enabled: jsonBool(d["Enabled"]), inserted: jsonBool(d["Inserted"]),
                    azimuthRadians: jsonDouble(d["AzimuthAngle"]), elevationRadians: jsonDouble(d["ElevationAngle"]),
                    solidAngleSteradians: jsonDouble(d["CollectionAngle"]),
                    dispersionEV: jsonDouble(d["Dispersion"]), offsetEnergyEV: jsonDouble(d["OffsetEnergy"]),
                    realTimeColumn0: jsonDouble(d["RealTime"]), liveTimeColumn0: jsonDouble(d["LiveTime"]),
                    exposureTimeSeconds: jsonDouble(d["ExposureTime"])))
            }
            detectors = zip(place, detectors).sorted { ($0.0, $0.1.index) < ($1.0, $1.1.index) }.map(\.1)
        }
        let binary = root["BinaryResult"] as? [String: Any]
        let detectorName = binary?["Detector"] as? String

        // rsciio `_get_dispersion_offset`: the first detector (file order) whose name
        // CONTAINS BinaryResult.Detector; dispersion and offset are eV, reported keV.
        // DEVIATION: rsciio silently falls back to scale 1, offset 0 when this fails;
        // here the axis is nil, so a caller cannot mistake a missing calibration for 1 keV/channel.
        var energy: VeloxEnergyAxis?
        if let detectorName {
            for d in detectors where d.name.contains(detectorName) {
                if let dispersion = d.dispersionEV, let offset = d.offsetEnergyEV {
                    energy = VeloxEnergyAxis(offsetKeV: offset / 1000.0, scaleKeV: dispersion / 1000.0)
                }
                break
            }
        }

        let scan = dict(root, "Scan")
        let size = dict(scan, "ScanSize"), area = dict(scan, "ScanArea")
        var areaTuple: (Double, Double, Double, Double)?
        if let l = jsonDouble(area?["left"]), let t = jsonDouble(area?["top"]),
           let r = jsonDouble(area?["right"]), let b = jsonDouble(area?["bottom"]) { areaTuple = (l, t, r, b) }
        let stage = dict(root, "Stage"), position = dict(stage, "Position")
        var positionTuple: (Double, Double, Double)?
        if let x = jsonDouble(position?["x"]), let y = jsonDouble(position?["y"]), let z = jsonDouble(position?["z"]) {
            positionTuple = (x, y, z)
        }
        let pixelSize = dict(binary, "PixelSize")
        var pixelTuple: (Double, Double)?
        if let w = jsonDouble(pixelSize?["width"]), let h = jsonDouble(pixelSize?["height"]) { pixelTuple = (w, h) }
        let offsetDict = dict(binary, "Offset")
        var offsetTuple: (Double, Double)?
        if let x = jsonDouble(offsetDict?["x"]), let y = jsonDouble(offsetDict?["y"]) { offsetTuple = (x, y) }

        // The per-frame drift-correction affine sits in CustomProperties, each
        // entry as {"type": "double", "value": "..."}.
        // The keys are FLAT dotted names: `CustomProperties["Scan.ScanTransformation.A11"]["value"]`
        // (verified on the owner's v9 file, five v4-v6 files, v11 and v13). A nested
        // CustomProperties.Scan.ScanTransformation.A11 is accepted as a fallback.
        var transformation: VeloxScanTransformation?
        let custom = dict(root, "CustomProperties")
        let nested = dict(dict(custom, "Scan"), "ScanTransformation")
        func entry(_ k: String) -> Double? {
            jsonDouble(dict(custom, "Scan.ScanTransformation." + k)?["value"]) ?? jsonDouble(dict(nested, k)?["value"])
        }
        if let a11 = entry("A11"), let a12 = entry("A12"), let a13 = entry("A13"),
           let a21 = entry("A21"), let a22 = entry("A22"), let a23 = entry("A23") {
            transformation = VeloxScanTransformation(a11: a11, a12: a12, a13: a13, a21: a21, a22: a22, a23: a23)
        }

        let optics = dict(root, "Optics")
        // An empty BinaryResult.Detector names no detector (an entry without DetectorName is listed with name "").
        var exposure: Double?
        if let detectorName, !detectorName.isEmpty {
            exposure = detectors.first { $0.name == detectorName }?.exposureTimeSeconds
        }

        return VeloxMetadata(
            detectors: detectors, binaryResultDetector: detectorName, binaryResultDetectorIndex: jsonInt(binary?["DetectorIndex"]), energyAxis: energy,
            scanSizeWidth: jsonInt(size?["width"]), scanSizeHeight: jsonInt(size?["height"]),
            scanArea: areaTuple.map { (left: $0.0, top: $0.1, right: $0.2, bottom: $0.3) },
            scanRotationRadians: jsonDouble(scan?["ScanRotation"]),
            dwellTimeSeconds: jsonDouble(scan?["DwellTime"]), frameTimeSeconds: jsonDouble(scan?["FrameTime"]),
            accelerationVoltageVolts: jsonDouble(optics?["AccelerationVoltage"]),
            screenCurrentAmperes: jsonDouble(optics?["ScreenCurrent"]),
            stageAlphaRadians: jsonDouble(stage?["AlphaTilt"]), stageBetaRadians: jsonDouble(stage?["BetaTilt"]),
            stagePositionMeters: positionTuple.map { (x: $0.0, y: $0.1, z: $0.2) },
            stageXMeters: jsonDouble(position?["x"]), stageYMeters: jsonDouble(position?["y"]), stageZMeters: jsonDouble(position?["z"]),
            holderType: stage?["HolderType"] as? String,
            pixelSizeMeters: pixelTuple.map { (width: $0.0, height: $0.1) },
            pixelUnit: binary?["PixelUnitX"] as? String, pixelUnitY: binary?["PixelUnitY"] as? String,
            offset: offsetTuple.map { (x: $0.0, y: $0.1) },
            instrumentModel: dict(root, "Instrument")?["InstrumentModel"] as? String,
            instrumentClass: dict(root, "Instrument")?["InstrumentClass"] as? String,
            acquisitionStartUnixTime: jsonDouble(dict(dict(root, "Acquisition"), "AcquisitionStartDatetime")?["DateTime"]),
            scanTransformation: transformation,
            nominalMagnification: jsonDouble(optics?["NominalMagnification"]),
            stemMagnification: jsonDouble(dict(custom, "StemMagnification")?["value"]),
            cameraLengthMeters: jsonDouble(optics?["CameraLength"]),
            operatingMode: optics?["OperatingMode"] as? String, projectorMode: optics?["ProjectorMode"] as? String,
            exposureTimeSeconds: exposure)
    }
}
