//
//  EMDBundle.swift
//  Role: the format-level writers of a "scientific bundle" in EMD 1.0 as py4DSTEM / emdfile lay it out: the file header, a root
//        group, a calibration metadata group, scalar result maps (`RealSlice`) and RGBA maps (`Array`), written through an
//        `HDF5WriteSession` so they compose with `HDF5NewFile` (a fresh file), `HDF5AppendWriter` (adding to a file that has
//        other content, a BraggVectors object included) and `EMDDatacubeWriter` (the 4D datacube).
//
//  What stays with the caller: the meaning of the content. Every attribute an application stamps (its schema version, a map's
//  kind or provenance, a lineage record, a load specification) arrives as a caller-supplied attribute or metadata entry and is
//  stored verbatim; this file names no application and invents no key. The layout (group types, python classes, `type` tags on
//  the metadata datasets, `dim0..` axes with `name` and `units`, `_target_paths`) is the one py4DSTEM 0.14 reads, and the
//  first consumer's own output is the reference for the details py4DSTEM does not fix (docs/session-bundle.md).
//
//  Strings are variable-length, as h5py writes a Python `str`: UTF-8 for attributes and datasets alike (py4DSTEM's own files
//  store unit strings as ASCII; UTF-8 is a superset and is what the first consumer writes).
//

import Foundation
import FormatoCore

/// How a boolean calibration value (`QR_flip`) is stored.
public nonisolated enum EMDBooleanStorage: Sendable, Equatable {
    /// h5py's `bool`: an 8-bit enumeration {FALSE, TRUE}. The default, and what py4DSTEM writes.
    case h5pyEnum
    /// A plain unsigned 8-bit integer (0 or 1), as the first consumer writes it. py4DSTEM reads either.
    case uint8
}

/// The attributes of the EMD file root group (`/`): the EMD 1.0 identity plus whatever the caller adds.
public nonisolated struct EMDFileHeader: Sendable, Equatable {
    public var authoringProgram: String
    /// Nil leaves `authoring_user` out; emdfile's own default is the empty text (never a machine account name).
    public var authoringUser: String?
    /// Nil leaves `UUID` out.
    public var uuid: String?
    /// Extra attributes on `/` (for example an acquisition voltage). Text is stored variable-length; numbers as int64 / float64.
    public var attributes: [String: HDF5AttributeValue]

    public init(authoringProgram: String, authoringUser: String? = "", uuid: String? = UUID().uuidString,
                attributes: [String: HDF5AttributeValue] = [:]) {
        self.authoringProgram = authoringProgram
        self.authoringUser = authoringUser
        self.uuid = uuid
        self.attributes = attributes
    }
}

/// Fitted diffraction-origin maps over the scan: `qx0` and `qy0` (and the measured ones) as `shape[0] x shape[1]` float64.
public nonisolated struct EMDOriginMaps: Sendable, Equatable {
    public var shape: [Int]
    public var fittedQX: [Double]
    public var fittedQY: [Double]
    public var measuredQX: [Double]?
    public var measuredQY: [Double]?
    public init(shape: [Int], fittedQX: [Double], fittedQY: [Double], measuredQX: [Double]? = nil, measuredQY: [Double]? = nil) {
        self.shape = shape; self.fittedQX = fittedQX; self.fittedQY = fittedQY
        self.measuredQX = measuredQX; self.measuredQY = measuredQY
    }
}

/// The py4DSTEM `Calibration` metadata group: pixel sizes and units, the diffraction-to-real rotation and flip, the origin
/// (mean and per-position maps), the elliptical distortion and the probe semi-angle. A nil value is not written.
public nonisolated struct EMDCalibration: Sendable, Equatable {
    public var qPixelSize: Double?
    public var qPixelUnits: String?
    public var rPixelSize: Double?
    public var rPixelUnits: String?
    public var qrFlip: Bool?
    /// `QR_rotation`, radians. Its degrees are written beside it (`QR_rotation_degrees`) as `radians * 180 / pi`, unless
    /// `qrRotationDegrees` is set.
    public var qrRotation: Double?
    public var qrRotationDegrees: Double?
    /// The convention the rotation was measured in, as text (written with the rotation only).
    public var qrRotationConvention: String?
    public var qx0Mean: Double?
    public var qy0Mean: Double?
    public var ellipseA: Double?
    public var ellipseB: Double?
    public var ellipseTheta: Double?
    public var probeSemiangle: Double?
    public var originMaps: EMDOriginMaps?

    public init(qPixelSize: Double? = nil, qPixelUnits: String? = nil, rPixelSize: Double? = nil, rPixelUnits: String? = nil,
                qrFlip: Bool? = nil, qrRotation: Double? = nil, qrRotationDegrees: Double? = nil,
                qrRotationConvention: String? = nil, qx0Mean: Double? = nil, qy0Mean: Double? = nil,
                ellipseA: Double? = nil, ellipseB: Double? = nil, ellipseTheta: Double? = nil,
                probeSemiangle: Double? = nil, originMaps: EMDOriginMaps? = nil) {
        self.qPixelSize = qPixelSize; self.qPixelUnits = qPixelUnits; self.rPixelSize = rPixelSize
        self.rPixelUnits = rPixelUnits; self.qrFlip = qrFlip; self.qrRotation = qrRotation
        self.qrRotationDegrees = qrRotationDegrees; self.qrRotationConvention = qrRotationConvention
        self.qx0Mean = qx0Mean; self.qy0Mean = qy0Mean; self.ellipseA = ellipseA; self.ellipseB = ellipseB
        self.ellipseTheta = ellipseTheta; self.probeSemiangle = probeSemiangle; self.originMaps = originMaps
    }

    /// The scalars of a BraggVectors calibration (no origin maps, no rotation convention).
    public init(_ bragg: BraggCalibration) {
        self.init(qPixelSize: bragg.qPixelSize, qPixelUnits: bragg.qPixelUnits, rPixelSize: bragg.rPixelSize,
                  rPixelUnits: bragg.rPixelUnits, qrFlip: bragg.qrFlip, qrRotation: bragg.qrRotation,
                  qrRotationDegrees: bragg.qrRotationDegrees, qx0Mean: bragg.qx0Mean, qy0Mean: bragg.qy0Mean,
                  ellipseA: bragg.ellipseA, ellipseB: bragg.ellipseB, ellipseTheta: bragg.ellipseTheta,
                  probeSemiangle: bragg.probeSemiangle)
    }
}

/// The two axes of a result map (rows then columns): the step between pixels and the units, written as `dim0` and `dim1`
/// (`[0, step]`). The caller resolves any fallback (a map's own pixel size, else the dataset's) before it gets here.
public nonisolated struct EMDMapAxes: Sendable, Equatable {
    public var rowStep: Double
    public var columnStep: Double
    public var units: String
    public init(rowStep: Double = 1, columnStep: Double = 1, units: String = "pixels") {
        self.rowStep = rowStep; self.columnStep = columnStep; self.units = units
    }
}

/// What an application stores beside a map's pixels, verbatim: attributes on the map's group, and a named metadata group
/// (`metadatabundle/<metadataName>`, group type `metadata`, python class `Metadata`) holding one text dataset per entry.
public nonisolated struct EMDMapAnnotations: Sendable, Equatable {
    public var groupAttributes: [String: HDF5AttributeValue]
    public var metadataName: String
    public var metadata: [String: String]
    public init(groupAttributes: [String: HDF5AttributeValue] = [:], metadataName: String = "metadata",
                metadata: [String: String] = [:]) {
        self.groupAttributes = groupAttributes; self.metadataName = metadataName; self.metadata = metadata
    }
}

/// A 2D float32 result map: py4DSTEM `RealSlice` (`data` with `units = "intensity"`, which RealSlice hard-codes; the physical
/// units of the values belong in the annotations).
public nonisolated struct EMDScalarMap: Sendable, Equatable {
    public var nodeName: String
    public var width: Int
    public var height: Int
    /// Row-major, `height * width` values.
    public var values: [Float]
    public var axes: EMDMapAxes
    public var annotations: EMDMapAnnotations
    public init(nodeName: String, width: Int, height: Int, values: [Float], axes: EMDMapAxes = EMDMapAxes(),
                annotations: EMDMapAnnotations = EMDMapAnnotations()) {
        self.nodeName = nodeName; self.width = width; self.height = height; self.values = values
        self.axes = axes; self.annotations = annotations
    }
}

/// An RGBA8 map: py4DSTEM `Array` of shape `height x width x 4` uint8 (`units = "rgba8"`), with a third axis `RGBA`.
public nonisolated struct EMDRGBAMap: Sendable, Equatable {
    public var nodeName: String
    public var width: Int
    public var height: Int
    /// Row-major, `height * width * 4` bytes.
    public var rgba: [UInt8]
    public var axes: EMDMapAxes
    public var annotations: EMDMapAnnotations
    public init(nodeName: String, width: Int, height: Int, rgba: [UInt8], axes: EMDMapAxes = EMDMapAxes(),
                annotations: EMDMapAnnotations = EMDMapAnnotations()) {
        self.nodeName = nodeName; self.width = width; self.height = height; self.rgba = rgba
        self.axes = axes; self.annotations = annotations
    }
}

private nonisolated let ownedFileAttributes: Set<String> = ["emd_group_type", "version_major", "version_minor", "UUID",
                                                           "authoring_program", "authoring_user"]
private nonisolated let ownedGroupAttributes: Set<String> = ["emd_group_type", "python_class"]

extension HDF5WriteSession {
    // MARK: File and root

    /// Writes the EMD 1.0 file identity on `/` (`emd_group_type = file`, `version_major = 1`, `version_minor = 0`, `UUID`,
    /// `authoring_program`, `authoring_user`) and the header's extra attributes. Names the layout owns are refused.
    public func writeEMDFileHeader(_ header: EMDFileHeader) throws {
        try Self.refuse(header.attributes.keys, owned: ownedFileAttributes)
        try setVariableLengthTextAttribute("emd_group_type", on: "/", "file")
        try setAttribute("version_major", on: "/", .integer(1))
        try setAttribute("version_minor", on: "/", .integer(0))
        if let uuid = header.uuid { try setVariableLengthTextAttribute("UUID", on: "/", uuid) }
        try setVariableLengthTextAttribute("authoring_program", on: "/", header.authoringProgram)
        if let user = header.authoringUser { try setVariableLengthTextAttribute("authoring_user", on: "/", user) }
        try setEMDAttributes(header.attributes, on: "/")
    }

    /// Creates the EMD root group `name` (`emd_group_type = root`, `python_class = Root`) and sets the caller's attributes.
    /// An existing group is kept and gets the attributes.
    public func createEMDRoot(_ name: String, attributes: [String: HDF5AttributeValue] = [:]) throws {
        try Self.refuse(attributes.keys, owned: ownedGroupAttributes)
        let path = try Self.child("/", name)
        try createGroup(path)
        try setVariableLengthTextAttribute("emd_group_type", on: path, "root")
        try setVariableLengthTextAttribute("python_class", on: path, "Root")
        try setEMDAttributes(attributes, on: path)
    }

    // MARK: Calibration

    /// Writes `root/metadatabundle/calibration` (group type `metadata`, python class `Calibration`): one scalar float64
    /// dataset per value (`type = number`), `QR_flip` (`type = bool`), the units as text (`type = string`), the origin maps as
    /// float64 matrices (`type = array`) with `qx0_shift` / `qy0_shift` (map minus mean) and, when both measured maps are
    /// there, `qx0_meas` / `qy0_meas`. The origin means are the explicit ones, else the mean of the fitted maps. Origin maps
    /// whose shape and counts disagree are not written (not an error: the scalars still are).
    ///
    /// - Parameters:
    ///   - targetPath: the EMD object this calibration describes, relative to the file (for example `/datacube`); when
    ///     given, `_root_treepath` (empty) and `_target_paths` (a list of one) are written, which is how py4DSTEM attaches
    ///     the calibration to the object. Nil leaves them out.
    ///   - replace: delete an existing calibration group first.
    public func writeEMDCalibration(_ calibration: EMDCalibration, inRoot root: String, targetPath: String? = nil,
                                    booleanStorage: EMDBooleanStorage = .h5pyEnum, replace: Bool = false) throws {
        let bundle = try Self.child(root, "metadatabundle")
        let group = try Self.child(bundle, "calibration")
        if replace, try exists(group) { try deleteLink(group) }
        try createGroup(bundle)
        try setVariableLengthTextAttribute("emd_group_type", on: bundle, "metadatabundle")
        try createGroup(group)
        try setVariableLengthTextAttribute("emd_group_type", on: group, "metadata")
        try setVariableLengthTextAttribute("python_class", on: group, "Calibration")

        if let flip = calibration.qrFlip {
            let path = try Self.child(group, "QR_flip")
            switch booleanStorage {
            case .h5pyEnum: try writeBool(path, flip)
            case .uint8: try writeDataset(path, try FormatoArray(dataType: .uint8, shape: [], bytes: Data([flip ? 1 : 0])))
            }
            try setVariableLengthTextAttribute("type", on: path, "bool")
        }
        func number(_ name: String, _ value: Double?) throws {
            guard let value else { return }
            try writeEMDNumber(try Self.child(group, name), value)
        }
        func text(_ name: String, _ value: String?) throws {
            guard let value else { return }
            let path = try Self.child(group, name)
            try writeText(path, value)
            try setVariableLengthTextAttribute("type", on: path, "string")
        }
        try number("Q_pixel_size", calibration.qPixelSize)
        try text("Q_pixel_units", calibration.qPixelUnits)
        try number("R_pixel_size", calibration.rPixelSize)
        try text("R_pixel_units", calibration.rPixelUnits)
        if let rotation = calibration.qrRotation {
            try number("QR_rotation", rotation)
            try number("QR_rotation_degrees", calibration.qrRotationDegrees ?? rotation * 180 / .pi)
            try text("QR_rotation_convention", calibration.qrRotationConvention)
        } else {
            try number("QR_rotation_degrees", calibration.qrRotationDegrees)
        }
        try number("probe_semiangle", calibration.probeSemiangle)
        try number("a", calibration.ellipseA)
        try number("b", calibration.ellipseB)
        try number("theta", calibration.ellipseTheta)

        var maps: EMDOriginMaps?
        if let candidate = calibration.originMaps, candidate.shape.count == 2, candidate.shape.allSatisfy({ $0 > 0 }) {
            let count = candidate.shape[0] * candidate.shape[1]
            if count == candidate.fittedQX.count, count == candidate.fittedQY.count { maps = candidate }
        }
        let qxMean = calibration.qx0Mean ?? maps.map { $0.fittedQX.reduce(0, +) / Double($0.fittedQX.count) }
        let qyMean = calibration.qy0Mean ?? maps.map { $0.fittedQY.reduce(0, +) / Double($0.fittedQY.count) }
        try number("qx0_mean", qxMean)
        try number("qy0_mean", qyMean)
        if let maps {
            try writeEMDMatrix(try Self.child(group, "qx0"), maps.fittedQX, shape: maps.shape)
            try writeEMDMatrix(try Self.child(group, "qy0"), maps.fittedQY, shape: maps.shape)
            if let qxMean, let qyMean {
                try writeEMDMatrix(try Self.child(group, "qx0_shift"), maps.fittedQX.map { $0 - qxMean }, shape: maps.shape)
                try writeEMDMatrix(try Self.child(group, "qy0_shift"), maps.fittedQY.map { $0 - qyMean }, shape: maps.shape)
            }
            if let mx = maps.measuredQX, let my = maps.measuredQY, mx.count == maps.fittedQX.count, my.count == maps.fittedQY.count {
                try writeEMDMatrix(try Self.child(group, "qx0_meas"), mx, shape: maps.shape)
                try writeEMDMatrix(try Self.child(group, "qy0_meas"), my, shape: maps.shape)
            }
        }
        if let targetPath {
            try text("_root_treepath", "")
            let targets = try Self.child(group, "_target_paths")
            try createGroup(targets)
            try setVariableLengthTextAttribute("type", on: targets, "list_of_strings")
            try setAttribute("length", on: targets, .integer(1))
            try writeText(try Self.child(targets, "0"), targetPath)
        }
    }

    // MARK: Result maps

    /// Writes a scalar float32 map as the EMD node `root/<map.nodeName>`: group type `array`, python class `RealSlice`,
    /// `data` (`height x width`, contiguous, `units = "intensity"`), `dim0` and `dim1` (`[0, step]`, `name` Rx / Ry, `units`),
    /// the annotations' group attributes and its `metadatabundle/<metadataName>` group. `replace` deletes an existing node of
    /// that name first; without it an existing one throws `alreadyExists`.
    public func writeEMDScalarMap(_ map: EMDScalarMap, inRoot root: String, replace: Bool = false) throws {
        guard map.width > 0, map.height > 0, map.values.count == map.width * map.height else {
            throw HDF5FileError.invalidArgument("the scalar map \(map.nodeName) holds \(map.values.count) values for \(map.width) x \(map.height)")
        }
        let node = try beginEMDMap(map.nodeName, in: root, pythonClass: "RealSlice", annotations: map.annotations, replace: replace)
        let data = Data(bytes: map.values, count: map.values.count * MemoryLayout<Float>.size)
        try writeDataset(try Self.child(node, "data"), try FormatoArray(dataType: .float32, shape: [map.height, map.width], bytes: data))
        try setVariableLengthTextAttribute("units", on: try Self.child(node, "data"), "intensity")
        try writeEMDAxis(node, "dim0", [0, map.axes.rowStep], name: "Rx", units: map.axes.units)
        try writeEMDAxis(node, "dim1", [0, map.axes.columnStep], name: "Ry", units: map.axes.units)
        try finishEMDMap(node, annotations: map.annotations)
    }

    /// Writes an RGBA8 map as the EMD node `root/<map.nodeName>`: python class `Array`, `data` (`height x width x 4` uint8,
    /// `units = "rgba8"`), `dim0` and `dim1` as for a scalar map and `dim2` (`[0, 1]`, name `RGBA`, units `channel`).
    public func writeEMDRGBAMap(_ map: EMDRGBAMap, inRoot root: String, replace: Bool = false) throws {
        guard map.width > 0, map.height > 0, map.rgba.count == map.width * map.height * 4 else {
            throw HDF5FileError.invalidArgument("the RGBA map \(map.nodeName) holds \(map.rgba.count) bytes for \(map.width) x \(map.height) x 4")
        }
        let node = try beginEMDMap(map.nodeName, in: root, pythonClass: "Array", annotations: map.annotations, replace: replace)
        try writeDataset(try Self.child(node, "data"), try FormatoArray(dataType: .uint8, shape: [map.height, map.width, 4], bytes: Data(map.rgba)))
        try setVariableLengthTextAttribute("units", on: try Self.child(node, "data"), "rgba8")
        try writeEMDAxis(node, "dim0", [0, map.axes.rowStep], name: "Rx", units: map.axes.units)
        try writeEMDAxis(node, "dim1", [0, map.axes.columnStep], name: "Ry", units: map.axes.units)
        try writeEMDAxis(node, "dim2", [0, 1], name: "RGBA", units: "channel")
        try finishEMDMap(node, annotations: map.annotations)
    }

    // MARK: Shared pieces (also used by EMDDatacubeWriter)

    /// A float64 vector dataset `path` with `name` and `units` text attributes: an EMD axis.
    func writeEMDAxis(_ parent: String, _ name: String, _ values: [Double], name axisName: String, units: String) throws {
        let path = try Self.child(parent, name)
        try writeDataset(path, try FormatoArray(dataType: .float64, shape: [values.count],
                                                bytes: Data(bytes: values, count: values.count * 8)))
        try setVariableLengthTextAttribute("name", on: path, axisName)
        try setVariableLengthTextAttribute("units", on: path, units)
    }

    /// Sets the caller's attributes: text variable-length, the rest through `setAttribute`. Sorted by name for a stable file.
    func setEMDAttributes(_ attributes: [String: HDF5AttributeValue], on path: String) throws {
        for name in attributes.keys.sorted() {
            switch attributes[name]! {
            case .text(let text): try setVariableLengthTextAttribute(name, on: path, text)
            case let other: try setAttribute(name, on: path, other)
            }
        }
    }

    static func refuse(_ names: some Collection<String>, owned: Set<String>) throws {
        for name in names {
            guard !name.isEmpty, !name.utf8.contains(0) else { throw HDF5FileError.invalidArgument("attribute \"\(name)\" has an empty name or a NUL") }
            guard !owned.contains(name) else { throw HDF5FileError.invalidArgument("attribute \"\(name)\" is owned by the EMD layout") }
        }
    }

    /// `parent/name` with `name` one path component.
    static func child(_ parent: String, _ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw HDF5FileError.invalidPath(name)
        }
        return (parent.hasSuffix("/") ? parent : parent + "/") + name
    }

    private func writeEMDNumber(_ path: String, _ value: Double) throws {
        try writeDataset(path, try FormatoArray(dataType: .float64, shape: [], bytes: Data(bytes: [value], count: 8)))
        try setVariableLengthTextAttribute("type", on: path, "number")
    }

    private func writeEMDMatrix(_ path: String, _ values: [Double], shape: [Int]) throws {
        try writeDataset(path, try FormatoArray(dataType: .float64, shape: shape, bytes: Data(bytes: values, count: values.count * 8)))
        try setVariableLengthTextAttribute("type", on: path, "array")
    }

    private func beginEMDMap(_ name: String, in root: String, pythonClass: String, annotations: EMDMapAnnotations,
                             replace: Bool) throws -> String {
        try Self.refuse(annotations.groupAttributes.keys, owned: ownedGroupAttributes)
        let node = try Self.child(root, name)
        guard !annotations.metadataName.isEmpty else { throw HDF5FileError.invalidPath(annotations.metadataName) }
        if try exists(node) {
            guard replace else { throw HDF5FileError.alreadyExists(node) }
            try deleteLink(node)
        }
        try createGroup(node)
        try setVariableLengthTextAttribute("emd_group_type", on: node, "array")
        try setVariableLengthTextAttribute("python_class", on: node, pythonClass)
        try setEMDAttributes(annotations.groupAttributes, on: node)
        return node
    }

    private func finishEMDMap(_ node: String, annotations: EMDMapAnnotations) throws {
        let bundle = try Self.child(node, "metadatabundle")
        try createGroup(bundle)
        try setVariableLengthTextAttribute("emd_group_type", on: bundle, "metadatabundle")
        let metadata = try Self.child(bundle, annotations.metadataName)
        try createGroup(metadata)
        try setVariableLengthTextAttribute("emd_group_type", on: metadata, "metadata")
        try setVariableLengthTextAttribute("python_class", on: metadata, "Metadata")
        for name in annotations.metadata.keys.sorted() {
            let path = try Self.child(metadata, name)
            try writeText(path, annotations.metadata[name]!)
            try setVariableLengthTextAttribute("type", on: path, "string")
        }
    }
}
