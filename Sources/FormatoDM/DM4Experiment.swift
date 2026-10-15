//
//  DM4Experiment.swift
//  Role: List every image object of a GMS `.dm4` ("one experiment") and read a
//        2D one (the survey, or a scan-grid HAADF) as Float32. A GMS STEM SI
//        file holds a thumbnail, a survey image with the scan rectangle on it,
//        optionally a scan-grid ADF/HAADF, the 4D "Diffraction SI", and for
//        EELS/EDS runs 3D spectrum images. `DM4Reader` returns only the 4D
//        object and drops the rest; this reads the rest.
//
//  HEADER READS ONLY, on every volume. The tag walk reads the file through a
//  `FileHandle` in small bounded windows and SEEKS past every `Data` blob (a 4D
//  blob is up to 29 GB), so a listing never reads blob bytes, even on a network
//  volume where `DM4Reader` falls back to reading the whole file. Only a
//  requested 2D image reads its own bytes.
//
//  Tag paths: docs/archive/v5/edx-research-2026-10-05/reports/gms.md §2.
//  PUBLIC (access only, at a consumer's request of 2026-10-13): `readImage`, `tagTree`, `DM4Image`,
//  `DM4Axis` and the six `DM4ImageObject` fields a consumer reads, so it reads DM through this module and keeps no
//  copy. Access only: no line of the walk or the decode changed.
//  An EELS spectrum image is decoded by `readEELSSpectrumImage` (EELS slice 1b, public): the same walk, the
//  same role rule, the same channel-block read as the EDS one, and E0 / alpha / beta from the tags RosettaSciIO maps.
//  An EDS spectrum image is decoded by `readEDSSpectrumImage` (v5.0 WP2 R2): the
//  only object it reads whole, in channel blocks, never the 4D blob. No real GMS
//  4D+EDS file existed when this was written; the layout is the simulator's guess
//  (`docs/archive/v5/4d-edx-file-structure-2026-10-05.md` §4a) and the first real
//  file corrects it.
//

import Foundation
import FormatoCore

/// What an image object of a GMS file is for.
public nonisolated enum DM4ImageRole: String, Sendable, Equatable {
    /// The RGBA preview image GMS stores first (data type 23).
    case thumbnail
    /// The larger-field ADF/HAADF image the scan rectangle is drawn on.
    case survey
    /// A DigiScan signal on the scan grid (ADF/HAADF).
    case scanSignal
    case eels
    /// The 4D "Diffraction SI".
    case diffraction
    case eds
    case unknown
}

/// Which rule decided an object's role, so a guess is never mistaken for a label.
package nonisolated enum DM4RoleSource: String, Sendable, Equatable {
    /// An `Experiment keywords.N.Label` in the known set.
    case label
    /// The root `Thumbnails.N.ImageIndex` list (as RosettaSciIO does).
    case thumbnailIndex
    /// Fallback: data type 23 with no recognised label.
    case rgbaFallback
    /// `Meta Data.Signal` = "X-ray".
    case signalTag
    /// Fallback: the object's free-text NAME, used when the label is absent OR unrecognised.
    case nameHeuristic
    case none
}

/// One calibrated axis: the value at pixel `i` is `(i - origin) * scale` (gms.md §2d).
public nonisolated struct DM4Axis: Sendable, Equatable {
    public let origin: Double
    public let scale: Double
    public let units: String
    package init(origin: Double, scale: Double, units: String) {
        self.origin = origin; self.scale = scale; self.units = units
    }
}

/// `Spectrum Image Rect`: the scan rectangle, in pixels of the survey image.
package nonisolated struct DM4SpectrumImageRect: Sendable, Equatable {
    package let top: Double
    package let left: Double
    package let bottom: Double
    package let right: Double
    package var width: Double { right - left }
    package var height: Double { bottom - top }
}

/// `EDS.*` tags, each present only if the file wrote it (gms.md §2d; names are
/// from RosettaSciIO's mapping of real GMS EDS files, unverified here).
public nonisolated struct DM4EDSDetectorTags: Sendable, Equatable {
    public let azimuthDegrees: Double?
    public let elevationDegrees: Double?
    public let solidAngle: Double?
    public let liveTime: Double?
    public let realTime: Double?
    package var isEmpty: Bool {
        azimuthDegrees == nil && elevationDegrees == nil && solidAngle == nil
            && liveTime == nil && realTime == nil
    }
}

public nonisolated struct DM4ImageObject: Sendable, Equatable {
    /// One-based position in `ImageList` (the `N` of `ImageList.N`).
    public let index: Int
    public let name: String
    public let role: DM4ImageRole
    package let roleSource: DM4RoleSource
    /// The first `Meta Data.Experiment keywords.N.Label` in the known set, nil if none.
    package let label: String?
    /// The first `Meta Data.Experiment keywords.N.Experiment ID`; equal across the objects of one run.
    public let experimentID: String?
    /// Gatan `ImageData.DataType` code.
    package let dataType: Int
    /// `ImageData.Dimensions` in file order, FASTEST FIRST (DM order: x, y, then slower).
    public let dimensions: [Int]
    /// One per dimension, same order; nil where the file wrote no calibration.
    public let axes: [DM4Axis?]
    /// `SI.Acquisition.Survey Image.Spectrum Image Rect` (top, left, bottom, right in SURVEY pixels).
    /// Written on the SI objects registered to the survey (scan-grid image, EELS/EDS/Diffraction SI),
    /// not on the survey itself.
    package let spectrumImageRect: DM4SpectrumImageRect?
    /// `SI.Acquisition.Survey Image.Unique Image ID` (four uint32): the survey an SI object is registered to.
    package let surveyImageID: [UInt32]?
    /// The object's own `ImageList.N.UniqueID` (four uint32), what a `surveyImageID` points at
    /// (falls back to the survey's `ImageTags.Survey Image.Unique Image ID`).
    package let uniqueID: [UInt32]?
    public let eds: DM4EDSDetectorTags?
    /// `ImageTags.Microscope Info.Voltage` as stored (volts in GMS), nil when the object carries none.
    public let voltage: Double?
    /// `ImageTags.Meta Data.Data Order Swapped` (1 on the owner's 4D cubes, meaning unknown for an SI), nil when absent.
    public let dataOrderSwapped: Bool?
    /// `ImageTags.Meta Data.Format` verbatim ("Spectrum image", "Image", "Diffraction image" as GMS writes it); not used for `role()`.
    public let metaDataFormat: String?
    /// `ImageTags.Meta Data.Signal` verbatim ("X-ray", "EELS", ...); `role()` reads its own copy, this is for consumers.
    package let metaDataSignal: String?
    /// Every scalar number under this object's `ImageTags`, prefix removed (`Microscope Info.Voltage`, `EDS.Live time`).
    /// Numeric arrays and structs are not in it. Added 2026-10-12 for consumers that show an object's metadata.
    public let imageTagNumbers: [String: Double]
    /// Every string under this object's `ImageTags`, prefix removed (`DataBar.Acquisition Date`): the type-18 strings
    /// and the short UTF-16 arrays (units, dates). Each is cut at the walk's kept length (4 KiB by default, `DMReadOptions.maximumStringBytes`),
    /// so a longer UTF-16 string is absent and a longer type-18 string is cut. Added 2026-10-12.
    public let imageTagStrings: [String: String]
    /// Where the pixel blob starts in the file and how many bytes the tag declares.
    public let dataOffset: Int
    public let dataByteCount: Int

    package var dataTypeName: String { DM4Experiment.dataTypeName(dataType) }
    /// Saturates at `Int.max` rather than trapping on absurd tag dimensions.
    package var elementCount: Int {
        dimensions.reduce(1) { acc, d in
            let (p, o) = acc.multipliedReportingOverflow(by: d)
            return o ? Int.max : p
        }
    }
}

/// A decoded 2D image object.
public nonisolated struct DM4Image: Sendable, Equatable {
    public let object: DM4ImageObject
    public let width: Int
    public let height: Int
    /// Row-major, `width` fastest, converted to Float32.
    public let pixels: [Float]
    public let xAxis: DM4Axis?
    public let yAxis: DM4Axis?
}

/// A decoded EDS spectrum image: counts in `(ny, nx, channels)` row-major (the layout `DenseSpectrumImage` takes),
/// and the energy axis exactly as the file states it (units NOT converted: the caller reads `units`).
public nonisolated struct DM4EDSSpectrumImage: Sendable, Equatable {
    package let object: DM4ImageObject
    public let nx: Int
    public let ny: Int
    public let channels: Int
    public let counts: [UInt32]
    public let energyAxis: DM4Axis
}

/// A decoded EELS spectrum image (a 3D object of role `.eels`: x, y, energy loss), read by
/// `DM4Experiment.readEELSSpectrumImage`. The counts are AS STORED in the file, converted to Float32: no dark-reference,
/// gain, offset or `Calibrations.Brightness` (electrons per count) is applied, and RosettaSciIO applies none either.
/// E0 and the two angles are read from `ImageTags` (from `ImageTags.source.Tags at creation` on a stack-builder file, where
/// RosettaSciIO looks): see `DM4Experiment.readEELSSpectrumImage`.
public nonisolated struct DM4EELSSpectrumImage: Sendable, Equatable {
    /// The listed object this was decoded from (its `index`, `name`, `role`, `imageTagNumbers`, ...).
    public let object: DM4ImageObject
    /// `ImageData.Dimensions` entry 1 (the fastest in the file): pixels along x.
    public let nx: Int
    /// `ImageData.Dimensions` entry 2: pixels along y.
    public let ny: Int
    /// `ImageData.Dimensions` entry 3 (the slowest in the file): energy channels per pixel.
    public let channels: Int
    /// Row-major `(y, x, channel)`: the spectrum of pixel `(x, y)` is `counts[(y * nx + x) * channels ..< (y * nx + x + 1) * channels]`.
    /// The file stores `[channel][y][x]` (x fastest, energy slowest); this is that cube transposed so one pixel's spectrum
    /// is contiguous. Values as stored, converted to Float32 (an integer above 2^24 or a Float64 is rounded to the nearest Float).
    public let counts: [Float]
    /// `ImageData.Calibrations.Dimension.3` (`Origin`, `Scale`, `Units`), units "eV": channel `c` is at `(c - origin) * scale` eV.
    /// RosettaSciIO's `offset` is `-origin * scale`.
    public let energyAxis: DM4Axis
    /// `ImageTags.Microscope Info.Voltage` (volts in GMS) / 1000, as RosettaSciIO maps it to `beam_energy`
    /// (`_api.py:921-924`, `lambda x: x / 1e3`); nil when the tag is absent. As stored: a 0 V tag is 0 keV. RosettaSciIO files
    /// it under `SEM` instead of `TEM` when the illumination mode says SEM; this reads the tag either way.
    public let beamEnergyKeV: Double?
    /// `ImageTags.EELS.Experimental Conditions.Convergence semi-angle (mrad)` as stored (RosettaSciIO `_api.py:1045-1048`,
    /// `Acquisition_instrument.TEM.convergence_angle`); nil when absent.
    public let convergenceSemiAngleMrad: Double?
    /// `ImageTags.EELS.Experimental Conditions.Collection semi-angle (mrad)` as stored (RosettaSciIO `_api.py:1040-1044`,
    /// `Acquisition_instrument.TEM.Detector.EELS.collection_angle`); nil when absent.
    public let collectionSemiAngleMrad: Double?
}

public nonisolated enum DM4Experiment {

    // MARK: Entry points

    /// Lists every image object of the file at `path`, in `ImageList` order.
    public static func list(path: String) throws -> [DM4ImageObject] {
        try Walk(source: try Source.file(path)).objects
    }

    /// As `list(path:)`, with the walk's `options`.
    public static func list(path: String, options: DMReadOptions) throws -> [DM4ImageObject] {
        try Walk(source: try Source.file(path), maximumStringBytes: options.maximumStringBytes).objects
    }

    /// Reads image object `index` (one-based, `DM4ImageObject.index`) as Float32.
    /// Reads only that object's own bytes.
    public static func readImage(path: String, index: Int) throws -> DM4Image {
        try readImage(source: try Source.file(path), index: index)
    }

    public static func list(data: Data) throws -> [DM4ImageObject] {
        try Walk(source: Source.data(data)).objects
    }

    /// As `list(data:)`, with the walk's `options`.
    public static func list(data: Data, options: DMReadOptions) throws -> [DM4ImageObject] {
        try Walk(source: Source.data(data), maximumStringBytes: options.maximumStringBytes).objects
    }

    /// The tag tree of a BARE DM tag stream: a complete DM3/DM4 stream whose root group is an image's `ImageTags` themselves
    /// (no `ImageList`), as DigitalMicrograph stores it in private TIFF tag 65027. `list(data:)` returns [] on such a stream.
    /// The same walk as `list(data:)` (one parser), its two maps returned as `imageTagNumbers` / `imageTagStrings` hold
    /// them: scalar numbers (types 2-12), and type-18 strings plus short UTF-16 arrays (cut at 4 KiB).
    /// KEYS are relative to the stream's root, with NO prefix and no leading dot: `Microscope Info.Voltage`,
    /// `DataBar.Acquisition Date`; an unnamed group is its one-based position (`Items.1.Label`).
    /// Bounds-checked as `list(data:)`: a cut or malformed stream throws `DM4Error.truncated` (or `.cannotOpen`).
    public static func tagTree(data: Data) throws -> (numbers: [String: Double], strings: [String: String]) {
        let walk = try Walk(source: Source.data(data))
        return (walk.numbers, walk.strings)
    }

    /// As `tagTree(data:)`, with the walk's `options`.
    public static func tagTree(data: Data, options: DMReadOptions) throws -> (numbers: [String: Double], strings: [String: String]) {
        let walk = try Walk(source: Source.data(data), maximumStringBytes: options.maximumStringBytes)
        return (walk.numbers, walk.strings)
    }

    public static func readImage(data: Data, index: Int) throws -> DM4Image {
        try readImage(source: Source.data(data), index: index)
    }

    /// How many bytes a listing of the file at `path` fetched from disk. A test hook for
    /// "listing never reads the blob": it must stay far below the file size.
    package static func bytesFetchedToList(path: String) throws -> Int {
        let source = try Source.file(path)
        _ = try Walk(source: source).objects
        return source.counter.bytes
    }

    private static func readImage(source: Source, index: Int) throws -> DM4Image {
        guard let object = try Walk(source: source).objects.first(where: { $0.index == index }) else {
            throw DM4Error.cannotOpen("This DM file has no image object \(index).")
        }
        return try decode2D(object, source: source)
    }

    /// Decodes the EDS spectrum image `index` (one-based) of the file at `path`. Throws `DM4Error.cannotOpen` with the
    /// reason for everything it refuses: see `decodeEDS`.
    public static func readEDSSpectrumImage(path: String, index: Int) throws -> DM4EDSSpectrumImage {
        try readEDSSpectrumImage(source: try Source.file(path), index: index)
    }

    public static func readEDSSpectrumImage(data: Data, index: Int) throws -> DM4EDSSpectrumImage {
        try readEDSSpectrumImage(source: Source.data(data), index: index)
    }

    private static func readEDSSpectrumImage(source: Source, index: Int) throws -> DM4EDSSpectrumImage {
        guard let object = try Walk(source: source).objects.first(where: { $0.index == index }) else {
            throw DM4Error.cannotOpen("This DM file has no image object \(index).")
        }
        return try decodeEDS(object, source: source)
    }

    /// Decodes the EELS spectrum image `index` (one-based, `DM4ImageObject.index`) of the file at `path`: a 3D object of role
    /// `.eels` whose dimensions are `[x, y, energy]` (fastest first) and whose third axis is calibrated in "eV". Reads only
    /// that object's own bytes, in blocks of 32 channels. Throws `DM4Error.cannotOpen` with the reason for everything it
    /// refuses (no such object, not role `.eels`, not 3D, `Data Order Swapped` set, no energy calibration, energy axis not in
    /// eV, larger than a quarter of physical memory as Float32), `.unsupportedDataType(code)` for a pixel type other than
    /// int8/16/32, uint8/16/32, float32/64, and `.truncated` when the file ends before the object's data does.
    public static func readEELSSpectrumImage(path: String, index: Int) throws -> DM4EELSSpectrumImage {
        try readEELSSpectrumImage(source: try Source.file(path), index: index)
    }

    /// As `readEELSSpectrumImage(path:index:)`, from the bytes of a `.dm4` already in memory.
    public static func readEELSSpectrumImage(data: Data, index: Int) throws -> DM4EELSSpectrumImage {
        try readEELSSpectrumImage(source: Source.data(data), index: index)
    }

    private static func readEELSSpectrumImage(source: Source, index: Int) throws -> DM4EELSSpectrumImage {
        guard let object = try Walk(source: source).objects.first(where: { $0.index == index }) else {
            throw DM4Error.cannotOpen("This DM file has no image object \(index).")
        }
        return try decodeEELS(object, source: source)
    }

    /// The distinct Experiment IDs, in first-seen order.
    package static func experimentIDs(in objects: [DM4ImageObject]) -> [String] {
        var seen = Set<String>(), out = [String]()
        for id in objects.compactMap(\.experimentID) where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// The survey object an SI object is registered to: the one whose own ID equals its
    /// `surveyImageID`. An explicit ID that matches nothing resolves to nil (no guess);
    /// only when the object names no ID does the run's single survey stand in.
    package static func survey(for object: DM4ImageObject, in objects: [DM4ImageObject]) -> DM4ImageObject? {
        let surveys = objects.filter { $0.role == .survey && $0.index != object.index }
        if let want = object.surveyImageID { return surveys.first(where: { $0.uniqueID == want }) }
        let sameRun = surveys.filter { $0.experimentID == object.experimentID }
        return sameRun.count == 1 ? sameRun.first : nil
    }

    package static func objects(inExperiment id: String, of objects: [DM4ImageObject]) -> [DM4ImageObject] {
        objects.filter { $0.experimentID == id }
    }

    package static func dataTypeName(_ code: Int) -> String {
        switch code {
        case 1: return "int16"; case 2: return "float32"; case 6: return "uint8"
        case 7: return "int32"; case 9: return "int8"; case 10: return "uint16"
        case 11: return "uint32"; case 12: return "float64"; case 23: return "rgba8"
        default: return "dm-type-\(code)"
        }
    }

    // MARK: Byte source

    /// Where bytes come from: a file read through `FileHandle` (seek + bounded reads, on any
    /// volume), or a `Data` for tests. `fetch` returns exactly `count` bytes or throws.
    private struct Source {
        let size: Int
        let fetch: (_ offset: Int, _ count: Int) throws -> [UInt8]
        let counter: Counter

        final class Counter: @unchecked Sendable { var bytes = 0 }

        // DEVIATION from DM4Reader: no mapping and no MappingLiveness latch. A one-shot header
        // walk through a descriptor: a vanished disk surfaces as a thrown read error, and a
        // network volume is never read whole (DM4Reader's `.mappedIfSafe` fallback does that).
        static func file(_ path: String) throws -> Source {
            let handle: FileHandle
            let size: Int
            do {
                handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                size = Int(try handle.seekToEnd())
            } catch {
                throw DM4Error.cannotOpen("\(formatoDisplayFileName(path)) — \(error.localizedDescription)")
            }
            let counter = Counter()
            let name = formatoDisplayFileName(path)
            return Source(size: size, fetch: { offset, count in
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    let got = try handle.read(upToCount: count) ?? Data()
                    guard got.count == count else { throw DM4Error.truncated }
                    counter.bytes += count
                    return [UInt8](got)
                } catch let error as DM4Error {
                    throw error
                } catch {
                    throw DM4Error.cannotOpen("\(name) — \(error.localizedDescription)")
                }
            }, counter: counter)
        }

        static func data(_ data: Data) -> Source {
            let counter = Counter()
            return Source(size: data.count, fetch: { offset, count in
                guard offset >= 0, count >= 0, count <= data.count - offset else { throw DM4Error.truncated }
                counter.bytes += count
                return [UInt8](data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
            }, counter: counter)
        }
    }

    // MARK: Decode one 2D image

    private static let maxImageBytes = 1 << 30

    private static func decode2D(_ object: DM4ImageObject, source: Source) throws -> DM4Image {
        let big = object.dimensions.filter { $0 > 1 }
        // Singleton dimensions are dropped, so a [w, h, 1] stack reads as 2D.
        guard big.count <= 2, object.dimensions.count >= 2 else {
            throw DM4Error.cannotOpen(
                "Image object \(object.index) (\(object.name)) has dimensions \(object.dimensions); only a 2D image is read here.")
        }
        guard let size = pixelSize(object.dataType) else {
            throw DM4Error.unsupportedDataType(object.dataType)
        }
        // File order is fastest first: x is the first non-singleton dimension.
        let nonSingleton = object.dimensions.enumerated().filter { $0.element > 1 }
        let width = nonSingleton.first?.element ?? 1
        let height = nonSingleton.count > 1 ? nonSingleton[1].element : 1
        let (count, o1) = width.multipliedReportingOverflow(by: height)
        let (bytes, o2) = count.multipliedReportingOverflow(by: size)
        let (end, o3) = object.dataOffset.addingReportingOverflow(bytes)
        guard !(o1 || o2 || o3), object.dataOffset >= 0, end <= source.size,
              object.dataByteCount == bytes else {
            throw DM4Error.truncated
        }
        guard bytes <= maxImageBytes else {
            throw DM4Error.cannotOpen("Image object \(object.index) is \(bytes) bytes; refusing to read a 2D image that large.")
        }
        let raw = try source.fetch(object.dataOffset, bytes)       // this object's own bytes only
        var out = [Float](repeating: 0, count: count)
        raw.withUnsafeBytes { p in
            switch object.dataType {
            case 1:  for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) }
            case 10: for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) }
            case 7:  for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i * 4, as: Int32.self)) }
            case 11: for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
            case 6:  for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i, as: UInt8.self)) }
            case 9:  for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i, as: Int8.self)) }
            case 2:  for i in 0..<count { out[i] = p.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
            case 12: for i in 0..<count { out[i] = Float(p.loadUnaligned(fromByteOffset: i * 8, as: Double.self)) }
            default: break
            }
        }
        let axisIndices = nonSingleton.map(\.offset)
        let xAxis = axisIndices.first.flatMap { object.axes[$0] }
        let yAxis = axisIndices.count > 1 ? object.axes[axisIndices[1]] : nil
        return DM4Image(object: object, width: width, height: height, pixels: out,
                        xAxis: xAxis, yAxis: yAxis)
    }

    /// Most values one EDS spectrum image may hold: a quarter of physical memory as UInt32 (this Mac panicked once reading a
    /// file bigger than RAM), so a larger cube is refused, not attempted, and the refusal names the limit.
    private static var maxEDSElements: Int { Int(ProcessInfo.processInfo.physicalMemory / 16) }

    /// The EDS SI blob, memory order `[nx, ny, channels]` with x fastest and ENERGY SLOWEST (what the simulator writes,
    /// what RosettaSciIO's GMS reader gives for an EDS SI, and what `Dimensions` lists fastest first), transposed into
    /// `(ny, nx, channels)` so one pixel's spectrum is contiguous. Read in blocks of 32 channels: the file is never held
    /// whole. Counts must be non-negative integers (an integer type, or a float type whose values all are): an averaged
    /// or scaled SI is refused rather than rounded, because every sum downstream is an exact integer sum.
    /// DEVIATION from the reference reader (rosettasciio keeps the file's dtype and never refuses): refusing keeps
    /// the exactness the net-count maths relies on.
    /// `Data Order Swapped` = 1 on an SI is REFUSED: the tag is present on the owner's 4D cubes and its meaning for a
    /// spectrum image is unmeasured (`docs/archive/v5/edx-research-2026-10-05/reports/formats.md` §3); guessing the
    /// layout would scramble every map without a sign.
    private static func decodeEDS(_ object: DM4ImageObject, source: Source) throws -> DM4EDSSpectrumImage {
        let name = "\(object.name) (object \(object.index))"
        guard object.role == .eds else {
            throw DM4Error.cannotOpen("\(name) is not an EDS spectrum image.")
        }
        guard object.dimensions.count == 3, object.dimensions.allSatisfy({ $0 > 0 }) else {
            throw DM4Error.cannotOpen("\(name) has dimensions \(object.dimensions); an EDS spectrum image is [x, y, energy].")
        }
        if object.dataOrderSwapped == true {
            throw DM4Error.cannotOpen("\(name) sets 'Data Order Swapped', whose meaning for a spectrum image is not known here; its layout is not guessed.")
        }
        guard let axis = object.axes[2] else {
            throw DM4Error.cannotOpen("\(name) carries no energy calibration.")
        }
        guard let size = pixelSize(object.dataType) else { throw DM4Error.unsupportedDataType(object.dataType) }
        let nx = object.dimensions[0], ny = object.dimensions[1], nch = object.dimensions[2]
        let (np, o1) = nx.multipliedReportingOverflow(by: ny)
        let (total, o2) = np.multipliedReportingOverflow(by: nch)
        let (planeBytes, o3) = np.multipliedReportingOverflow(by: size)
        let (bytes, o4) = total.multipliedReportingOverflow(by: size)
        let (end, o5) = object.dataOffset.addingReportingOverflow(bytes)
        guard !(o1 || o2 || o3 || o4 || o5), object.dataOffset >= 0, end <= source.size,
              object.dataByteCount == bytes else { throw DM4Error.truncated }
        guard total <= maxEDSElements else {
            throw DM4Error.cannotOpen("\(name) has \(total) values; refusing to read more than \(maxEDSElements) (a quarter of this Mac's memory, as 32-bit counts).")
        }
        var out = [UInt32](repeating: 0, count: total)
        var bad = false
        let block = 32
        var c0 = 0
        while c0 < nch {
            let b = min(block, nch - c0)
            let raw = try source.fetch(object.dataOffset + c0 * planeBytes, b * planeBytes)
            raw.withUnsafeBytes { p in
                switch object.dataType {
                case 11: bad = scatterEDS(p, UInt32.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                case 10: bad = scatterEDS(p, UInt16.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                case 6:  bad = scatterEDS(p, UInt8.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                case 7:  bad = scatterEDS(p, Int32.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                case 1:  bad = scatterEDS(p, Int16.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                case 9:  bad = scatterEDS(p, Int8.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                case 2:  bad = scatterEDS(p, Float.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                default: bad = scatterEDS(p, Double.self, b, np, nch, c0, &out) { UInt32(exactly: $0) } || bad
                }
            }
            if bad {
                throw DM4Error.cannotOpen("\(name) holds values that are not non-negative whole counts; only a counts spectrum image is read.")
            }
            c0 += b
        }
        return DM4EDSSpectrumImage(object: object, nx: nx, ny: ny, channels: nch, counts: out, energyAxis: axis)
    }

    /// One block of `b` channel planes (`np` values each) into the pixel-major cube. True when a value does not convert.
    private static func scatterEDS<T>(
        _ p: UnsafeRawBufferPointer, _ type: T.Type, _ b: Int, _ np: Int, _ nch: Int, _ c0: Int,
        _ out: inout [UInt32], _ convert: (T) -> UInt32?
    ) -> Bool {
        var bad = false
        let stride = MemoryLayout<T>.stride
        for pixel in 0..<np {
            let base = pixel * nch + c0
            for j in 0..<b {
                let v = p.loadUnaligned(fromByteOffset: (j * np + pixel) * stride, as: T.self)
                if let u = convert(v) { out[base + j] = u } else { bad = true }
            }
        }
        return bad
    }

    /// The same cap as the EDS cube (a quarter of physical memory, as 4-byte values): Float32 counts are 4 bytes each.
    private static var maxEELSElements: Int { maxEDSElements }

    /// The EELS SI blob, memory order `[nx, ny, channels]` with x fastest and ENERGY SLOWEST (the order of `Dimensions` in the
    /// file, fastest first; RosettaSciIO reads it as an array of shape `(channels, ny, nx)` and names the axes Energy loss,
    /// y, x: `_api.py:457-460`, `:674`), transposed into `(ny, nx, channels)` so one pixel's spectrum is contiguous. The
    /// energy dimension is the THIRD, as the EDS reader takes it, and must be calibrated in "eV" (RosettaSciIO names an axis
    /// "Energy loss" only by that unit, `_api.py:504-506`): another unit is refused rather than guessed.
    /// Read in blocks of 32 channels: the file is never held whole. Unlike the EDS reader nothing is refused for its VALUES:
    /// a negative, fractional or non-finite count is returned as stored (a dark-subtracted or averaged SI is a legitimate
    /// EELS file; any rule on values is the consumer's). `Data Order Swapped` = 1 is refused, as for EDS.
    /// E0, convergence and collection semi-angle: see `DM4EELSSpectrumImage`. A stack made with the DigitalMicrograph stack
    /// builder keeps its tags under `ImageTags.source.Tags at creation`, and RosettaSciIO reads them there only
    /// (`_api.py:888-891`); this does the same when that group holds any number or string.
    /// DIFFERENCE from RosettaSciIO: it maps convergence and collection angle only when `Meta Data.Signal` is "EELS"
    /// (`_api.py:1025`); this reads them whenever the tag is present, because the group `EELS.Experimental Conditions` exists
    /// only on EELS acquisitions and the object is already known to be `.eels`.
    private static func decodeEELS(_ object: DM4ImageObject, source: Source) throws -> DM4EELSSpectrumImage {
        let name = "\(object.name) (object \(object.index))"
        guard object.role == .eels else {
            throw DM4Error.cannotOpen("\(name) is not an EELS spectrum image (its role is \(object.role.rawValue)).")
        }
        guard object.dimensions.count == 3, object.dimensions.allSatisfy({ $0 > 0 }) else {
            throw DM4Error.cannotOpen("\(name) has dimensions \(object.dimensions); an EELS spectrum image is [x, y, energy].")
        }
        if object.dataOrderSwapped == true {
            throw DM4Error.cannotOpen("\(name) sets 'Data Order Swapped', whose meaning for a spectrum image is not known here; its layout is not guessed.")
        }
        guard let axis = object.axes[2] else {
            throw DM4Error.cannotOpen("\(name) carries no energy calibration.")
        }
        guard axis.units == "eV" else {
            throw DM4Error.cannotOpen("\(name) has its third axis in '\(axis.units)', not eV; only [x, y, energy loss in eV] is read.")
        }
        guard let size = pixelSize(object.dataType) else { throw DM4Error.unsupportedDataType(object.dataType) }
        let nx = object.dimensions[0], ny = object.dimensions[1], nch = object.dimensions[2]
        let (np, o1) = nx.multipliedReportingOverflow(by: ny)
        let (total, o2) = np.multipliedReportingOverflow(by: nch)
        let (planeBytes, o3) = np.multipliedReportingOverflow(by: size)
        let (bytes, o4) = total.multipliedReportingOverflow(by: size)
        let (end, o5) = object.dataOffset.addingReportingOverflow(bytes)
        guard !(o1 || o2 || o3 || o4 || o5), object.dataOffset >= 0, end <= source.size,
              object.dataByteCount == bytes else { throw DM4Error.truncated }
        guard total <= maxEELSElements else {
            throw DM4Error.cannotOpen("\(name) has \(total) values; refusing to read more than \(maxEELSElements) (a quarter of this Mac's memory, as 32-bit values).")
        }
        var out = [Float](repeating: 0, count: total)
        let block = 32
        var c0 = 0
        while c0 < nch {
            let b = min(block, nch - c0)
            let raw = try source.fetch(object.dataOffset + c0 * planeBytes, b * planeBytes)
            try raw.withUnsafeBytes { p in
                switch object.dataType {
                case 2:  scatterEELS(p, Float.self, b, np, nch, c0, &out) { $0 }
                case 12: scatterEELS(p, Double.self, b, np, nch, c0, &out) { Float($0) }
                case 1:  scatterEELS(p, Int16.self, b, np, nch, c0, &out) { Float($0) }
                case 10: scatterEELS(p, UInt16.self, b, np, nch, c0, &out) { Float($0) }
                case 7:  scatterEELS(p, Int32.self, b, np, nch, c0, &out) { Float($0) }
                case 11: scatterEELS(p, UInt32.self, b, np, nch, c0, &out) { Float($0) }
                case 6:  scatterEELS(p, UInt8.self, b, np, nch, c0, &out) { Float($0) }
                case 9:  scatterEELS(p, Int8.self, b, np, nch, c0, &out) { Float($0) }
                default: throw DM4Error.unsupportedDataType(object.dataType)
                }
            }
            c0 += b
        }
        let stackGroup = "source.Tags at creation."
        let fromStack = object.imageTagNumbers.keys.contains { $0.hasPrefix(stackGroup) }
            || object.imageTagStrings.keys.contains { $0.hasPrefix(stackGroup) }
        let base = fromStack ? stackGroup : ""
        let conditions = base + "EELS.Experimental Conditions."
        return DM4EELSSpectrumImage(
            object: object, nx: nx, ny: ny, channels: nch, counts: out, energyAxis: axis,
            beamEnergyKeV: object.imageTagNumbers[base + "Microscope Info.Voltage"].map { $0 / 1e3 },
            convergenceSemiAngleMrad: object.imageTagNumbers[conditions + "Convergence semi-angle (mrad)"],
            collectionSemiAngleMrad: object.imageTagNumbers[conditions + "Collection semi-angle (mrad)"])
    }

    /// One block of `b` channel planes (`np` values each) into the pixel-major cube.
    private static func scatterEELS<T>(
        _ p: UnsafeRawBufferPointer, _ type: T.Type, _ b: Int, _ np: Int, _ nch: Int, _ c0: Int,
        _ out: inout [Float], _ convert: (T) -> Float
    ) {
        let stride = MemoryLayout<T>.stride
        for pixel in 0..<np {
            let base = pixel * nch + c0
            for j in 0..<b {
                out[base + j] = convert(p.loadUnaligned(fromByteOffset: (j * np + pixel) * stride, as: T.self))
            }
        }
    }

    /// Pixel types `DM4Reader` decodes; nil for anything else (notably 23, RGBA).
    private static func pixelSize(_ dataType: Int) -> Int? {
        switch dataType {
        case 6, 9: return 1
        case 1, 10: return 2
        case 2, 7, 11: return 4
        case 12: return 8
        default: return nil
        }
    }

    // MARK: Tag walk

    private static let keptArrayBytes = 4096
    private static let knownLabels: Set<String> = ["Survey", "Scan Signal", "EELS", "Diffraction", "EDS"]

    /// DEVIATION from DM4Reader: it walks the same tag grammar but keeps only
    /// scalars, units strings and `Data` offsets. A role needs the Label and
    /// Experiment ID strings and the rect needs short numeric arrays, so this
    /// keeps those too. `DM4Reader.parse` is left untouched on purpose (its
    /// behaviour is pinned byte for byte); the walker is duplicated, not shared.
    ///
    /// A type-18 string tag has the info array [18, length] and then `length` bytes of text,
    /// nothing else. RosettaSciIO `_api.py:121-127` (infoarray_size == 2:
    /// `parse_string_definition` reads the length from the info array) and `:301-330`
    /// (`read_string` consumes exactly `length` bytes). DM4Reader agrees since 2026-10-08.
    private struct Walk {
        var cursor: Cursor
        var version = 4
        var numbers: [String: Double] = [:]
        var strings: [String: String] = [:]
        var arrays: [String: [Double]] = [:]
        var blobs: [String: (offset: Int, bytes: Int)] = [:]
        var objects: [DM4ImageObject] = []
        let keptStringBytes: Int

        init(source: Source, maximumStringBytes: Int = 4096) throws {
            keptStringBytes = max(maximumStringBytes, 0)
            cursor = Cursor(source)
            let v = Int(cursor.u32be())
            if cursor.overran { throw cursor.failure }
            // rsciio `_api.py:76-81` accepts DM3 and DM4 only; a .dm5 is HDF5 and starts with 0x89 'HDF'.
            guard v == 3 || v == 4 else {
                throw DM4Error.cannotOpen("This is not a DM3 or DM4 file (version field \(v)). DM5 (.dm5) is not supported; save as .dm4.")
            }
            version = v
            _ = cursor.special(version)
            guard cursor.u32be() == 1 else {
                if cursor.overran { throw cursor.failure }
                throw DM4Error.notLittleEndian
            }
            try group(prefix: "", depth: 0)
            if cursor.overran { throw cursor.failure }
            objects = try build()
        }

        /// A tag count or length from the file as an `Int`, or `.truncated`.
        func int(_ v: UInt64) throws -> Int {
            guard let i = Int(exactly: v) else { throw DM4Error.truncated }
            return i
        }

        mutating func group(prefix: String, depth: Int) throws {
            guard depth <= 64 else { throw DM4Error.truncated }
            _ = cursor.u8(); _ = cursor.u8()
            let nTags = try int(cursor.special(version))
            for sibling in 0..<nTags {
                guard !cursor.overran, cursor.remaining >= 3 else { throw cursor.failure }
                let tag = cursor.u8()
                if tag == 0 { break }
                let labelLen = Int(cursor.u16be())
                // An empty label is named by its one-based position in the group
                // (the convention DM4Reader and ncempy use).
                let label = labelLen > 0 ? cursor.string(labelLen) : String(sibling + 1)
                let path = prefix.isEmpty ? label : prefix + "." + label
                if version == 4 { _ = cursor.special(version) }
                if tag == 21 { try dataTag(path: path, label: label) }
                else if tag == 20 { try group(prefix: path, depth: depth + 1) }
            }
        }

        mutating func dataTag(path: String, label: String) throws {
            guard cursor.bytes(4) == [37, 37, 37, 37] else { throw cursor.overran ? cursor.failure : DM4Error.truncated }
            let ninfo = try int(cursor.special(version))
            guard ninfo >= 0, ninfo <= 4096 else { throw DM4Error.truncated }
            var info = [UInt64](); info.reserveCapacity(ninfo)
            for _ in 0..<ninfo { info.append(cursor.special(version)) }
            if cursor.overran { throw cursor.failure }
            guard let first = info.first else { return }
            let encType = try int(first)
            switch encType {
            case 2...12:
                numbers[path] = cursor.value(encType)
            case 18:
                // [18, length]; `length` bytes follow (see the DEVIATION note above).
                let length = info.count >= 2 ? try int(info[1]) : 0
                let (end, o) = cursor.offset.addingReportingOverflow(length)
                guard !o, end <= cursor.source.size else { throw DM4Error.truncated }
                strings[path] = String(decoding: cursor.bytes(min(length, keptStringBytes)),
                                       as: UTF8.self)
                cursor.seek(end)
            case 15:
                // Struct: numeric fields kept in order as an array.
                let nFields = info.count >= 3 ? try int(info[2]) : 0
                guard nFields <= 4096, 3 + nFields * 2 <= info.count else { throw DM4Error.truncated }
                var values = [Double]()
                for f in 0..<nFields {
                    let t = try int(info[3 + f * 2 + 1])
                    if (2...12).contains(t) { values.append(cursor.value(t)) }
                    else { _ = cursor.bytes(DM4Experiment.tagTypeSize(t)) }
                }
                if !values.isEmpty { arrays[path] = values }
            case 20:
                let elementType = info.count >= 2 ? try int(info[1]) : 0
                var elemSize = 0
                var lengthIndex = 2
                if elementType == 15 {                          // array of struct
                    let nFields = info.count >= 4 ? try int(info[3]) : 0
                    guard nFields <= 4096, 4 + nFields * 2 < info.count else { throw DM4Error.truncated }
                    for f in 0..<nFields { elemSize += DM4Experiment.tagTypeSize(try int(info[4 + f * 2 + 1])) }
                    lengthIndex = 4 + nFields * 2
                } else if elementType == 18 {                   // array of strings: [20, 18, strLen, size]
                    guard info.count >= 4 else { throw DM4Error.truncated }
                    elemSize = try int(info[2])
                    lengthIndex = 3
                } else {
                    elemSize = DM4Experiment.tagTypeSize(elementType)
                }
                guard lengthIndex < info.count else { throw DM4Error.truncated }
                let length = try int(info[lengthIndex])
                let (nbytes, o1) = length.multipliedReportingOverflow(by: elemSize)
                let start = cursor.offset
                let (end, o2) = start.addingReportingOverflow(nbytes)
                guard !(o1 || o2) else { throw DM4Error.truncated }
                if label == "Data" {
                    // A blob may run past a cut file; only a read of it checks (decode2D).
                    blobs[path] = (start, nbytes)
                } else {
                    guard end <= cursor.source.size else { throw DM4Error.truncated }
                    if nbytes < keptStringBytes, elementType == 4 {
                        // ushort array: a string (units, label, experiment ID) AND, if it is
                        // short, possibly numbers.
                        var units = [UInt16]()
                        for _ in 0..<length { units.append(cursor.u16le()) }
                        strings[path] = String(decoding: units.filter { $0 > 0 }, as: UTF16.self)
                        if length <= 64 { arrays[path] = units.map(Double.init) }
                    } else if nbytes < DM4Experiment.keptArrayBytes, (2...12).contains(elementType), elementType != 8, elementType != 4 {   // a ushort array is a string or nothing (registration 0.2.0 A2)
                        var values = [Double]()
                        for _ in 0..<length { values.append(cursor.value(elementType)) }
                        arrays[path] = values
                    }
                }
                cursor.seek(end)
            default:
                break
            }
        }

        // MARK: Build the objects

        func build() throws -> [DM4ImageObject] {
            var out = [DM4ImageObject]()
            var indices = Set<Int>()
            for key in blobs.keys where key.hasPrefix("ImageList.") && key.hasSuffix(".ImageData.Data") {
                let mid = key.dropFirst("ImageList.".count).dropLast(".ImageData.Data".count)
                if let n = Int(mid) { indices.insert(n) }
            }
            // Root `Thumbnails.N.ImageIndex` is 0-based (measured on 036 and 134: 0 for
            // ImageList.1); rsciio `_api.py:436-440` excludes those images the same way.
            var thumbnails = Set<Int>()
            for (k, v) in numbers where k.hasPrefix("Thumbnails.") && k.hasSuffix(".ImageIndex") {
                if let i = Int(exactly: v) { thumbnails.insert(i + 1) }
            }
            for n in indices.sorted() {
                let root = "ImageList.\(n)."
                let data = root + "ImageData."
                guard let blob = blobs[data + "Data"], let typeValue = numbers[data + "DataType"] else { continue }
                guard let dtype = Int(exactly: typeValue) else { throw DM4Error.truncated }
                var dims = [(Int, Int)]()
                for (k, v) in numbers where k.hasPrefix(data + "Dimensions.") {
                    guard let i = Int(k.dropFirst((data + "Dimensions.").count)) else { continue }
                    guard let d = Int(exactly: v), d >= 0 else { throw DM4Error.truncated }
                    dims.append((i, d))
                }
                dims.sort { $0.0 < $1.0 }
                let axes: [DM4Axis?] = dims.map { (i, _) in
                    let c = data + "Calibrations.Dimension.\(i)."
                    guard let scale = numbers[c + "Scale"] else { return nil }
                    return DM4Axis(origin: numbers[c + "Origin"] ?? 0, scale: scale,
                                   units: strings[c + "Units"] ?? "")
                }
                let tags = root + "ImageTags."
                // This object's own tags only: the trailing dot keeps `ImageList.1.` from matching `ImageList.10.`.
                var tagNumbers = [String: Double](), tagStrings = [String: String]()
                for (k, v) in numbers where k.hasPrefix(tags) { tagNumbers[String(k.dropFirst(tags.count))] = v }
                for (k, v) in strings where k.hasPrefix(tags) { tagStrings[String(k.dropFirst(tags.count))] = v }
                let name = strings[root + "Name"] ?? ""
                // Do not rely on the keyword POSITIONS (.1 = ID, .2 = Label, as seen in the
                // owner's files): scan every `Experiment keywords.N` for a known Label and an ID.
                let kw = tags + "Meta Data.Experiment keywords."
                func keywordValues(_ suffix: String) -> [String] {
                    strings.filter { $0.key.hasPrefix(kw) && $0.key.hasSuffix(suffix) }
                        .compactMap { (k, v) -> (Int, String)? in
                            let mid = k.dropFirst(kw.count).dropLast(suffix.count)
                            return Int(mid).map { ($0, v) }
                        }
                        .sorted { $0.0 < $1.0 }.map(\.1)
                }
                let label = keywordValues(".Label").first { DM4Experiment.knownLabels.contains($0) }
                let experimentID = keywordValues(".Experiment ID").first
                let signal = strings[tags + "Meta Data.Signal"]
                let rect = arrays[tags + "SI.Acquisition.Survey Image.Spectrum Image Rect"]
                func ownID(_ p: String) -> [UInt32]? {
                    let v = (1...4).compactMap { numbers[p + String($0)] }.compactMap { UInt32(exactly: $0) }
                    return v.count == 4 ? v : nil
                }
                func id(_ p: String) -> [UInt32]? {
                    guard let a = arrays[p] else { return nil }
                    let v = a.compactMap { UInt32(exactly: $0) }
                    return v.count == a.count ? v : nil
                }
                let eds = DM4EDSDetectorTags(
                    azimuthDegrees: numbers[tags + "EDS.Detector Info.Azimuthal angle"],
                    elevationDegrees: numbers[tags + "EDS.Detector Info.Elevation angle"],
                    solidAngle: numbers[tags + "EDS.Solid angle"],
                    liveTime: numbers[tags + "EDS.Live time"],
                    realTime: numbers[tags + "EDS.Real time"])
                let (role, source) = Self.role(label: label, signal: signal, name: name, dataType: dtype,
                                               isThumbnail: thumbnails.contains(n))
                out.append(DM4ImageObject(
                    index: n, name: name, role: role, roleSource: source, label: label,
                    experimentID: experimentID,
                    dataType: dtype, dimensions: dims.map(\.1), axes: axes,
                    spectrumImageRect: rect.flatMap { $0.count >= 4 ?
                        DM4SpectrumImageRect(top: $0[0], left: $0[1], bottom: $0[2], right: $0[3]) : nil },
                    surveyImageID: id(tags + "SI.Acquisition.Survey Image.Unique Image ID"),
                    uniqueID: ownID(root + "UniqueID.") ?? id(tags + "Survey Image.Unique Image ID"),
                    eds: eds.isEmpty ? nil : eds,
                    voltage: numbers[tags + "Microscope Info.Voltage"],
                    dataOrderSwapped: numbers[tags + "Meta Data.Data Order Swapped"].map { $0 != 0 },
                    metaDataFormat: strings[tags + "Meta Data.Format"],
                    metaDataSignal: signal,
                    imageTagNumbers: tagNumbers, imageTagStrings: tagStrings,
                    dataOffset: blob.offset, dataByteCount: blob.bytes))
            }
            return out
        }

        /// Order of authority: the root thumbnail list; a known Experiment-keywords Label; then, as
        /// FALLBACKS that a reader must not mistake for labels: data type 23 (RGBA preview),
        /// `Meta Data.Signal` = "X-ray" or "EELS" (RosettaSciIO's two markers), and the object's NAME. The name is used whenever no
        /// known label decided the role (label absent OR unrecognised). GMS names are free text
        /// ("ADF Image (SI Survey)", "Diffraction SI", "EELS LL SI"), so a name is only a guess;
        /// `roleSource` records which rule fired.
        static func role(label: String?, signal: String?, name: String, dataType: Int,
                         isThumbnail: Bool) -> (DM4ImageRole, DM4RoleSource) {
            if isThumbnail { return (.thumbnail, .thumbnailIndex) }
            switch label {
            case "Survey": return (.survey, .label)
            case "Scan Signal": return (.scanSignal, .label)
            case "EELS": return (.eels, .label)
            case "Diffraction": return (.diffraction, .label)
            case "EDS": return (.eds, .label)
            default: break
            }
            if dataType == 23 { return (.thumbnail, .rgbaFallback) }
            if signal == "X-ray" { return (.eds, .signalTag) }       // RosettaSciIO's EDS marker
            if signal == "EELS" { return (.eels, .signalTag) }       // RosettaSciIO's EELS marker (signal_type)
            let n = name.lowercased()
            if n.contains("survey") { return (.survey, .nameHeuristic) }
            if n.contains("diffraction") { return (.diffraction, .nameHeuristic) }
            if n.contains("eels") { return (.eels, .nameHeuristic) }
            if n.contains("eds") || n.contains("edx") || n.contains("x-ray") { return (.eds, .nameHeuristic) }
            return (.unknown, .none)
        }
    }

    fileprivate static func tagTypeSize(_ code: Int) -> Int {
        switch code {
        case 2, 4: return 2
        case 3, 5, 6: return 4
        case 7, 11, 12: return 8
        case 8, 9, 10: return 1
        default: return 0
        }
    }

    /// Cursor over a `Source` with the same bounds behaviour as `DM4Reader`'s `ByteReader`:
    /// a read past the end returns 0 and latches `overran`. Bytes come in 64 KiB windows, so a
    /// tag walk is a few reads, and a skip over a blob is a seek that fetches nothing.
    private struct Cursor {
        let source: Source
        var offset = 0
        private(set) var overran = false
        private var ioError: Error?
        private var window = [UInt8]()
        private var windowStart = 0
        static let windowBytes = 64 * 1024

        init(_ source: Source) { self.source = source }
        var remaining: Int { source.size - offset }
        /// What to throw once `overran` is set: the read error if the disk said one, else `.truncated`.
        var failure: Error { ioError ?? DM4Error.truncated }

        private mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, offset >= 0, n <= source.size - offset else {
                overran = true; offset = source.size &+ 1; return nil
            }
            if !(offset >= windowStart && offset + n <= windowStart + window.count) {
                let want = min(max(n, Self.windowBytes), source.size - offset)
                do { window = try source.fetch(offset, want) }
                catch { ioError = error; overran = true; offset = source.size &+ 1; return nil }
                windowStart = offset
            }
            let s = offset - windowStart
            offset += n
            return window[s..<(s + n)]
        }

        mutating func u8() -> UInt8 { take(1)?.first ?? 0 }
        mutating func u16be() -> UInt16 { UInt16(truncatingIfNeeded: be(2)) }
        mutating func u16le() -> UInt16 { UInt16(truncatingIfNeeded: le(2)) }
        mutating func u32be() -> UInt32 { UInt32(truncatingIfNeeded: be(4)) }
        mutating func u64be() -> UInt64 { be(8) }
        mutating func special(_ version: Int) -> UInt64 { version == 4 ? u64be() : UInt64(u32be()) }
        private mutating func be(_ n: Int) -> UInt64 { take(n)?.reduce(0) { $0 << 8 | UInt64($1) } ?? 0 }
        private mutating func le(_ n: Int) -> UInt64 {
            take(n)?.reversed().reduce(0) { $0 << 8 | UInt64($1) } ?? 0
        }
        mutating func bytes(_ n: Int) -> [UInt8] { take(n).map { Array($0) } ?? [] }
        /// A tag label. UTF-8 when valid, else Latin-1: DigitalMicrograph writes `Emission Current (\u{B5}A)` with a lone
        /// 0xB5 byte (ncempy and RosettaSciIO `_api.py:328-330` read it as Latin-1); UTF-8 decoding made it U+FFFD.
        mutating func string(_ n: Int) -> String {
            let b = bytes(n)
            return String(bytes: b, encoding: .utf8) ?? String(b.map { Character(Unicode.Scalar($0)) })
        }
        mutating func value(_ encType: Int) -> Double {
            switch encType {
            case 2:  return Double(Int16(truncatingIfNeeded: le(2)))
            case 3:  return Double(Int32(truncatingIfNeeded: le(4)))
            case 4:  return Double(UInt16(truncatingIfNeeded: le(2)))
            case 5:  return Double(UInt32(truncatingIfNeeded: le(4)))
            case 6:  return Double(Float(bitPattern: UInt32(truncatingIfNeeded: le(4))))
            case 7:  return Double(bitPattern: le(8))
            case 8:  return Double(u8())
            case 9, 10: return Double(Int8(bitPattern: u8()))
            case 11: return Double(Int64(bitPattern: le(8)))
            case 12: return Double(le(8))
            default: return 0
            }
        }
        mutating func seek(_ to: Int) { offset = to }
    }
}
