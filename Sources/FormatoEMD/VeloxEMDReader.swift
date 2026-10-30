//
//  VeloxEMDReader.swift
//  Role: Read a Thermo Fisher Velox EMD spectrum image (EDX), headless. Decodes
//        `Data/SpectrumStream/<id>/Data` into a per-pixel sparse event store
//        (CSR: channel, count), reads the HAADF image stack on the spectrum grid,
//        and parses the acquisition metadata (energy axis, Super-X geometry,
//        stage, dose, scan).
//
//  The reference is rosettasciio at 049e7d70 (`rsciio/emd/_emd_velox.py`,
//  `rsciio/utils/_fei_stream_readers.py`); `tools/lib/fetch-rsciio.sh` pins it
//  and `tools/velox-parity` compares this reader to it count for count.
//  The stream format (docs/archive/v5/edx-research-2026-10-05/reports/formats.md
//  §2.2): uint16 values; 65535 ends a pixel; any other value is the channel of
//  one detected X-ray; pixels run row-major, and a frame is ny*nx markers.
//
//  Not read by the spectrum path, by decision (ADR 053): Velox's derived element
//  maps and its pruned `SpectrumImage` cube (`images()` below lists a map stored as
//  an image like any other image). No AppState: nothing in the app sees this yet.
//
//  Images (2026-10-12): `images()` lists a file's `Data/Image` stacks and `readImageFrame` reads one
//  frame of one as Float32, so an image reader needs no second Velox parser. A file that
//  holds only images is a Velox file (`isVeloxFile`) but not a spectrum image (`isVeloxEMD`).
//

import Darwin
import Foundation
import FormatoCore
import FormatoHDF5

public enum VeloxEMDError: LocalizedError {
    case libraryUnavailable(String)
    case cannotOpen(String)
    case notVelox(String)
    /// A pruned file (no `SpectrumStream`, or an empty one): only Velox's own
    /// proprietary cube is left, which is not decoded.
    case noSpectrumStream
    case missingMetadata(String)
    case cannotDetermineGrid(String)
    case frameRangeInvalid(String)
    case readFailed(String)
    /// `startFramePosition` other than 1: its meaning is not established (all known files have 1).
    case unsupportedFramePosition(String)
    /// The stream does not fit the grid the metadata implies: refused, never decoded into a wrong cube.
    case gridInconsistent(String)
    /// A file that is not a Velox EMD at all (the image calls do not need a spectrum image).
    case notVeloxFile(String)
    /// `readImageFrame` was given an id that is not an image group of the file.
    case unknownImage(String)
    /// An image stored in a type no float read can take (Velox's FFT and DPC images are compound).
    case unsupportedImageType(String)

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let detail): return "Could not load the bundled HDF5 library: \(detail)"
        case .cannotOpen(let name): return "Could not open \(name) as an HDF5 file."
        case .notVelox(let name): return "\(name) is not a Velox EMD spectrum image."
        case .noSpectrumStream:
            return "This Velox file holds no spectrum stream: it has no spectrum image, or it was pruned or saved by "
                + "software other than Velox. A pruned spectrum image is stored in a proprietary format that is not read."
        case .missingMetadata(let what): return "The Velox file lacks \(what)."
        case .cannotDetermineGrid(let why): return "The spectrum-image grid could not be determined: \(why)."
        case .frameRangeInvalid(let why): return "Invalid frame range: \(why)."
        case .readFailed(let operation): return "HDF5 read failed: \(operation)."
        case .unsupportedFramePosition(let what): return "Unsupported frame position: \(what)."
        case .gridInconsistent(let why): return "The spectrum stream does not match its grid: \(why)."
        case .notVeloxFile(let name): return "\(name) is not a Velox EMD file."
        case .unknownImage(let id): return "The Velox file holds no image named \(id)."
        case .unsupportedImageType(let what): return "Unsupported image data type: \(what)."
        }
    }
}

// MARK: - HDF5 binding (Velox's own subset)

nonisolated private let veloxReadOnly: UInt32 = 0
nonisolated private let veloxDefaultProperty: hid_t = 0
nonisolated private let veloxSelectSet: Int32 = 0
nonisolated private let veloxIntegerClass: Int32 = 0
nonisolated private let veloxFloatClass: Int32 = 1
/// `H5T_SGN_2`: two's complement. `H5T_SGN_NONE` is 0; an integer is one or the other.
nonisolated private let veloxSignedTwosComplement: Int32 = 1

private nonisolated final class VeloxLinkCollector: @unchecked Sendable {
    var names: [String] = []
}

private nonisolated let collectVeloxLink: @convention(c)
    (hid_t, UnsafePointer<CChar>?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> herr_t = {
        _, name, _, context in
        guard let name, let context else { return 0 }
        let collector = Unmanaged<VeloxLinkCollector>.fromOpaque(context).takeUnretainedValue()
        collector.names.append(String(cString: name))
        return 0
    }

/// Where the Velox reader looks for libhdf5, in order (the inherited list plus one): the `FORMATO_HDF5_PATH`
/// override, the host app's `Frameworks/libhdf5.dylib` (a host that ships its own is served first), the copy FormatoKit ships
/// (`FormatoHDF5Library.bundledLibraryPath`), then the loader's search path. A host with other names sets `libraryCandidates` once, before the first read.
package nonisolated enum VeloxHDF5Library {
    /// The default list: exactly the lookup the reader has always done.
    package static let defaultCandidates: @Sendable () -> [String] = {
        [
            ProcessInfo.processInfo.environment["FORMATO_HDF5_PATH"],
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libhdf5.dylib").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("../Frameworks/libhdf5.dylib").standardized.path,
            FormatoHDF5Library.bundledLibraryPath,
            "libhdf5.dylib"
        ].compactMap { $0 }
    }

    /// Owned by `HDF5Serial`: read and written only under its lock (the reader loads the library under it).
    nonisolated(unsafe) private static var custom: (@Sendable () -> [String])?

    package static var libraryCandidates: @Sendable () -> [String] {
        get { HDF5Serial.run { custom ?? defaultCandidates } }
        set { HDF5Serial.run { custom = newValue } }
    }
}

// Both readers use the bindings in FormatoHDF5; keep Velox's error and candidate API.
typealias VeloxHDF5 = SharedHDF5
extension SharedHDF5 {
    static func load() throws -> SharedHDF5 {
        do { return try load(candidates: VeloxHDF5Library.libraryCandidates()) }
        catch HDF5DatacubeError.libraryUnavailable(let detail) { throw VeloxEMDError.libraryUnavailable(detail) }
    }
}

/// RosettaSciIO's `is_EMD_Velox`: the root `Version.format` is "Velox" or "DevelopersKit".
nonisolated func veloxAcceptsFormat(_ format: String?) -> Bool { format == "Velox" || format == "DevelopersKit" }

/// One open file. A class so the handle closes with it. Every member that calls libhdf5 takes `HDF5Serial` itself (the lock
/// is recursive, so a short entry point may still wrap several calls in one `run`); a long operation holds nothing between
/// calls, and the lock is held for one call at most, `readSlab` (one block) being the longest. The handles are plain ids:
/// the lock guards calls, not handles, so a dataset stays open between blocks.
nonisolated final class VeloxFile {
    let h5: VeloxHDF5
    let file: hid_t

    init(path: String) throws {
        let (lib, id): (VeloxHDF5, hid_t) = try HDF5Serial.run {
            let lib = try VeloxHDF5.load()
            return (lib, path.withCString { lib.h5fopen($0, veloxReadOnly, veloxDefaultProperty) })
        }
        guard id >= 0 else { throw VeloxEMDError.cannotOpen(formatoDisplayFileName(path)) }
        h5 = lib
        file = id
    }
    deinit { HDF5Serial.run { _ = h5.h5fclose(file) } }

    func exists(_ path: String) -> Bool {
        HDF5Serial.run { existsLocked(path) }
    }

    private func existsLocked(_ path: String) -> Bool {
        let id = path.withCString { h5.h5oopen(file, $0, veloxDefaultProperty) }
        guard id >= 0 else { return false }
        _ = h5.h5oclose(id)
        return true
    }

    /// Names of the direct children of a group, sorted (h5py iterates by name, and rsciio
    /// takes "the last image" and "the first stream" in that order).
    func children(of group: String) -> [String] {
        HDF5Serial.run { childrenLocked(of: group) }
    }

    private func childrenLocked(of group: String) -> [String] {
        let id = group.withCString { h5.h5oopen(file, $0, veloxDefaultProperty) }
        guard id >= 0 else { return [] }
        defer { _ = h5.h5oclose(id) }
        let collector = VeloxLinkCollector()
        let unmanaged = Unmanaged.passUnretained(collector)
        _ = h5.h5lvisit2(id, 0, 0, collectVeloxLink, unmanaged.toOpaque())
        return collector.names.filter { !$0.contains("/") }.sorted()
    }

    struct Dataset {
        let id: hid_t
        let dims: [Int]
        let isInteger: Bool
        /// The stored element type: HDF5 class (0 integer, 1 float), bytes per element, and whether an integer is signed.
        let typeClass: Int32
        let byteSize: Int
        let isSigned: Bool
    }

    func open(_ path: String) throws -> Dataset {
        try HDF5Serial.run { try openLocked(path) }
    }

    private func openLocked(_ path: String) throws -> Dataset {
        let id = path.withCString { h5.h5dopen2(file, $0, veloxDefaultProperty) }
        guard id >= 0 else { throw VeloxEMDError.readFailed("opening \(path)") }
        let space = h5.h5dgetSpace(id)
        defer { _ = h5.h5sclose(space) }
        let rank = Int(h5.h5sgetNdims(space))
        var dims = [hsize_t](repeating: 0, count: max(rank, 1))
        if rank > 0 { _ = h5.h5sgetDims(space, &dims, nil) }
        let type = h5.h5dgetType(id)
        defer { _ = h5.h5tclose(type) }
        let typeClass = h5.h5tgetClass(type)
        let isInteger = typeClass == veloxIntegerClass
        return Dataset(id: id, dims: dims.prefix(rank).map { Int($0) }, isInteger: isInteger, typeClass: typeClass,
                       byteSize: h5.h5tgetSize(type), isSigned: isInteger && h5.h5tgetSign(type) == veloxSignedTwosComplement)
    }

    func close(_ dataset: Dataset) { HDF5Serial.run { _ = h5.h5dclose(dataset.id) } }

    /// A variable-length string dataset's first element (Version, AcquisitionSettings, ...).
    func readString(_ path: String) -> String? {
        HDF5Serial.run { readStringLocked(path) }
    }

    private func readStringLocked(_ path: String) -> String? {
        guard let dataset = try? open(path) else { return nil }
        defer { close(dataset) }
        // One pointer is all the read below has room for: a dataset of several elements
        // (any other HDF5 file passes through `isVeloxEMD`) would write past it.
        guard dataset.dims.reduce(1, *) == 1 else { return nil }
        let fileType = h5.h5dgetType(dataset.id)
        defer { _ = h5.h5tclose(fileType) }
        guard h5.h5tisVariableStr(fileType) > 0 else { return nil }
        let memType = h5.h5tcopy(fileType)
        defer { _ = h5.h5tclose(memType) }
        var pointer: UnsafeMutablePointer<CChar>?
        // Element 0 of a (1,) dataset: the default selection would also read a (n,) one into one slot.
        let status = withUnsafeMutableBytes(of: &pointer) { h5.h5dread(dataset.id, memType, 0, 0, veloxDefaultProperty, $0.baseAddress) }
        guard status >= 0, let pointer else { return nil }
        defer { _ = h5.h5freeMemory(pointer) }
        return String(cString: pointer)
    }

    /// Reads `count` elements starting at `start` (one hyperslab), rank 1 to 3, into `buffer`.
    func readSlab(_ dataset: Dataset, type: hid_t, start: [Int], count: [Int], into buffer: UnsafeMutableRawPointer) throws {
        try HDF5Serial.run { try readSlabLocked(dataset, type: type, start: start, count: count, into: buffer) }
    }

    private func readSlabLocked(_ dataset: Dataset, type: hid_t, start: [Int], count: [Int], into buffer: UnsafeMutableRawPointer) throws {
        let space = h5.h5dgetSpace(dataset.id)
        defer { _ = h5.h5sclose(space) }
        let s = start.map { hsize_t($0) }, c = count.map { hsize_t($0) }
        guard h5.h5sselectHyperslab(space, veloxSelectSet, s, nil, c, nil) >= 0 else {
            throw VeloxEMDError.readFailed("selecting a hyperslab")
        }
        let memSpace = h5.h5screateSimple(Int32(c.count), c, nil)
        guard memSpace >= 0 else { throw VeloxEMDError.readFailed("creating the memory dataspace") }
        defer { _ = h5.h5sclose(memSpace) }
        guard h5.h5dread(dataset.id, type, memSpace, space, veloxDefaultProperty, buffer) >= 0 else {
            throw VeloxEMDError.readFailed("reading a hyperslab")
        }
    }

    static let maxMetadataBytes = 16 << 20

    /// One column of a `(60000, nFrames)` uint8 `Metadata` dataset: NUL-padded UTF-8 JSON.
    func readMetadataJSON(group: String, column: Int) throws -> Data {
        try HDF5Serial.run { try readMetadataJSONLocked(group: group, column: column) }
    }

    private func readMetadataJSONLocked(group: String, column: Int) throws -> Data {
        let dataset = try open(group + "/Metadata")
        defer { close(dataset) }
        guard dataset.dims.count == 2, column >= 0, column < dataset.dims[1] else {
            throw VeloxEMDError.missingMetadata("metadata column \(column) of \(group)")
        }
        // The row count comes out of the file. Every Velox file measured (111 Metadata datasets over the parity set, the
        // reader's fixtures and rsciio's test files, 2026-10-12) has 60000 rows, 60 kB; 16 MiB is wide margin, and a corrupt
        // or hostile file asking for more is refused before anything is allocated.
        guard dataset.dims[0] <= Self.maxMetadataBytes else {
            throw VeloxEMDError.readFailed("a metadata column of \(dataset.dims[0]) bytes in \(group) (the limit is \(Self.maxMetadataBytes))")
        }
        var bytes = [UInt8](repeating: 0, count: dataset.dims[0])
        try bytes.withUnsafeMutableBytes {
            try readSlab(dataset, type: h5.uint8, start: [0, column], count: [dataset.dims[0], 1], into: $0.baseAddress!)
        }
        if let end = bytes.firstIndex(of: 0) { bytes.removeSubrange(end...) }
        return Data(bytes)
    }
}

// MARK: - The reader

/// The HAADF (or best available scan) image on the spectrum grid, frames summed.
public nonisolated struct VeloxScanImage: Sendable {
    public let ny: Int
    public let nx: Int
    /// `ny * nx` row-major, summed over `framesSummed` frames, in UInt32 so 1607 frames cannot wrap.
    public let sum: [UInt32]
    package let framesSummed: Int
    /// Frames the file holds for this image.
    package let framesInFile: Int
    package let detectorName: String
}

public nonisolated struct VeloxSpectrumImage: Sendable {
    public let eventStore: VeloxEventStore
    public let scanImage: VeloxScanImage?
    /// Metadata of the first stream (column 0).
    public let metadata: VeloxMetadata
    package let version: String
    /// Streams summed (4 for a Super-X, 6 for an UltraX, 1 otherwise).
    public let streamCount: Int
    /// `endFramePosition` of `SpectrumImageSettings` (end, 1-based inclusive) and `startFramePosition`.
    package let settingsFrames: (start: Int?, end: Int?)
    /// Every stream, in name order, with the detector it carries and the X-ray segments that detector name
    /// resolves to. The owner's Super-X file has ONE pre-summed stream "SuperXG1" = segments SuperXG11-14; the
    /// fei 4-detector file has one stream per segment; an UltraX file has six.
    public let streams: [VeloxStreamInfo]
    /// False when the segments the streams resolve to do not all share dispersion and offset: the summed
    /// spectrum would then mix energy scales, and `metadata.energyAxis` (the first stream's) fits only some of it.
    public let energyCalibrationAgrees: Bool
}

public nonisolated struct VeloxStreamInfo: Sendable {
    /// The stream's group id under Data/SpectrumStream.
    public let id: String
    /// `BinaryResult.Detector` and `DetectorIndex` of the stream's own metadata (column 0).
    package let detectorName: String?
    package let detectorIndex: Int?
    /// The analytical detectors whose name CONTAINS `detectorName` (rsciio's matching rule), in file order,
    /// each with its (azimuth, elevation) pair.
    public let segments: [VeloxDetectorInfo]
}

/// The stored element type of an image stack, as HDF5 reports it.
public nonisolated enum VeloxImageElementType: String, Sendable {
    case uint8, uint16, uint32, uint64, int8, int16, int32, int64, float32, float64
}

/// One image stack under `Data/Image`, shape `(height, width, frameCount)` as Velox stores it: `Data` is `(y, x, frame)`.
public nonisolated struct VeloxImageInfo: Sendable {
    /// The group's name under `Data/Image` (a UUID in a Velox file).
    public let id: String
    /// `BinaryResult.Detector` of the first metadata column; "" when the file names none.
    public let detectorName: String
    public let height: Int
    public let width: Int
    public let frameCount: Int
    /// nil for a type no float read can take, such as Velox's compound FFT and DPC images.
    public let elementType: VeloxImageElementType?
    /// Column 0 of the image's `Metadata`: rsciio's `[:, 0]`, and the one a single-frame image has.
    public let metadata: VeloxMetadata
}

/// The groups of a Velox file, counted (`VeloxEMDReader.contents`).
public nonisolated struct VeloxContents: Equatable, Sendable {
    /// Image groups with `Data` and `Metadata` (HAADF, BF, EDS maps, ...).
    public let images: Int
    /// Single spectra under `Data/Spectrum`.
    public let spectra: Int
    /// EDS spectrum streams under `Data/SpectrumStream` (one per detector) of a file that has a `Data/SpectrumImage` group, that is a
    /// scan: a stream recorded at one spot (a single spectrum acquisition) is not a spectrum image and counts as 0.
    public let edsSpectrumImages: Int
    /// EELS spectrum images under `Data/EelsSpectrumImage`.
    public let eelsSpectrumImages: Int

    public init(images: Int, spectra: Int, edsSpectrumImages: Int, eelsSpectrumImages: Int) {
        self.images = images; self.spectra = spectra
        self.edsSpectrumImages = edsSpectrumImages; self.eelsSpectrumImages = eelsSpectrumImages
    }

    /// A spectrum cube (EDS or EELS) is in the file.
    public var hasSpectrumImage: Bool { edsSpectrumImages > 0 || eelsSpectrumImages > 0 }
}

public nonisolated struct VeloxEMDReader: Sendable {
    package let path: String
    /// Values per block read. The default is 32 M (64 MB); a test lowers it so a small file spans several blocks.
    package var blockValues = VeloxEMDReader.defaultBlockValues
    /// Called after each block's read, with no HDF5 lock held, before the block is decoded. A test hook (the lock is free here:
    /// another thread can take it between two blocks); nil in production.
    package var betweenBlocks: (@Sendable (_ blockIndex: Int) -> Void)?

    public init(path: String) { self.path = path }

    /// True for a Velox EMD that carries a spectrum stream or a spectrum image:
    /// root `Version` JSON with `format` "Velox" or "DevelopersKit", and `Data/SpectrumStream` or
    /// `Data/SpectrumImage`. False for anything else, including an unreadable file.
    /// This is the question "can this be opened as a spectrum image?" and the app routes `.emd` files on it:
    /// a file that holds only images answers false here and true to `isVeloxFile`.
    public static func isVeloxEMD(path: String) -> Bool {
        HDF5Serial.run {
            guard let file = try? VeloxFile(path: path) else { return false }
            guard let version = file.readString("/Version"), veloxAcceptsFormat(parseVersion(version)?.format) else { return false }
            return file.exists("/Data/SpectrumStream") || file.exists("/Data/SpectrumImage")
        }
    }

    /// True for a Velox EMD that holds something this reader can read: a spectrum stream, a spectrum image, or an image group
    /// with both `Data` and `Metadata` under `Data/Image`. Use it where plain images are wanted too (`images()`); use
    /// `isVeloxEMD` to ask for a spectrum image. False for anything else, including an unreadable file.
    /// rsciio's `is_EMD_Velox` accepts `format` "Velox" and "DevelopersKit" (0.9.0: so does this) and looks at no layout;
    /// this accepts only a file with one of the layouts above.
    public static func isVeloxFile(path: String) -> Bool {
        HDF5Serial.run {
            guard let file = try? openVeloxFile(path: path) else { return false }
            if file.exists("/Data/SpectrumStream") || file.exists("/Data/SpectrumImage") { return true }
            return file.children(of: "/Data/Image").contains { imageGroup(file: file, id: $0) != nil }
        }
    }

    /// What a Velox file holds, counted from its group names with one HDF5 open and nothing decoded: the image groups (with `Data` and
    /// `Metadata`, the ones `images()` reads), the single spectra, the EDS spectrum streams and the EELS spectrum images. A file's
    /// The `Data/SpectrumImage` descriptors are not counted, but without one the streams are not a scan. Nil for a file that is not Velox or cannot be opened;
    /// a Velox file that holds nothing readable returns all zeros (unlike `isVeloxFile`, which says false).
    public static func contents(path: String) -> VeloxContents? {
        HDF5Serial.run {
            guard let file = try? openVeloxFile(path: path) else { return nil }
            return VeloxContents(
                images: file.children(of: "/Data/Image").filter { imageGroup(file: file, id: $0) != nil }.count,
                spectra: file.children(of: "/Data/Spectrum").count,
                edsSpectrumImages: file.exists("/Data/SpectrumImage") ? file.children(of: "/Data/SpectrumStream").count : 0,
                eelsSpectrumImages: file.children(of: "/Data/EelsSpectrumImage").count)
        }
    }

    /// RosettaSciIO's `is_EMD_Velox`, nothing more: the root `Version` dataset holds JSON whose `format` is "Velox" or
    /// "DevelopersKit". True for a file with only single spectra (`isVeloxFile` needs images or a spectrum image); false for
    /// anything else, including an unreadable file.
    public static func hasVeloxVersion(path: String) -> Bool {
        HDF5Serial.run {
            guard let file = try? VeloxFile(path: path), let version = file.readString("/Version") else { return false }
            return veloxAcceptsFormat(parseVersion(version)?.format)
        }
    }

    /// Opens the file and checks the root `Version` for `format` "Velox", throwing `notVeloxFile` when it is not.
    private static func openVeloxFile(path: String) throws -> VeloxFile {
        let file = try VeloxFile(path: path)
        guard let version = file.readString("/Version"), veloxAcceptsFormat(parseVersion(version)?.format) else {
            throw VeloxEMDError.notVeloxFile(formatoDisplayFileName(path))
        }
        return file
    }

    private static func parseVersion(_ json: String) -> (version: String, format: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let format = object["format"] as? String else { return nil }
        return (object["version"] as? String ?? "", format)
    }

    private struct StreamRef {
        let name: String
        var group: String { "/Data/SpectrumStream/" + name }
    }

    /// Reads the spectrum image: the stream summed over `frames`, the scan image on the
    /// same grid, and the metadata.
    ///
    /// `cancelled` is polled at block boundaries (and between frames of the scan image); true throws `FormatoCancelled` and
    /// nothing is kept. `progress` is the fraction of the stream passes done (one length pass over the first stream, then a
    /// count and a scatter pass per stream; monotone, ending at 1). The HDF5 lock is taken per call inside `VeloxFile`, so
    /// another thread waits for one block read at most.
    public func readSpectrumImage(
        frames: VeloxFrameSelection = .recordedDefault,
        cancelled: @Sendable () -> Bool = FormatoCancellation.task,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> VeloxSpectrumImage {
        try withoutActuallyEscaping(cancelled) { (cancelled: @escaping @Sendable () -> Bool) throws -> VeloxSpectrumImage in   // the block sources live for this call only
            try FormatoCancellation.check(cancelled)
            let file = try VeloxFile(path: path)
            guard let versionText = file.readString("/Version"), let version = Self.parseVersion(versionText),
                  veloxAcceptsFormat(version.format) else { throw VeloxEMDError.notVelox(formatoDisplayFileName(path)) }
            let streams = file.children(of: "/Data/SpectrumStream").map(StreamRef.init)
            guard !streams.isEmpty else { throw VeloxEMDError.noSpectrumStream }

            // Metadata of the first stream, in name order: rsciio's `streams[0]`.
            let head = streams[0]
            let metadata = try VeloxMetadata.parse(jsonData: file.readMetadataJSON(group: head.group, column: 0))
            guard let settingsText = file.readString(head.group + "/AcquisitionSettings"),
                  let settings = try JSONSerialization.jsonObject(with: Data(settingsText.utf8)) as? [String: Any],
                  let channels = jsonInt(settings["bincount"]), channels > 0 else {
                throw VeloxEMDError.missingMetadata("AcquisitionSettings.bincount")
            }

            // SI settings: endFramePosition is rsciio's frame count and last_frame.
            var settingsStart: Int?, settingsEnd: Int?
            if let first = file.children(of: "/Data/SpectrumImage").first,
               let text = file.readString("/Data/SpectrumImage/\(first)/SpectrumImageSettings"),
               let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                settingsStart = jsonInt(object["startFramePosition"])
                settingsEnd = jsonInt(object["endFramePosition"])
            }
            // startFramePosition is 1 in every file seen, where 1-based inclusive equals rsciio's first_frame 0.
            // Any other value would be a trimmed acquisition whose meaning nobody has established: refuse.
            if let start = settingsStart, start != 1 {
                throw VeloxEMDError.unsupportedFramePosition("startFramePosition is \(start); only 1 is understood")
            }
            if let end = settingsEnd, end < 1 {
                throw VeloxEMDError.frameRangeInvalid("endFramePosition is \(end)")
            }

            // The grid. DEVIATION: rsciio takes it from the LAST image group read (name order),
            // whatever that image is. In `example_velox_EELS_EDS.emd` that is a 128 x 128 image of a
            // 16 x 20 spectrum image, and every count lands in the first rows (formats.md §2.2,
            // reproduced by tools/velox-parity). Here the grid is ScanSize x ScanArea. Evidence it is the
            // right one: in that file the seven (16, 20, 1) images share the stream's ScanArea
            // (128 x 0.15625 = 20 columns, 128 x 0.125 = 16 rows); the non-square public 10 x 50 files' HAADF
            // is (50, 10); the owner's HAADF is (926, 215, 1607) with ScanArea 0.2100 x 0.9043 of 1024.
            // rsciio's last-image rule is the fallback when the metadata cannot say, and then it must be
            // an integer scan image, or the grid is refused.
            let imageNames = file.children(of: "/Data/Image")
            var imageShapes: [(name: String, ny: Int, nx: Int, frames: Int, isInteger: Bool)] = []
            for name in imageNames {
                let dataset = try file.open("/Data/Image/\(name)/Data")
                defer { file.close(dataset) }
                if dataset.dims.count == 3 {
                    imageShapes.append((name, dataset.dims[0], dataset.dims[1], dataset.dims[2], dataset.isInteger))
                }
            }
            let grid: (ny: Int, nx: Int)
            if let derived = metadata.derivedGrid {
                grid = derived
            } else if let last = imageShapes.last {
                guard last.isInteger, imageShapes.contains(where: { $0.ny == last.ny && $0.nx == last.nx && $0.isInteger }) else {
                    throw VeloxEMDError.cannotDetermineGrid("ScanArea is missing and the last image is not an integer scan image")
                }
                grid = (last.ny, last.nx)
            } else {
                throw VeloxEMDError.cannotDetermineGrid("neither ScanSize x ScanArea nor an image gives it")
            }
            let geometry = VeloxStreamGeometry(ny: grid.ny, nx: grid.nx, channels: channels)

            // The stream must fit the grid, BEFORE anything is allocated from it. One pass over the first stream.
            let tracker = PassProgress(passes: 1 + 2 * streams.count, report: progress)
            tracker.begin()
            let (_, markers) = try Self.lengthAndMarkers(
                file: file, stream: head, blockValues: blockValues, hook: betweenBlocks, cancelled: cancelled,
                progress: { tracker.fraction($0) })
            let pixels = geometry.pixelsPerFrame
            guard pixels >= 1, pixels <= Self.maximumPixels, pixels <= markers + 1 else {   // + 1: the last pixel's marker may be absent
                throw VeloxEMDError.gridInconsistent("\(grid.ny) x \(grid.nx) pixels per frame against \(markers) pixel ends")
            }
            var tableFrames: Int?
            if file.exists(head.group + "/FrameLocationTable") {
                let table = try file.open(head.group + "/FrameLocationTable")
                defer { file.close(table) }
                tableFrames = table.dims.first
            }
            // ceil(markers / pixels): rsciio's own frame count. A stream may lack its LAST marker (the 16 x 20
            // EELS_EDS stream has 319 of 320), but never a whole frame's worth.
            let frameCountGuess = (markers + pixels - 1) / pixels
            if let n = tableFrames, n != frameCountGuess {
                throw VeloxEMDError.gridInconsistent("the FrameLocationTable lists \(n) frames; \(markers) pixel ends over \(grid.ny) x \(grid.nx) pixels make \(frameCountGuess)")
            }
            // Without a FrameLocationTable a grid SMALLER than the stream can pass this check (the grid comes from
            // ScanSize x ScanArea, not from the stream); the table is the only cross-check on the grid size.
            // A stopped acquisition (a partial last frame) is NOT refused: fei_emd_si.emd is one, and rsciio
            // reads it. It is reported in the store (`partialFramePixels`) instead.

            // Frame range: rsciio's first_frame = 0, last_frame = endFramePosition, else the
            // stream's own frame count. An explicit range may not pass endFramePosition (rsciio raises).
            let limit = settingsEnd ?? frameCountGuess
            let range: Range<Int>
            switch frames {
            case .recordedDefault: range = 0..<limit
            case .all: range = 0..<frameCountGuess
            case .range(let r):
                guard r.upperBound <= limit else {
                    throw VeloxEMDError.frameRangeInvalid("\(r) passes the \(limit) frames of this file")
                }
                range = r
            }

            // Sources: one restartable block reader per stream, over its own dataset handle.
            var sources: [VeloxStreamDecoder.BlockSource] = []
            for stream in streams {
                let base = Self.blockSource(
                    file: file, dataset: stream.group + "/Data", blockValues: blockValues, hook: betweenBlocks,
                    cancelled: cancelled, progress: { tracker.fraction($0) })
                sources.append { visit in tracker.begin(); try base(visit) }   // each call is the next pass
            }
            let store = try VeloxStreamDecoder.buildEventStore(streams: sources, geometry: geometry, frames: range, cancelled: cancelled)

            // Which detector each stream carries, and whether the summed segments share an energy scale.
            var infos: [VeloxStreamInfo] = []
            for stream in streams {
                let m = stream.name == head.name ? metadata
                    : try VeloxMetadata.parse(jsonData: file.readMetadataJSON(group: stream.group, column: 0))
                let name = m.binaryResultDetector
                // `contains`, rsciio's rule, would also take a hypothetical SuperXG10 for SuperXG1 (or UltraX10 for UltraX1).
                let segments = name.map { n in m.detectors.filter { $0.isAnalytical && $0.name.contains(n) } } ?? []
                infos.append(VeloxStreamInfo(id: stream.name, detectorName: name, detectorIndex: m.binaryResultDetectorIndex, segments: segments))
            }
            var calibrations = Set<String>()
            for segment in infos.flatMap(\.segments) {
                calibrations.insert("\(segment.dispersionEV ?? .nan)|\(segment.offsetEnergyEV ?? .nan)")
            }

            let image = try Self.readScanImage(
                file: file, shapes: imageShapes, grid: grid, range: range, preferredDetector: metadata.binaryResultDetector,
                cancelled: cancelled)
            tracker.finish()
            return VeloxSpectrumImage(
                eventStore: store, scanImage: image, metadata: metadata, version: version.version,
                streamCount: streams.count, settingsFrames: (settingsStart, settingsEnd),
                streams: infos, energyCalibrationAgrees: calibrations.count <= 1)
        }
    }

    /// A stream's length and pixel-marker count, in one pass.
    private static func lengthAndMarkers(
        file: VeloxFile, stream: StreamRef, blockValues: Int, hook: (@Sendable (Int) -> Void)?,
        cancelled: @escaping @Sendable () -> Bool, progress: (@Sendable (Double) -> Void)?
    ) throws -> (values: Int, markers: Int) {
        var values = 0, markers = 0
        let source = blockSource(
            file: file, dataset: stream.group + "/Data", blockValues: blockValues, hook: hook, cancelled: cancelled, progress: progress)
        try source { block in
            values += block.count
            for v in block where v == VeloxStreamDecoder.pixelMarker { markers += 1 }
            return true
        }
        return (values, markers)
    }

    /// A sanity cap on ny * nx (2^28 pixels): a corrupt ScanSize must throw, not allocate gigabytes.
    private static let maximumPixels = 1 << 28

    /// A sanity cap on the frames a file may declare (2^20).
    private static let maximumFrames = 1 << 20

    /// A sanity cap on the bytes of a whole `Metadata` block the per-frame reads walk (1 GiB): every Velox file measured has 60000
    /// rows, so this is about 17900 frames, while a crafted block within the frame and column caps could declare terabytes.
    private static let maximumMetadataBytes = 1 << 30

    /// Refuses a `Metadata` block of `rows` × `columns` bytes past `maximumMetadataBytes` before its first column is read.
    private static func requireMetadataBytes(rows: Int, columns: Int, group: String) throws {
        let (total, overflow) = rows.multipliedReportingOverflow(by: columns)
        guard overflow || total > maximumMetadataBytes else { return }
        let size = overflow ? "\(rows) × \(columns)" : "\(total)"
        throw VeloxEMDError.readFailed("a Metadata block of \(size) bytes in \(group) (the limit is \(maximumMetadataBytes))")
    }

    /// Refuses `count` frames declared by `what` of the stream at `group` before anything is allocated or looped from it: every
    /// frame holds at least one value of the stream's `Data` (its pixel markers), so a stream of n values has at most n frames,
    /// and never more than `maximumFrames`.
    private static func requireFrames(_ count: Int, _ what: String, group: String, file: VeloxFile) throws {
        let stream = try file.open(group + "/Data")
        defer { file.close(stream) }
        var values = 1
        for d in stream.dims {
            let (product, overflow) = values.multipliedReportingOverflow(by: d)
            values = overflow ? Int.max : product
        }
        let limit = min(values, maximumFrames)
        guard count <= limit else {
            throw VeloxEMDError.readFailed("\(what) of \(count) frames in \(group) (the limit is \(limit): the stream's length, at most \(maximumFrames))")
        }
    }

    /// 32 M values (64 MB) a block: the stream is read in chunks, never whole.
    package static let defaultBlockValues = 32 << 20

    /// Counts the passes of a `readSpectrumImage` and folds each block's within-pass fraction into one monotone fraction.
    /// Single-threaded by construction (the passes run one after another on the calling thread).
    private final class PassProgress: @unchecked Sendable {
        let passes: Int
        let report: (@Sendable (Double) -> Void)?
        private var pass = -1
        private var last = 0.0
        init(passes: Int, report: (@Sendable (Double) -> Void)?) { self.passes = passes; self.report = report }
        func begin() { pass += 1 }
        func fraction(_ within: Double) {
            let value = min(1, (Double(max(pass, 0)) + within) / Double(passes))
            if value > last { last = value; report?(value) }
        }
        func finish() { if last < 1 { last = 1; report?(1) } }
    }

    /// One restartable reader of a stream's values, `blockValues` at a time. The HDF5 lock is held inside `readSlab` only:
    /// `visit` (the per-value decode), `hook` and the cancel check run unlocked. `cancelled` is polled before each block;
    /// `progress` gets the fraction of the stream's values read, ending at 1 (also when the visitor stops the read early).
    private static func blockSource(
        file: VeloxFile, dataset path: String, blockValues: Int, hook: (@Sendable (Int) -> Void)?,
        cancelled: @Sendable @escaping () -> Bool, progress: (@Sendable (Double) -> Void)?
    ) -> VeloxStreamDecoder.BlockSource {
        { visit in
            let dataset = try file.open(path)
            defer { file.close(dataset) }
            guard dataset.dims.count >= 1 else { throw VeloxEMDError.readFailed("the stream \(path) has no extent") }
            let total = dataset.dims[0]
            let width = dataset.dims.count == 2 ? dataset.dims[1] : 1
            guard width == 1 else { throw VeloxEMDError.readFailed("the stream \(path) is not one column") }
            let buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: min(total, blockValues))
            defer { buffer.deallocate() }
            var at = 0, index = 0
            while at < total {
                try FormatoCancellation.check(cancelled)
                let n = min(blockValues, total - at)
                let start = dataset.dims.count == 2 ? [at, 0] : [at]
                let count = dataset.dims.count == 2 ? [n, 1] : [n]
                try file.readSlab(dataset, type: file.h5.uint16, start: start, count: count, into: buffer)
                hook?(index)
                if try !visit(UnsafeBufferPointer(start: buffer, count: n)) { progress?(1); return }
                at += n
                index += 1
                progress?(Double(at) / Double(total))   // the last block's is exactly 1
            }
            if total == 0 { progress?(1) }
        }
    }

    /// The scan image on the spectrum grid: the stream's own detector when it is an image
    /// (never, for EDX), else HAADF, then any dark field, then bright field, then the first
    /// integer image; summed over the same frame range, clipped to the frames the image has.
    private static func readScanImage(
        file: VeloxFile, shapes: [(name: String, ny: Int, nx: Int, frames: Int, isInteger: Bool)],
        grid: (ny: Int, nx: Int), range: Range<Int>, preferredDetector: String?,
        cancelled: @Sendable () -> Bool
    ) throws -> VeloxScanImage? {
        let onGrid = shapes.filter { $0.ny == grid.ny && $0.nx == grid.nx && $0.isInteger }
        guard !onGrid.isEmpty else { return nil }
        var named: [(entry: (name: String, ny: Int, nx: Int, frames: Int, isInteger: Bool), detector: String)] = []
        for entry in onGrid {
            let json = try file.readMetadataJSON(group: "/Data/Image/\(entry.name)", column: 0)
            let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
            let detector = (root?["BinaryResult"] as? [String: Any])?["Detector"] as? String ?? ""
            named.append((entry, detector))
        }
        func rank(_ detector: String) -> Int {
            let d = detector.uppercased()
            if d.contains("HAADF") { return 0 }
            if d.contains("DF") { return 1 }
            if d.contains("BF") { return 2 }
            return 3
        }
        guard let pick = named.enumerated().min(by: { (rank($0.element.detector), $0.offset) < (rank($1.element.detector), $1.offset) })?.element
        else { return nil }

        let upper = min(range.upperBound, pick.entry.frames)
        let lower = min(range.lowerBound, upper)
        let dataset = try file.open("/Data/Image/\(pick.entry.name)/Data")
        defer { file.close(dataset) }
        let pixels = grid.ny * grid.nx
        var sum = [UInt32](repeating: 0, count: pixels)
        var frame = [UInt32](repeating: 0, count: pixels)
        // One frame per read: Velox chunks each frame separately, and a whole-stack read scatters element-wise.
        for f in lower..<upper {
            try FormatoCancellation.check(cancelled)
            try frame.withUnsafeMutableBytes {
                try file.readSlab(dataset, type: file.h5.uint32, start: [0, 0, f], count: [grid.ny, grid.nx, 1], into: $0.baseAddress!)
            }
            for p in 0..<pixels { sum[p] &+= frame[p] }
        }
        return VeloxScanImage(
            ny: grid.ny, nx: grid.nx, sum: sum, framesSummed: upper - lower,
            framesInFile: pick.entry.frames, detectorName: pick.detector)
    }

    // MARK: Images

    /// `/Data/Image/<id>` when `id` names a group there that holds both `Data` and `Metadata`, else nil. An id with a "/" never does.
    private static func imageGroup(file: VeloxFile, id: String) -> String? {
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let group = "/Data/Image/" + id
        return file.exists(group + "/Data") && file.exists(group + "/Metadata") ? group : nil
    }

    /// The type HDF5 can convert to Float32 on read: 1, 2, 4 or 8-byte integers and 4 or 8-byte floats. nil for anything else
    /// (compound, enum, string, a 2-byte float, ...).
    private static func imageElementType(of dataset: VeloxFile.Dataset) -> VeloxImageElementType? {
        if dataset.typeClass == veloxIntegerClass {
            switch (dataset.byteSize, dataset.isSigned) {
            case (1, false): return .uint8
            case (2, false): return .uint16
            case (4, false): return .uint32
            case (8, false): return .uint64
            case (1, true): return .int8
            case (2, true): return .int16
            case (4, true): return .int32
            case (8, true): return .int64
            default: return nil
            }
        }
        if dataset.typeClass == veloxFloatClass {
            switch dataset.byteSize {
            case 4: return .float32
            case 8: return .float64
            default: return nil
            }
        }
        return nil
    }

    /// Every image stack of the file: the groups under `Data/Image` that hold a rank-3 `Data` and a `Metadata`, in name order (as
    /// h5py iterates, and rsciio reads them). Empty when the file has none. A group whose `Metadata` is unreadable throws, as the
    /// file is then damaged rather than short of images. Throws `notVeloxFile` for any HDF5 file whose `Version` is not Velox.
    /// `cancelled` is polled before each image group. A short operation: the lock is held across it.
    public func images(cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws -> [VeloxImageInfo] {
        try HDF5Serial.run {
            try FormatoCancellation.check(cancelled)
            let file = try Self.openVeloxFile(path: path)
            var out: [VeloxImageInfo] = []
            for name in file.children(of: "/Data/Image") {
                try FormatoCancellation.check(cancelled)
                guard let group = Self.imageGroup(file: file, id: name) else { continue }
                let dataset = try file.open(group + "/Data")
                defer { file.close(dataset) }
                guard dataset.dims.count == 3 else { continue }
                let metadata = try VeloxMetadata.parse(jsonData: file.readMetadataJSON(group: group, column: 0))
                out.append(VeloxImageInfo(
                    id: name, detectorName: metadata.binaryResultDetector ?? "",
                    height: dataset.dims[0], width: dataset.dims[1], frameCount: dataset.dims[2],
                    elementType: Self.imageElementType(of: dataset), metadata: metadata))
            }
            return out
        }
    }

    /// The metadata of the file's spectrum image: column 0 of `Metadata` of the first group under `Data/SpectrumImage` (name order, as
    /// RosettaSciIO's EELS reader takes its pixel size), nil when the file has no such group or the group has no `Metadata`.
    ///
    /// This is where a Velox file keeps the live and real time of the whole acquisition: `superXDetectors[i].liveTimeColumn0` and
    /// `.realTimeColumn0` are seconds, one pair per X-ray detector segment, the totals over the frames of the scan (the owner's
    /// 1607-frame file: real 4187.7 s against a frame time of 2.64 s, live 1423.1 s). The spectrum stream's own columns
    /// hold one frame's values, or 0 in the first column. RosettaSciIO maps neither; FormatoKit reads them as stored. The group also
    /// carries the optics (`stemMagnification`, `cameraLengthMeters`), `pixelSizeMeters` and `pixelUnit` of the scan; `segmentTimes`, `commonLiveTimeSeconds` and `commonRealTimeSeconds` read the times. They are not in the signals' metadata: that stays RosettaSciIO's. Throws as `images()`
    /// does for a damaged file.
    public func spectrumImageMetadata(cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws -> VeloxMetadata? {
        try HDF5Serial.run {
            try FormatoCancellation.check(cancelled)
            let file = try Self.openVeloxFile(path: path)
            guard let name = file.children(of: "/Data/SpectrumImage").first else { return nil }
            let group = "/Data/SpectrumImage/" + name
            guard file.exists(group + "/Metadata") else { return nil }
            return try VeloxMetadata.parse(jsonData: file.readMetadataJSON(group: group, column: 0))
        }
    }

    /// The metadata of each EELS spectrum image, `Data/EelsSpectrumImage/<id>/Metadata`, in the order `VeloxSpectrumImageSignals`
    /// returns the EELS signals (one per energy range of a Zebra detector). Each carries the optics the EELS signal's own metadata
    /// does not: RosettaSciIO maps nothing for an EELS spectrum image, so its signals keep only the title and file name. Read
    /// `AcquisitionMetadata.velox(eelsSpectrumImage:)` from these for the beam energy and the angles. Empty for a file with
    /// no EELS spectrum image. Throws `missingMetadata` for a group without a Metadata JSON object (RosettaSciIO raises there
    /// too), and as `images()` does for a damaged file.
    public func eelsSpectrumImageMetadata(cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws -> [VeloxMetadata] {
        try HDF5Serial.run {
            try FormatoCancellation.check(cancelled)
            let file = try Self.openVeloxFile(path: path)
            return try file.children(of: "/Data/EelsSpectrumImage").map { id in
                try FormatoCancellation.check(cancelled)
                let group = "/Data/EelsSpectrumImage/" + id
                guard file.exists(group + "/Metadata") else { throw VeloxEMDError.missingMetadata("Data/EelsSpectrumImage/\(id)/Metadata") }
                let json = try file.readMetadataJSON(group: group, column: 0)
                guard let metadata = try? VeloxMetadata.parse(jsonData: json) else {
                    throw VeloxEMDError.missingMetadata("a JSON object in Data/EelsSpectrumImage/\(id)/Metadata")
                }
                return metadata
            }
        }
    }

    /// One frame of one image as `height * width` Float32, row-major (y, then x). HDF5 converts the stored type on read, so every
    /// `VeloxImageElementType` is read the same way. DEVIATION: rsciio returns the stored dtype; here int32, uint32, 64-bit values
    /// beyond 2^24 and float64 round to the nearest Float32 (int8, int16, uint8, uint16 and float32 are exact); a float64 above
    /// Float32's largest value becomes ±infinity (HDF5's conversion, even where IEEE rounding would give that value), and
    /// NaN stays NaN.
    /// One hyperslab `[0, 0, frame]` by `[height, width, 1]`: Velox chunks a frame at a time. Throws `unknownImage` for an id
    /// `images()` does not list, `frameRangeInvalid` for a frame outside `0..<frameCount`, and `unsupportedImageType` for a type
    /// whose `elementType` is nil.
    /// `cancelled` is polled before the open and before the one block read (a frame is a single `H5Dread`).
    public func readImageFrame(id: String, frame: Int, cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws -> [Float] {
        try HDF5Serial.run {
            try FormatoCancellation.check(cancelled)
            let file = try Self.openVeloxFile(path: path)
            guard let group = Self.imageGroup(file: file, id: id) else { throw VeloxEMDError.unknownImage(id) }
            let dataset = try file.open(group + "/Data")
            defer { file.close(dataset) }
            guard dataset.dims.count == 3 else { throw VeloxEMDError.unknownImage(id) }
            let height = dataset.dims[0], width = dataset.dims[1], frames = dataset.dims[2]
            guard frame >= 0, frame < frames else {
                throw VeloxEMDError.frameRangeInvalid("frame \(frame) of image \(id) is outside its \(frames) frames")
            }
            guard Self.imageElementType(of: dataset) != nil else {
                throw VeloxEMDError.unsupportedImageType(
                    "image \(id) is stored as HDF5 type class \(dataset.typeClass), \(dataset.byteSize) bytes per element; "
                    + "only integers of 1 to 8 bytes and 4 or 8-byte floats are read (Velox's FFT and DPC images are compound)")
            }
            let (pixels, overflow) = height.multipliedReportingOverflow(by: width)
            guard !overflow, pixels > 0, pixels <= Self.maximumPixels else {
                throw VeloxEMDError.readFailed("an image of \(height) x \(width) pixels is empty or larger than this reader accepts")
            }
            var out = [Float](repeating: 0, count: pixels)
            try FormatoCancellation.check(cancelled)
            try out.withUnsafeMutableBytes {
                try file.readSlab(dataset, type: file.h5.float32, start: [0, 0, frame], count: [height, width, 1], into: $0.baseAddress!)
            }
            return out
        }
    }

    /// One frame of one image in its STORED type: `height * width` elements, row-major (y, then x), little-endian, read through
    /// HDF5's native type of the stored class, size and sign, so no value changes (`readImageFrame`
    /// above stays Float32 for its callers). Throws as `readImageFrame` does.
    package func readImageFrameBytes(id: String, frame: Int, cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws -> (VeloxImageElementType, [UInt8]) {
        try HDF5Serial.run {
            try FormatoCancellation.check(cancelled)
            let file = try Self.openVeloxFile(path: path)
            guard let group = Self.imageGroup(file: file, id: id) else { throw VeloxEMDError.unknownImage(id) }
            let dataset = try file.open(group + "/Data")
            defer { file.close(dataset) }
            guard dataset.dims.count == 3 else { throw VeloxEMDError.unknownImage(id) }
            let height = dataset.dims[0], width = dataset.dims[1], frames = dataset.dims[2]
            guard frame >= 0, frame < frames else {
                throw VeloxEMDError.frameRangeInvalid("frame \(frame) of image \(id) is outside its \(frames) frames")
            }
            guard let type = Self.imageElementType(of: dataset) else {
                throw VeloxEMDError.unsupportedImageType(
                    "image \(id) is stored as HDF5 type class \(dataset.typeClass), \(dataset.byteSize) bytes per element; "
                    + "only integers of 1 to 8 bytes and 4 or 8-byte floats are read (Velox's FFT and DPC images are compound)")
            }
            let (pixels, overflow) = height.multipliedReportingOverflow(by: width)
            guard !overflow, pixels > 0, pixels <= Self.maximumPixels else {
                throw VeloxEMDError.readFailed("an image of \(height) x \(width) pixels is empty or larger than this reader accepts")
            }
            let h5 = file.h5
            let memory: hid_t
            let size: Int
            switch type {
            case .uint8: (memory, size) = (h5.uint8, 1)
            case .uint16: (memory, size) = (h5.uint16, 2)
            case .uint32: (memory, size) = (h5.uint32, 4)
            case .uint64: (memory, size) = (h5.uint64, 8)
            case .int8: (memory, size) = (h5.int8, 1)
            case .int16: (memory, size) = (h5.int16, 2)
            case .int32: (memory, size) = (h5.int32, 4)
            case .int64: (memory, size) = (h5.int64, 8)
            case .float32: (memory, size) = (h5.float32, 4)
            case .float64: (memory, size) = (h5.float64, 8)
            }
            var out = [UInt8](repeating: 0, count: pixels * size)
            try FormatoCancellation.check(cancelled)
            try out.withUnsafeMutableBytes {
                try file.readSlab(dataset, type: memory, start: [0, 0, frame], count: [height, width, 1], into: $0.baseAddress!)
            }
            return (type, out)   // native is little-endian on every platform this package builds for (arm64)
        }
    }

    /// Diagnostic: how many pixel markers fall in each frame window of the first stream, from its
    /// `FrameLocationTable` (versions >= 6; nil without one). Every entry equals ny*nx when the
    /// grid is right (prediction P2), and a stopped acquisition shows as a short last entry.
    /// `cancelled` is polled at block boundaries; `progress` is the fraction of the stream read (monotone, ends at 1).
    package func markersPerFrame(
        cancelled: @Sendable () -> Bool = FormatoCancellation.task, progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> [Int]? {
        try withoutActuallyEscaping(cancelled) { (cancelled: @escaping @Sendable () -> Bool) throws -> [Int]? in

            try FormatoCancellation.check(cancelled)
            let file = try VeloxFile(path: path)
            guard let head = file.children(of: "/Data/SpectrumStream").first else { throw VeloxEMDError.noSpectrumStream }
            let group = "/Data/SpectrumStream/" + head
            guard file.exists(group + "/FrameLocationTable") else { return nil }
            let table = try file.open(group + "/FrameLocationTable")
            defer { file.close(table) }
            guard let n = table.dims.first, n > 0 else { return nil }
            try Self.requireFrames(n, "a FrameLocationTable", group: group, file: file)
            var starts = [UInt64](repeating: 0, count: n)
            try starts.withUnsafeMutableBytes {
                try file.readSlab(table, type: file.h5.uint64, start: table.dims.count == 2 ? [0, 0] : [0],
                                  count: table.dims.count == 2 ? [n, 1] : [n], into: $0.baseAddress!)
            }
            // Walk the stream once, counting markers between consecutive frame starts.
            var perFrame = [Int](repeating: 0, count: n)
            var position: UInt64 = 0
            var frame = 0
            let source = Self.blockSource(
                file: file, dataset: group + "/Data", blockValues: blockValues, hook: betweenBlocks, cancelled: cancelled, progress: progress)
            try source { block in
                for v in block {
                    while frame + 1 < n && position >= starts[frame + 1] { frame += 1 }
                    if v == VeloxStreamDecoder.pixelMarker { perFrame[frame] += 1 }
                    position += 1
                }
                return true
            }
            return perFrame
        }
    }

    /// Diagnostic: the first stream's length and its pixel-marker count.
    /// `cancelled` is polled at block boundaries; `progress` is the fraction of the stream read (monotone, ends at 1).
    package func streamLengthAndMarkers(
        cancelled: @Sendable () -> Bool = FormatoCancellation.task, progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> (values: Int, markers: Int) {
        try withoutActuallyEscaping(cancelled) { (cancelled: @escaping @Sendable () -> Bool) throws -> (values: Int, markers: Int) in
            try FormatoCancellation.check(cancelled)
            let file = try VeloxFile(path: path)
            guard let head = file.children(of: "/Data/SpectrumStream").first else { throw VeloxEMDError.noSpectrumStream }
            return try Self.lengthAndMarkers(
                file: file, stream: StreamRef(name: head), blockValues: blockValues, hook: betweenBlocks, cancelled: cancelled, progress: progress)
        }
    }

    /// The per-frame `ScanTransformation`, one entry per metadata column of the first stream
    /// (nil where a column lacks it). Recorded only; never applied.
    package func readFrameTransformations() throws -> [VeloxScanTransformation?] {
        try HDF5Serial.run {
            let file = try VeloxFile(path: path)
            guard let head = file.children(of: "/Data/SpectrumStream").first else { throw VeloxEMDError.noSpectrumStream }
            let group = "/Data/SpectrumStream/" + head
            let dataset = try file.open(group + "/Metadata")
            let rows = dataset.dims.count == 2 ? dataset.dims[0] : 0, columns = dataset.dims.count == 2 ? dataset.dims[1] : 0
            file.close(dataset)
            try Self.requireFrames(columns, "a Metadata block", group: group, file: file)
            try Self.requireMetadataBytes(rows: rows, columns: columns, group: group)
            var out: [VeloxScanTransformation?] = []
            out.reserveCapacity(columns)
            for column in 0..<columns {
                let json = try file.readMetadataJSON(group: group, column: column)
                out.append((try? VeloxMetadata.parse(jsonData: json))?.scanTransformation)
            }
            return out
        }
    }

    /// Per frame (metadata column), each X-ray segment's RealTime and LiveTime AS READ. SEMANTICS UNVERIFIED:
    /// cumulative in one file, per-frame in another, 0 on the owner's file; recorded, never interpreted.
    package func readFrameDetectorTimes() throws -> [[(name: String, realTime: Double?, liveTime: Double?)]] {
        try HDF5Serial.run {
            let file = try VeloxFile(path: path)
            guard let head = file.children(of: "/Data/SpectrumStream").first else { throw VeloxEMDError.noSpectrumStream }
            let group = "/Data/SpectrumStream/" + head
            let dataset = try file.open(group + "/Metadata")
            let rows = dataset.dims.count == 2 ? dataset.dims[0] : 0, columns = dataset.dims.count == 2 ? dataset.dims[1] : 0
            file.close(dataset)
            try Self.requireFrames(columns, "a Metadata block", group: group, file: file)
            try Self.requireMetadataBytes(rows: rows, columns: columns, group: group)
            var out: [[(name: String, realTime: Double?, liveTime: Double?)]] = []
            for column in 0..<columns {
                let m = try VeloxMetadata.parse(jsonData: file.readMetadataJSON(group: group, column: column))
                out.append(m.superXDetectors.map { ($0.name, $0.realTimeColumn0, $0.liveTimeColumn0) })
            }
            return out
        }
    }

    // MARK: Stored element selection

    /// Symbols by atomic number minus one (H to Lr), the same table rsciio's `atomic_number2name` spells for 1...103.
    private static let elementSymbols = ("H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr "
        + "Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg "
        + "Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr").split(separator: " ").map(String.init)

    /// The element symbols out of a Velox quantification-settings JSON: its `elementSelection`, atomic numbers in the order stored.
    /// nil when the key is missing or empty (Velox keeps no list for a session that selected nothing), and for any number outside 1...103.
    public static func elementSelection(fromSettingsJSON data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["elementSelection"] as? [Any], !list.isEmpty else { return nil }
        var out: [String] = []
        for item in list {
            guard let z = jsonInt(item), z >= 1, z <= elementSymbols.count else { return nil }
            out.append(elementSymbols[z - 1])
        }
        return out
    }

    /// The elements the person had selected in Velox's own quantification, as the file stores them: the first entry (by name, as h5py
    /// iterates) of `Operations/ImageQuantificationOperation` (EMD < 11) or `SharedProperties/EDSSpectrumQuantificationSettings`
    /// (EMD >= 11), each entry a variable-length JSON string; rsciio's `_convert_element_list`. Symbols in the order stored; nil when the
    /// file has no such group or its selection is empty. Never written back: this is what Velox's session knew, not an Auto ID result.
    public func storedElementSelection() throws -> [String]? {
        try HDF5Serial.run {
            let file = try VeloxFile(path: path)
            guard let versionText = file.readString("/Version"), let version = Self.parseVersion(versionText),
                  veloxAcceptsFormat(version.format) else { throw VeloxEMDError.notVelox(formatoDisplayFileName(path)) }
            let major = Int(version.version.split(separator: ".").first ?? "") ?? 0
            let group = major >= 11 ? "/SharedProperties/EDSSpectrumQuantificationSettings" : "/Operations/ImageQuantificationOperation"
            guard let entry = file.children(of: group).first, let text = file.readString(group + "/" + entry) else { return nil }
            return Self.elementSelection(fromSettingsJSON: Data(text.utf8))
        }
    }
}
