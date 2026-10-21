//
//  BraggVectorsEMD.swift
//  Role: write and read py4DSTEM `BraggVectors` in EMD 1.0 (the `_v_uncal` peak grid plus the calibration bundle) through the
//        one shared HDF5 loader. The layout is what py4DSTEM 0.14.19 (emdfile 0.0.15) writes and reads; the atomic publish
//        (a temporary file in the item-replacement directory, then rename) and the refusal to publish over the source come from the mac4DSTEM
//        session sidecar writer, whose app-specific attributes, sidecar model and lineage stay in the app and arrive here
//        only through the `extraAttributes` hook.
//

import Foundation
import Darwin
import FormatoCore

/// A failed Bragg-vector read or write.
public nonisolated enum BraggVectorsEMDError: Error, Sendable, Equatable {
    /// libhdf5 could not be loaded.
    case libraryUnavailable(String)
    /// The file could not be opened as HDF5.
    case cannotOpen(String)
    /// The file is HDF5 but is not a readable BraggVectors object (missing groups, wrong shapes, damaged data).
    case malformed(String)
    /// A valid layout this reader does not take (for example several BraggVectors objects and no `groupPath`).
    case unsupported(String)
    /// An argument the writer refuses (shape mismatch, non-finite peak, reserved or empty attribute name, bad node name).
    case invalidInput(String)
    /// The destination is the source file; nothing was written.
    case destinationIsSource(String)
    /// An HDF5 call failed while writing; the destination is unchanged.
    case writeFailed(String)
    /// The finished temporary file could not be moved onto the destination; the destination is unchanged.
    case publishFailed(String)
}

/// One detected Bragg peak as py4DSTEM stores it: `qx` is the first detector axis (the row), `qy` the second (the column),
/// `intensity` the peak weight, all float64.
///
/// With ``BraggAxisConvention/appImageXY`` the same fields carry image coordinates instead: `qx` is the column (x) and `qy`
/// the row (y), and the file gets the swapped values.
public nonisolated struct BraggPeak: Sendable, Hashable {
    public var qx: Double
    public var qy: Double
    public var intensity: Double
    public init(qx: Double, qy: Double, intensity: Double) {
        self.qx = qx; self.qy = qy; self.intensity = intensity
    }
}

/// How ``BraggPeak/qx`` and ``BraggPeak/qy`` relate to the stored `qx` (row) and `qy` (column) fields.
public nonisolated enum BraggAxisConvention: Sendable {
    /// py4DSTEM's own: the peak's `qx` and `qy` are the stored fields (qx = detector row, qy = detector column). Primary,
    /// pinned to py4DSTEM 0.14.19.
    case py4DSTEM
    /// mac4DSTEM's image convention (x = column, y = row): the peak's `qx` is x and `qy` is y, so the file holds
    /// `qx = peak.qy` (row) and `qy = peak.qx` (column). Pinned to the app's own output.
    case appImageXY
}

/// A grid size: rows first, then columns, as py4DSTEM's `Rshape` and `Qshape`.
public nonisolated struct BraggGridShape: Sendable, Hashable {
    public var rows: Int
    public var columns: Int
    public init(rows: Int, columns: Int) { self.rows = rows; self.columns = columns }
}

/// The py4DSTEM `Calibration` scalars that travel with a BraggVectors object. A nil value is not written, and reads back as
/// py4DSTEM's own default. Origin maps are not part of the BraggVectors bundle here.
public nonisolated struct BraggCalibration: Sendable, Equatable {
    public var qPixelSize: Double?
    public var qPixelUnits: String?
    public var rPixelSize: Double?
    public var rPixelUnits: String?
    public var qrFlip: Bool?
    /// `QR_rotation` as stored (radians in py4DSTEM's calibration).
    public var qrRotation: Double?
    public var qrRotationDegrees: Double?
    public var qx0Mean: Double?
    public var qy0Mean: Double?
    public var ellipseA: Double?
    public var ellipseB: Double?
    public var ellipseTheta: Double?
    public var probeSemiangle: Double?
    public init(qPixelSize: Double? = nil, qPixelUnits: String? = nil, rPixelSize: Double? = nil, rPixelUnits: String? = nil,
                qrFlip: Bool? = nil, qrRotation: Double? = nil, qrRotationDegrees: Double? = nil,
                qx0Mean: Double? = nil, qy0Mean: Double? = nil, ellipseA: Double? = nil, ellipseB: Double? = nil,
                ellipseTheta: Double? = nil, probeSemiangle: Double? = nil) {
        self.qPixelSize = qPixelSize; self.qPixelUnits = qPixelUnits; self.rPixelSize = rPixelSize
        self.rPixelUnits = rPixelUnits; self.qrFlip = qrFlip; self.qrRotation = qrRotation
        self.qrRotationDegrees = qrRotationDegrees; self.qx0Mean = qx0Mean; self.qy0Mean = qy0Mean
        self.ellipseA = ellipseA; self.ellipseB = ellipseB; self.ellipseTheta = ellipseTheta
        self.probeSemiangle = probeSemiangle
    }
}

/// The three HDF5 objects of a BraggVectors file that can carry caller attributes.
public nonisolated enum BraggAttributeTarget: Sendable, Hashable, CaseIterable {
    /// The file (the HDF5 root `/`).
    case file
    /// The EMD root group (`braggvectors_root` in py4DSTEM).
    case root
    /// The BraggVectors group itself (`braggvectors`).
    case braggVectors
}

/// py4DSTEM `BraggVectors` in EMD 1.0: the raw (`_v_uncal`) peaks of every scan position, the scan and detector shapes and
/// the calibration scalars.
///
/// ``write(peaks:scan:detector:calibration:to:convention:rootName:nodeName:authoringProgram:sourcePath:extraAttributes:cancelled:)``
/// publishes atomically; ``read(path:groupPath:convention:attributeNames:)`` loads everything (peak grids are small next to
/// the datacubes they come from). Both run under ``HDF5Serial`` and the one shared loader.
public nonisolated struct BraggVectorsEMD: Sendable {
    /// The scan grid (py4DSTEM `Rshape`): rows (y) first.
    public let scan: BraggGridShape
    /// The detector shape (py4DSTEM `Qshape`).
    public let detector: BraggGridShape
    /// Peaks of every scan position in row-major order (`index = row * scan.columns + column`), in the axis convention the
    /// file was read with.
    public let peaks: [[BraggPeak]]
    /// The calibration scalars present in the file.
    public let calibration: BraggCalibration
    /// The HDF5 path of the BraggVectors group that was read, for example `/braggvectors_root/braggvectors`.
    public let groupPath: String
    /// The string attributes asked for by name on each target, when present.
    public let attributes: [BraggAttributeTarget: [String: String]]

    /// The peaks of one scan position. Precondition: inside the scan.
    public func peaks(row: Int, column: Int) -> [BraggPeak] { peaks[row * scan.columns + column] }

    /// The total number of peaks in the file.
    public var peakCount: Int { peaks.reduce(0) { $0 + $1.count } }

    // MARK: Write

    /// Write BraggVectors to `destination` as a py4DSTEM EMD 1.0 file and publish it atomically.
    ///
    /// The file is built in the item-replacement directory (beside the destination if the system gives none) and renamed onto it only when complete, so a failed
    /// or cancelled write leaves the destination exactly as it was and no temporary file behind. A `destination` that is the
    /// `sourcePath` file (by file identity, so a symlink or a different spelling counts) is refused before anything is
    /// written.
    ///
    /// - Parameters:
    ///   - peaks: Row-major peaks of every scan position (`scan.rows * scan.columns` arrays, empty arrays allowed). Every
    ///     value must be finite.
    ///   - scan: py4DSTEM `Rshape`.
    ///   - detector: py4DSTEM `Qshape`.
    ///   - calibration: Scalars to write into `metadatabundle/calibration`; nil ones are omitted.
    ///   - convention: How the peaks' `qx`/`qy` map onto the stored fields.
    ///   - rootName: The EMD root group (py4DSTEM names it after the object plus `_root`).
    ///   - nodeName: The BraggVectors group inside it.
    ///   - authoringProgram: Stored in the file's `authoring_program` attribute.
    ///   - sourcePath: The file the vectors were detected from, if any; the destination may not be it.
    ///   - extraAttributes: Called once per ``BraggAttributeTarget``; the string attributes it returns are written on that
    ///     object (for example an app's own provenance). Names the EMD layout owns are refused.
    ///   - cancelled: Polled between scan rows and before the publish; throws `FormatoCancelled`.
    public static func write(
        peaks: [[BraggPeak]], scan: BraggGridShape, detector: BraggGridShape,
        calibration: BraggCalibration = BraggCalibration(), to destination: URL,
        convention: BraggAxisConvention = .py4DSTEM,
        rootName: String = "braggvectors_root", nodeName: String = "braggvectors",
        authoringProgram: String = "FormatoKit", sourcePath: String? = nil,
        extraAttributes: (@Sendable (BraggAttributeTarget) -> [String: String])? = nil,
        cancelled: @Sendable () -> Bool = FormatoCancellation.task
    ) throws {
        try EMDWriter.publish(
            peaks: peaks, scan: scan, detector: detector, calibration: calibration, destination: destination,
            convention: convention, rootName: rootName, nodeName: nodeName, authoringProgram: authoringProgram,
            sourcePath: sourcePath, extraAttributes: extraAttributes, cancelled: cancelled)
    }

    // MARK: Read

    /// Read BraggVectors from a py4DSTEM EMD 1.0 file.
    ///
    /// - Parameters:
    ///   - path: The HDF5 file.
    ///   - groupPath: The BraggVectors group (`/braggvectors_root/braggvectors`). When nil the file is searched: exactly one
    ///     group with `python_class == "BraggVectors"` at the top or one level down must exist.
    ///   - convention: How to hand the stored `qx`/`qy` fields back.
    ///   - attributeNames: String attributes to fetch by name from the file, root and BraggVectors group (an app's own).
    /// - Throws: ``BraggVectorsEMDError``; never traps on a damaged or truncated file.
    public static func read(
        path: String, groupPath: String? = nil, convention: BraggAxisConvention = .py4DSTEM,
        attributeNames: [String] = []
    ) throws -> BraggVectorsEMD {
        try EMDReader.read(path: path, groupPath: groupPath, convention: convention, attributeNames: attributeNames)
    }
}

// MARK: - Shared constants

private nonisolated let h5Default: hid_t = 0
private nonisolated let h5EntireSpace: hid_t = 0
private nonisolated let h5Truncate: UInt32 = 0x0002
private nonisolated let h5ReadOnly: UInt32 = 0x0000
private nonisolated let h5Scalar: Int32 = 0
private nonisolated let h5ClassInteger: Int32 = 0
private nonisolated let h5ClassFloat: Int32 = 1
private nonisolated let h5ClassString: Int32 = 3
private nonisolated let h5ClassCompound: Int32 = 6
private nonisolated let h5ClassEnum: Int32 = 8
private nonisolated let h5ClassVlen: Int32 = 9
private nonisolated let h5CsetUTF8: Int32 = 1
private nonisolated let maxPositions = 1 << 26

private nonisolated struct PeakRecord { var qx: Double; var qy: Double; var intensity: Double }
private nonisolated struct HVL { var length: Int; var pointer: UnsafeMutableRawPointer? }

private nonisolated let fileReserved: Set<String> = ["emd_group_type", "version_major", "version_minor", "UUID", "authoring_program", "authoring_user"]
private nonisolated let groupReserved: Set<String> = ["emd_group_type", "python_class"]

private nonisolated func wrap(_ error: HDF5DatacubeError) -> BraggVectorsEMDError {
    switch error {
    case .libraryUnavailable(let m): .libraryUnavailable(m)
    case .cannotOpen(let m): .cannotOpen(m)
    case .malformed(let m): .malformed(m)
    case .unsupported(let m): .unsupported(m)
    case .readFailed(let m): .malformed(m)
    }
}

private nonisolated func loadLibrary() throws -> SharedHDF5 {
    do { return try SharedHDF5.loadStandard() } catch let e as HDF5DatacubeError { throw wrap(e) }
}

// MARK: - Writer

private nonisolated struct EMDWriter {
    let h5: SharedHDF5
    private func fail(_ what: String) -> BraggVectorsEMDError { .writeFailed(what) }

    static func publish(
        peaks: [[BraggPeak]], scan: BraggGridShape, detector: BraggGridShape, calibration: BraggCalibration,
        destination: URL, convention: BraggAxisConvention, rootName: String, nodeName: String, authoringProgram: String,
        sourcePath: String?, extraAttributes: (@Sendable (BraggAttributeTarget) -> [String: String])?,
        cancelled: @Sendable () -> Bool
    ) throws {
        guard scan.rows > 0, scan.columns > 0, scan.rows <= Int(Int32.max), scan.columns <= Int(Int32.max),
              scan.rows * scan.columns <= maxPositions else {
            throw BraggVectorsEMDError.invalidInput("scan shape \(scan.rows) x \(scan.columns) is outside 1...\(maxPositions) positions")
        }
        guard detector.rows > 0, detector.columns > 0 else {
            throw BraggVectorsEMDError.invalidInput("detector shape must be positive")
        }
        guard peaks.count == scan.rows * scan.columns else {
            throw BraggVectorsEMDError.invalidInput("\(peaks.count) peak arrays for a \(scan.rows) x \(scan.columns) scan")
        }
        for name in [rootName, nodeName] {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw BraggVectorsEMDError.invalidInput("invalid group name \"\(name)\"")
            }
        }
        guard !authoringProgram.contains("\0") else { throw BraggVectorsEMDError.invalidInput("authoring program contains NUL") }
        for cell in peaks { for p in cell where !(p.qx.isFinite && p.qy.isFinite && p.intensity.isFinite) {
            throw BraggVectorsEMDError.invalidInput("a peak holds a non-finite value")
        } }
        var extras: [BraggAttributeTarget: [String: String]] = [:]
        for target in BraggAttributeTarget.allCases {
            let values = extraAttributes?(target) ?? [:]
            let reserved = target == .file ? fileReserved : groupReserved
            for (key, value) in values {
                guard !key.isEmpty, !key.contains("\0"), !value.contains("\0") else {
                    throw BraggVectorsEMDError.invalidInput("attribute \"\(key)\" has an empty name or a NUL")
                }
                guard !reserved.contains(key) else {
                    throw BraggVectorsEMDError.invalidInput("attribute \"\(key)\" is owned by the EMD layout")
                }
            }
            extras[target] = values
        }
        for text in [calibration.qPixelUnits, calibration.rPixelUnits] where text?.contains("\0") == true {
            throw BraggVectorsEMDError.invalidInput("calibration units contain NUL")
        }
        if let sourcePath, sameFile(destination, URL(fileURLWithPath: sourcePath)) {
            throw BraggVectorsEMDError.destinationIsSource("the destination is the source file: \(destination.path)")
        }
        try FormatoCancellation.check(cancelled)

        // Built in the system's item-replacement directory (writable under the sandbox, same volume), else beside the destination.
        let (temporary, scratchDirectory) = HDF5RootAttributes.temporaryURL(for: destination, namePrefix: ".bragg-")
        var published = false
        defer {
            if !published { _ = unlink(temporary.path) }
            if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        }
        try HDF5Serial.run {
            let writer = EMDWriter(h5: try loadLibrary())
            try writer.writeFile(
                at: temporary.path, peaks: peaks, scan: scan, detector: detector, calibration: calibration,
                convention: convention, rootName: rootName, nodeName: nodeName, authoringProgram: authoringProgram,
                extras: extras, cancelled: cancelled)
        }
        try FormatoCancellation.check(cancelled)
        guard rename(temporary.path, destination.path) == 0 else {
            throw BraggVectorsEMDError.publishFailed(String(cString: strerror(errno)))
        }
        published = true
    }

    /// One file under two spellings (a symlink, a differently written path): by file identity as well as by path.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let ra = a.standardizedFileURL.resolvingSymlinksInPath(), rb = b.standardizedFileURL.resolvingSymlinksInPath()
        if ra == rb { return true }
        var sa = stat(), sb = stat()
        if stat(ra.path, &sa) == 0, stat(rb.path, &sb) == 0 { return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino }
        return false
    }

    func writeFile(
        at path: String, peaks: [[BraggPeak]], scan: BraggGridShape, detector: BraggGridShape, calibration: BraggCalibration,
        convention: BraggAxisConvention, rootName: String, nodeName: String, authoringProgram: String,
        extras: [BraggAttributeTarget: [String: String]], cancelled: @Sendable () -> Bool
    ) throws {
        let file = path.withCString { h5.h5fcreate($0, h5Truncate, h5Default, h5Default) }
        guard file >= 0 else { throw BraggVectorsEMDError.publishFailed("cannot create the temporary file") }
        defer { _ = h5.h5fclose(file) }
        try stringAttribute("emd_group_type", "file", on: file)
        try int64Attribute("version_major", 1, on: file)
        try int64Attribute("version_minor", 0, on: file)
        try stringAttribute("UUID", UUID().uuidString.lowercased(), on: file)
        try stringAttribute("authoring_program", authoringProgram, on: file)
        try stringAttribute("authoring_user", "", on: file)
        try extra(extras[.file], on: file)

        let root = try group(rootName, in: file); defer { _ = h5.h5close(root) }
        try stringAttribute("emd_group_type", "root", on: root)
        try stringAttribute("python_class", "Root", on: root)
        try extra(extras[.root], on: root)
        try writeCalibration(calibration, target: "/" + nodeName, in: root)

        try writeNode(nodeName, in: root, peaks: peaks, scan: scan, detector: detector, convention: convention,
                      extras: extras, cancelled: cancelled)
    }

    /// The BraggVectors group (its shape bundle and `_v_uncal` peak grid) inside the open group `root`.
    func writeNode(_ nodeName: String, in root: hid_t, peaks: [[BraggPeak]], scan: BraggGridShape, detector: BraggGridShape,
                   convention: BraggAxisConvention, extras: [BraggAttributeTarget: [String: String]],
                   cancelled: @Sendable () -> Bool) throws {
        let node = try group(nodeName, in: root); defer { _ = h5.h5close(node) }
        try stringAttribute("emd_group_type", "custom", on: node)
        try stringAttribute("python_class", "BraggVectors", on: node)
        try extra(extras[.braggVectors], on: node)
        let bundle = try group("metadatabundle", in: node); defer { _ = h5.h5close(bundle) }
        try stringAttribute("emd_group_type", "metadatabundle", on: bundle)
        let shape = try group("_braggvectors_shape", in: bundle); defer { _ = h5.h5close(shape) }
        try stringAttribute("emd_group_type", "metadata", on: shape)
        try stringAttribute("python_class", "Metadata", on: shape)
        try int64Vector("Qshape", [Int64(detector.rows), Int64(detector.columns)], type: "tuple", in: shape)
        try int64Vector("Rshape", [Int64(scan.rows), Int64(scan.columns)], type: "tuple", in: shape)

        let grid = try group("_v_uncal", in: node); defer { _ = h5.h5close(grid) }
        try stringAttribute("emd_group_type", "custom_pointlistarray", on: grid)
        try stringAttribute("python_class", "PointListArray", on: grid)
        try writePeakGrid(peaks, scan: scan, convention: convention, in: grid, cancelled: cancelled)
    }

    // MARK: Peak grid

    private func peakType() throws -> (compound: hid_t, vlen: hid_t) {
        let compound = h5.h5tcreate(6, MemoryLayout<PeakRecord>.stride)
        guard compound >= 0 else { throw fail("creating the peak compound type") }
        guard "qx".withCString({ h5.h5tinsert(compound, $0, MemoryLayout<PeakRecord>.offset(of: \.qx)!, h5.float64) }) >= 0,
              "qy".withCString({ h5.h5tinsert(compound, $0, MemoryLayout<PeakRecord>.offset(of: \.qy)!, h5.float64) }) >= 0,
              "intensity".withCString({ h5.h5tinsert(compound, $0, MemoryLayout<PeakRecord>.offset(of: \.intensity)!, h5.float64) }) >= 0
        else { _ = h5.h5tclose(compound); throw fail("defining the peak fields") }
        let vlen = h5.h5tvlenCreate(compound)
        guard vlen >= 0 else { _ = h5.h5tclose(compound); throw fail("creating the variable-length peak type") }
        return (compound, vlen)
    }

    private func writePeakGrid(_ peaks: [[BraggPeak]], scan: BraggGridShape, convention: BraggAxisConvention,
                               in grid: hid_t, cancelled: @Sendable () -> Bool) throws {
        let (compound, vlen) = try peakType()
        defer { _ = h5.h5tclose(vlen); _ = h5.h5tclose(compound) }
        var dims = [hsize_t(scan.rows), hsize_t(scan.columns)]
        let space = h5.h5screateSimple(2, &dims, nil)
        guard space >= 0 else { throw fail("creating the peak-grid dataspace") }
        defer { _ = h5.h5sclose(space) }
        let dataset = "data".withCString { h5.h5dcreate2(grid, $0, vlen, space, h5Default, h5Default, h5Default) }
        guard dataset >= 0 else { throw fail("creating the peak-grid dataset") }
        defer { _ = h5.h5dclose(dataset) }

        // One contiguous record buffer for the whole grid; each cell points into it.
        var records: [PeakRecord] = []
        records.reserveCapacity(peaks.reduce(0) { $0 + $1.count })
        for row in 0..<scan.rows {
            try FormatoCancellation.check(cancelled)
            for column in 0..<scan.columns {
                for p in peaks[row * scan.columns + column] {
                    switch convention {
                    case .py4DSTEM: records.append(PeakRecord(qx: p.qx, qy: p.qy, intensity: p.intensity))
                    case .appImageXY: records.append(PeakRecord(qx: p.qy, qy: p.qx, intensity: p.intensity))
                    }
                }
            }
        }
        var cells = [HVL](repeating: HVL(length: 0, pointer: nil), count: peaks.count)
        let status: herr_t = records.withUnsafeMutableBytes { raw in
            var offset = 0
            for (i, cell) in peaks.enumerated() where !cell.isEmpty {
                cells[i] = HVL(length: cell.count, pointer: raw.baseAddress! + offset * MemoryLayout<PeakRecord>.stride)
                offset += cell.count
            }
            return cells.withUnsafeBytes { h5.h5dwrite(dataset, vlen, h5EntireSpace, h5EntireSpace, h5Default, $0.baseAddress) }
        }
        guard status >= 0 else { throw fail("writing the peak grid") }
    }

    // MARK: Calibration

    private func writeCalibration(_ c: BraggCalibration, target: String, in root: hid_t) throws {
        let bundle = try group("metadatabundle", in: root); defer { _ = h5.h5close(bundle) }
        try stringAttribute("emd_group_type", "metadatabundle", on: bundle)
        let cal = try group("calibration", in: bundle); defer { _ = h5.h5close(cal) }
        try stringAttribute("emd_group_type", "metadata", on: cal)
        try stringAttribute("python_class", "Calibration", on: cal)
        if let v = c.qrFlip { try boolDataset("QR_flip", v, in: cal) }
        let numbers: [(String, Double?)] = [
            ("Q_pixel_size", c.qPixelSize), ("R_pixel_size", c.rPixelSize), ("QR_rotation", c.qrRotation),
            ("QR_rotation_degrees", c.qrRotationDegrees), ("qx0_mean", c.qx0Mean), ("qy0_mean", c.qy0Mean),
            ("a", c.ellipseA), ("b", c.ellipseB), ("theta", c.ellipseTheta), ("probe_semiangle", c.probeSemiangle)]
        for (name, value) in numbers { if let value { try doubleDataset(name, value, in: cal) } }
        if let v = c.qPixelUnits { try stringDataset("Q_pixel_units", v, type: "string", in: cal) }
        if let v = c.rPixelUnits { try stringDataset("R_pixel_units", v, type: "string", in: cal) }
        try stringDataset("_root_treepath", "", type: "string", in: cal)
        let targets = try group("_target_paths", in: cal); defer { _ = h5.h5close(targets) }
        try stringAttribute("type", "list_of_strings", on: targets)
        try int64Attribute("length", 1, on: targets)
        try stringDataset("0", target, type: nil, in: targets)
    }

    // MARK: Primitives

    private func group(_ name: String, in parent: hid_t) throws -> hid_t {
        let id = name.withCString { h5.h5gcreate2(parent, $0, h5Default, h5Default, h5Default) }
        guard id >= 0 else { throw fail("creating group \(name)") }
        return id
    }

    /// Attribute strings are UTF-8 variable-length, as h5py writes a Python str.
    private func stringType(utf8: Bool) throws -> hid_t {
        let t = h5.h5tcopy(h5.stringC1)
        guard t >= 0, h5.h5tsetSize(t, -1) >= 0, !utf8 || h5.h5tsetCset(t, h5CsetUTF8) >= 0 else {
            if t >= 0 { _ = h5.h5tclose(t) }
            throw fail("creating a string type")
        }
        return t
    }

    private func extra(_ values: [String: String]?, on object: hid_t) throws {
        for key in (values ?? [:]).keys.sorted() { try stringAttribute(key, values![key]!, on: object) }
    }

    private func stringAttribute(_ name: String, _ value: String, on object: hid_t) throws {
        let type = try stringType(utf8: true); defer { _ = h5.h5tclose(type) }
        let space = h5.h5screate(h5Scalar); guard space >= 0 else { throw fail("attribute \(name)") }
        defer { _ = h5.h5sclose(space) }
        let attribute = name.withCString { h5.h5acreate2(object, $0, type, space, h5Default, h5Default) }
        guard attribute >= 0 else { throw fail("creating attribute \(name)") }
        defer { _ = h5.h5aclose(attribute) }
        let status = value.withCString { characters -> herr_t in
            var pointer: UnsafePointer<CChar>? = characters
            return withUnsafePointer(to: &pointer) { h5.h5awrite(attribute, type, $0) }
        }
        guard status >= 0 else { throw fail("writing attribute \(name)") }
    }

    private func int64Attribute(_ name: String, _ value: Int64, on object: hid_t) throws {
        let space = h5.h5screate(h5Scalar); guard space >= 0 else { throw fail("attribute \(name)") }
        defer { _ = h5.h5sclose(space) }
        let attribute = name.withCString { h5.h5acreate2(object, $0, h5.int64, space, h5Default, h5Default) }
        guard attribute >= 0 else { throw fail("creating attribute \(name)") }
        defer { _ = h5.h5aclose(attribute) }
        var v = value
        guard withUnsafePointer(to: &v, { h5.h5awrite(attribute, h5.int64, $0) }) >= 0 else { throw fail("writing attribute \(name)") }
    }

    /// Creates a scalar dataset, writes `bytes` from memory type `memory`, and tags it with py4DSTEM's `type` attribute.
    private func scalarDataset(_ name: String, fileType: hid_t, memory: hid_t, tag: String?, in parent: hid_t,
                               write: (hid_t) -> herr_t) throws {
        let space = h5.h5screate(h5Scalar); guard space >= 0 else { throw fail("dataset \(name)") }
        defer { _ = h5.h5sclose(space) }
        let dataset = name.withCString { h5.h5dcreate2(parent, $0, fileType, space, h5Default, h5Default, h5Default) }
        guard dataset >= 0 else { throw fail("creating dataset \(name)") }
        defer { _ = h5.h5dclose(dataset) }
        guard write(dataset) >= 0 else { throw fail("writing dataset \(name)") }
        if let tag { try stringAttribute("type", tag, on: dataset) }
    }

    private func doubleDataset(_ name: String, _ value: Double, in parent: hid_t) throws {
        var v = value
        try scalarDataset(name, fileType: h5.float64, memory: h5.float64, tag: "number", in: parent) { ds in
            withUnsafePointer(to: &v) { h5.h5dwrite(ds, h5.float64, h5EntireSpace, h5EntireSpace, h5Default, $0) }
        }
    }

    /// h5py's bool: an int8 enum {FALSE = 0, TRUE = 1}.
    private func boolDataset(_ name: String, _ value: Bool, in parent: hid_t) throws {
        let type = h5.h5tenumCreate(h5.int8); guard type >= 0 else { throw fail("creating the bool type") }
        defer { _ = h5.h5tclose(type) }
        var f: Int8 = 0, t: Int8 = 1
        guard "FALSE".withCString({ h5.h5tenumInsert(type, $0, &f) }) >= 0,
              "TRUE".withCString({ h5.h5tenumInsert(type, $0, &t) }) >= 0 else { throw fail("defining the bool type") }
        var v: Int8 = value ? 1 : 0
        try scalarDataset(name, fileType: type, memory: type, tag: "bool", in: parent) { ds in
            withUnsafePointer(to: &v) { h5.h5dwrite(ds, type, h5EntireSpace, h5EntireSpace, h5Default, $0) }
        }
    }

    /// py4DSTEM stores its strings as variable-length ASCII; units and paths stay ASCII-typed for it.
    private func stringDataset(_ name: String, _ value: String, type tag: String?, in parent: hid_t) throws {
        let type = try stringType(utf8: false); defer { _ = h5.h5tclose(type) }
        try scalarDataset(name, fileType: type, memory: type, tag: tag, in: parent) { ds in
            value.withCString { characters -> herr_t in
                var pointer: UnsafePointer<CChar>? = characters
                return withUnsafePointer(to: &pointer) { h5.h5dwrite(ds, type, h5EntireSpace, h5EntireSpace, h5Default, $0) }
            }
        }
    }

    private func int64Vector(_ name: String, _ values: [Int64], type tag: String, in parent: hid_t) throws {
        var dims = [hsize_t(values.count)]
        let space = h5.h5screateSimple(1, &dims, nil); guard space >= 0 else { throw fail("dataset \(name)") }
        defer { _ = h5.h5sclose(space) }
        let dataset = name.withCString { h5.h5dcreate2(parent, $0, h5.int64, space, h5Default, h5Default, h5Default) }
        guard dataset >= 0 else { throw fail("creating dataset \(name)") }
        defer { _ = h5.h5dclose(dataset) }
        guard values.withUnsafeBytes({ h5.h5dwrite(dataset, h5.int64, h5EntireSpace, h5EntireSpace, h5Default, $0.baseAddress) }) >= 0
        else { throw fail("writing dataset \(name)") }
        try stringAttribute("type", tag, on: dataset)
    }
}

private extension SharedHDF5 {
    /// Closes any object id (group, dataset, file) with the matching call: HDF5 1.x/2.x close each by its own function, and
    /// `H5Oclose` closes groups and datasets; files go through `h5fclose`.
    func h5close(_ id: hid_t) -> herr_t { h5oclose(id) }
}

// MARK: - Reader

private nonisolated final class LinkCollector: @unchecked Sendable { var names: [String] = [] }
private nonisolated let collectLink: @convention(c)
    (hid_t, UnsafePointer<CChar>?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> herr_t = { _, name, _, context in
        guard let name, let context else { return 0 }
        Unmanaged<LinkCollector>.fromOpaque(context).takeUnretainedValue().names.append(String(cString: name))
        return 0
    }

private nonisolated struct EMDReader {
    let h5: SharedHDF5
    let file: hid_t
    private func bad(_ what: String) -> BraggVectorsEMDError { .malformed(what) }

    static func read(path: String, groupPath: String?, convention: BraggAxisConvention, attributeNames: [String]) throws -> BraggVectorsEMD {
        try HDF5Serial.run {
            let h5 = try loadLibrary()
            _ = h5.h5eSetAuto2(0, nil, nil)
            let file = path.withCString { h5.h5fopen($0, h5ReadOnly, h5Default) }
            guard file >= 0 else { throw BraggVectorsEMDError.cannotOpen(path) }
            defer { _ = h5.h5fclose(file) }
            return try EMDReader(h5: h5, file: file).run(groupPath: groupPath, convention: convention, attributeNames: attributeNames)
        }
    }

    private func run(groupPath: String?, convention: BraggAxisConvention, attributeNames: [String]) throws -> BraggVectorsEMD {
        let node = try locate(groupPath)
        let parent = (node as NSString).deletingLastPathComponent
        let rootPath = parent == "/" ? "" : parent
        let rShape = try shapeVector(node + "/metadatabundle/_braggvectors_shape/Rshape")
        let qShape = try shapeVector(node + "/metadatabundle/_braggvectors_shape/Qshape")
        let peaks = try peakGrid(node + "/_v_uncal/data", scan: rShape, convention: convention)
        let calibration = try readCalibration(rootPath + "/metadatabundle/calibration")
        var attributes: [BraggAttributeTarget: [String: String]] = [:]
        for (target, location) in [(BraggAttributeTarget.file, "/"), (.root, rootPath.isEmpty ? "/" : rootPath), (.braggVectors, node)] {
            var found: [String: String] = [:]
            for name in attributeNames { if let v = try stringAttribute(name, at: location) { found[name] = v } }
            attributes[target] = found
        }
        return BraggVectorsEMD(scan: BraggGridShape(rows: rShape[0], columns: rShape[1]),
                               detector: BraggGridShape(rows: qShape[0], columns: qShape[1]),
                               peaks: peaks, calibration: calibration, groupPath: node, attributes: attributes)
    }

    // MARK: Location

    private func locate(_ explicit: String?) throws -> String {
        if let explicit {
            let path = explicit.hasPrefix("/") ? explicit : "/" + explicit
            guard try stringAttribute("python_class", at: path) == "BraggVectors" else {
                throw bad("\(path) is not a BraggVectors group")
            }
            return path
        }
        let collector = LinkCollector()
        _ = h5.h5lvisit2(file, 0, 0, collectLink, Unmanaged.passUnretained(collector).toOpaque())
        var found: [String] = []
        for name in collector.names.sorted() where name.split(separator: "/").count <= 2 {
            if try stringAttribute("python_class", at: "/" + name) == "BraggVectors" { found.append("/" + name) }
        }
        switch found.count {
        case 0: throw bad("no BraggVectors group in the file")
        case 1: return found[0]
        default: throw BraggVectorsEMDError.unsupported("several BraggVectors groups (\(found.joined(separator: ", "))): pass groupPath")
        }
    }

    // MARK: Datasets

    private func dims(_ space: hid_t) throws -> [Int] {
        guard space >= 0 else { throw bad("dataspace") }
        let rank = h5.h5sgetNdims(space)
        guard rank >= 0, rank <= 32 else { throw bad("invalid rank") }
        if rank == 0 { return [] }
        var d = [hsize_t](repeating: 0, count: Int(rank))
        guard h5.h5sgetDims(space, &d, nil) >= 0, d.allSatisfy({ $0 <= UInt64(Int32.max) }) else { throw bad("invalid dimensions") }
        return d.map(Int.init)
    }

    private func shapeVector(_ path: String) throws -> [Int] {
        let ds = path.withCString { h5.h5dopen2(file, $0, h5Default) }
        guard ds >= 0 else { throw bad("missing \(path)") }
        defer { _ = h5.h5dclose(ds) }
        let space = h5.h5dgetSpace(ds); defer { _ = h5.h5sclose(space) }
        let type = h5.h5dgetType(ds); defer { _ = h5.h5tclose(type) }
        guard try dims(space) == [2], h5.h5tgetClass(type) == h5ClassInteger else { throw bad("\(path) is not an integer pair") }
        var values = [Int64](repeating: 0, count: 2)
        guard values.withUnsafeMutableBytes({ h5.h5dread(ds, h5.int64, h5EntireSpace, h5EntireSpace, h5Default, $0.baseAddress) }) >= 0
        else { throw bad("reading \(path)") }
        guard values.allSatisfy({ $0 > 0 && $0 <= Int64(Int32.max) }) else { throw bad("\(path) is not a positive shape: \(values)") }
        return values.map(Int.init)
    }

    private func peakGrid(_ path: String, scan: [Int], convention: BraggAxisConvention) throws -> [[BraggPeak]] {
        let ds = path.withCString { h5.h5dopen2(file, $0, h5Default) }
        guard ds >= 0 else { throw bad("missing \(path)") }
        defer { _ = h5.h5dclose(ds) }
        let space = h5.h5dgetSpace(ds); defer { _ = h5.h5sclose(space) }
        let fileType = h5.h5dgetType(ds); defer { _ = h5.h5tclose(fileType) }
        guard h5.h5tgetClass(fileType) == h5ClassVlen else { throw bad("\(path) is not a variable-length peak grid") }
        guard try dims(space) == scan else { throw bad("\(path) does not match Rshape \(scan)") }
        guard scan[0] * scan[1] <= maxPositions else {
            throw BraggVectorsEMDError.unsupported("scan of \(scan[0] * scan[1]) positions is above the \(maxPositions) limit")
        }
        let positions = scan[0] * scan[1]
        // Memory type: vlen of {qx, qy, intensity} float64; HDF5 matches compound members by name.
        let compound = h5.h5tcreate(h5ClassCompound, MemoryLayout<PeakRecord>.stride)
        guard compound >= 0 else { throw bad("peak type") }
        defer { _ = h5.h5tclose(compound) }
        guard "qx".withCString({ h5.h5tinsert(compound, $0, 0, h5.float64) }) >= 0,
              "qy".withCString({ h5.h5tinsert(compound, $0, 8, h5.float64) }) >= 0,
              "intensity".withCString({ h5.h5tinsert(compound, $0, 16, h5.float64) }) >= 0 else { throw bad("peak fields") }
        let memory = h5.h5tvlenCreate(compound)
        guard memory >= 0 else { throw bad("peak vlen type") }
        defer { _ = h5.h5tclose(memory) }
        var cells = [HVL](repeating: HVL(length: 0, pointer: nil), count: positions)
        let status = cells.withUnsafeMutableBytes { h5.h5dread(ds, memory, h5EntireSpace, h5EntireSpace, h5Default, $0.baseAddress) }
        // The library owns each cell's buffer: free every one exactly once, whatever happens next.
        defer { for cell in cells { if let p = cell.pointer { _ = h5.h5freeMemory(p) } } }
        guard status >= 0 else { throw bad("reading the peak grid (damaged or incompatible peak type)") }
        var out = [[BraggPeak]](repeating: [], count: positions)
        for i in 0..<positions {
            let cell = cells[i]
            guard cell.length > 0 else { continue }
            guard let pointer = cell.pointer, cell.length <= Int(Int32.max) else { throw bad("a peak cell is malformed") }
            let records = pointer.assumingMemoryBound(to: PeakRecord.self)
            out[i] = (0..<cell.length).map { k in
                let r = records[k]
                switch convention {
                case .py4DSTEM: return BraggPeak(qx: r.qx, qy: r.qy, intensity: r.intensity)
                case .appImageXY: return BraggPeak(qx: r.qy, qy: r.qx, intensity: r.intensity)
                }
            }
        }
        return out
    }

    // MARK: Calibration

    private func readCalibration(_ group: String) throws -> BraggCalibration {
        var c = BraggCalibration()
        c.qPixelSize = try number("Q_pixel_size", group)
        c.rPixelSize = try number("R_pixel_size", group)
        c.qrRotation = try number("QR_rotation", group)
        c.qrRotationDegrees = try number("QR_rotation_degrees", group)
        c.qx0Mean = try number("qx0_mean", group)
        c.qy0Mean = try number("qy0_mean", group)
        c.ellipseA = try number("a", group)
        c.ellipseB = try number("b", group)
        c.ellipseTheta = try number("theta", group)
        c.probeSemiangle = try number("probe_semiangle", group)
        c.qrFlip = try number("QR_flip", group, allowEnum: true).map { $0 != 0 }
        c.qPixelUnits = try text("Q_pixel_units", group)
        c.rPixelUnits = try text("R_pixel_units", group)
        return c
    }

    private func scalarDataset(_ name: String, _ group: String) throws -> (ds: hid_t, type: hid_t)? {
        let path = group + "/" + name
        let ds = path.withCString { h5.h5dopen2(file, $0, h5Default) }
        guard ds >= 0 else { return nil }
        let space = h5.h5dgetSpace(ds); defer { _ = h5.h5sclose(space) }
        guard (try? dims(space)) == [] || (try? dims(space)) == [1] else { _ = h5.h5dclose(ds); throw bad("\(path) is not a scalar") }
        return (ds, h5.h5dgetType(ds))
    }

    private func number(_ name: String, _ group: String, allowEnum: Bool = false) throws -> Double? {
        guard let (ds, type) = try scalarDataset(name, group) else { return nil }
        defer { _ = h5.h5dclose(ds); _ = h5.h5tclose(type) }
        let cls = h5.h5tgetClass(type)
        var v: Double = 0
        if allowEnum, cls == h5ClassEnum || cls == h5ClassInteger {
            var i: Int32 = 0
            guard withUnsafeMutableBytes(of: &i, { h5.h5dread(ds, h5.int32, h5EntireSpace, h5EntireSpace, h5Default, $0.baseAddress) }) >= 0
            else { throw bad("reading \(group)/\(name)") }
            return Double(i)
        }
        guard cls == h5ClassFloat || cls == h5ClassInteger else { throw bad("\(group)/\(name) is not numeric") }
        guard withUnsafeMutableBytes(of: &v, { h5.h5dread(ds, h5.float64, h5EntireSpace, h5EntireSpace, h5Default, $0.baseAddress) }) >= 0
        else { throw bad("reading \(group)/\(name)") }
        return v
    }

    private func text(_ name: String, _ group: String) throws -> String? {
        guard let (ds, type) = try scalarDataset(name, group) else { return nil }
        defer { _ = h5.h5dclose(ds); _ = h5.h5tclose(type) }
        guard h5.h5tgetClass(type) == h5ClassString else { throw bad("\(group)/\(name) is not a string") }
        return try readString(type: type, key: name) { h5.h5dread(ds, type, h5EntireSpace, h5EntireSpace, h5Default, $0) }
    }

    private func readString(type: hid_t, key: String, read: (UnsafeMutableRawPointer?) -> herr_t) throws -> String {
        if h5.h5tisVariableStr(type) > 0 {
            var pointer: UnsafeMutablePointer<CChar>?
            let status = withUnsafeMutableBytes(of: &pointer) { read($0.baseAddress) }
            guard status >= 0, let pointer else { throw bad("reading \(key)") }
            defer { _ = h5.h5freeMemory(pointer) }
            return String(cString: pointer)
        }
        let n = h5.h5tgetSize(type)
        guard n > 0, n < 65536 else { throw bad("invalid string size for \(key)") }
        var bytes = [CChar](repeating: 0, count: n + 1)
        guard bytes.withUnsafeMutableBytes({ read($0.baseAddress) }) >= 0 else { throw bad("reading \(key)") }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A string attribute of the object at `path`; nil when the object or attribute is absent.
    private func stringAttribute(_ name: String, at path: String) throws -> String? {
        let object = path.withCString { h5.h5oopen(file, $0, h5Default) }
        guard object >= 0 else { return nil }
        defer { _ = h5.h5oclose(object) }
        let attribute = name.withCString { h5.h5aopen(object, $0, h5Default) }
        guard attribute >= 0 else { return nil }
        defer { _ = h5.h5aclose(attribute) }
        let type = h5.h5agetType(attribute); defer { _ = h5.h5tclose(type) }
        guard h5.h5tgetClass(type) == h5ClassString else { throw bad("attribute \(name) of \(path) is not a string") }
        return try readString(type: type, key: name) { h5.h5aread(attribute, type, $0) }
    }
}

// MARK: - In a session

extension HDF5WriteSession {
    /// Writes the BraggVectors object (py4DSTEM's layout: the group `nodeName` with its `_braggvectors_shape` bundle and the
    /// `_v_uncal` peak grid) into the existing group `root` of the file this session is changing, so a file that also holds a
    /// calibration, results or copied objects gets the peaks without a second file. The group and root must already exist
    /// (`createGroup`, `createEMDRoot`); `nodeName` must not. `groupAttributes` are written on the BraggVectors group.
    /// Peaks are row-major (`scan.rows * scan.columns` arrays); every value must be finite.
    public func writeBraggVectors(
        peaks: [[BraggPeak]], scan: BraggGridShape, detector: BraggGridShape, inRoot root: String,
        nodeName: String = "braggvectors", convention: BraggAxisConvention = .py4DSTEM,
        groupAttributes: [String: String] = [:], cancelled: @Sendable () -> Bool = FormatoCancellation.task
    ) throws {
        guard scan.rows > 0, scan.columns > 0, detector.rows > 0, detector.columns > 0 else {
            throw BraggVectorsEMDError.invalidInput("the scan and detector shapes must be positive")
        }
        guard peaks.count == scan.rows * scan.columns else {
            throw BraggVectorsEMDError.invalidInput("\(peaks.count) peak lists for a \(scan.rows) x \(scan.columns) scan")
        }
        guard peaks.allSatisfy({ $0.allSatisfy { $0.qx.isFinite && $0.qy.isFinite && $0.intensity.isFinite } }) else {
            throw BraggVectorsEMDError.invalidInput("a peak value is not finite")
        }
        guard !groupAttributes.keys.contains(where: { groupReserved.contains($0) }) else {
            throw BraggVectorsEMDError.invalidInput("a group attribute name belongs to the EMD layout")
        }
        let parts = try HDF5Ops.components(root)
        try withHandle { h5, file in
            guard HDF5Ops.linkExists(h5, file, parts) else { throw HDF5FileError.notFound(root) }
            let id = HDF5Ops.absolute(parts).withCString { h5.h5oopen(file, $0, 0) }
            guard id >= 0 else { throw HDF5FileError.notFound(root) }
            defer { _ = h5.h5oclose(id) }
            guard !nodeName.isEmpty, !nodeName.contains("/"), !"\(nodeName)".utf8.contains(0) else { throw HDF5FileError.invalidPath(nodeName) }
            guard !nodeName.withCString({ h5.h5lexists(id, $0, 0) }).isPositive else {
                throw HDF5FileError.invalidArgument("\(root)/\(nodeName) already exists")
            }
            do {
                try EMDWriter(h5: h5).writeNode(nodeName, in: id, peaks: peaks, scan: scan, detector: detector, convention: convention,
                                                extras: [.braggVectors: groupAttributes], cancelled: cancelled)
            } catch {
                _ = nodeName.withCString { h5.h5ldelete(id, $0, 0) }
                if let error = error as? BraggVectorsEMDError {
                    throw HDF5FileError.cannotWrite(operation: "writing the BraggVectors object", detail: "\(error)")
                }
                throw error
            }
        }
    }
}

private extension Int32 { var isPositive: Bool { self > 0 } }
