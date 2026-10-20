//
//  EMDDatacubeWriter.swift
//  Role: write a 4D datacube (scan rows x scan columns x detector rows x detector columns, float32) as a py4DSTEM `DataCube`
//        in EMD 1.0: `<file>/<root>/<node>/data` chunked one diffraction pattern per chunk, four `dim` axes, an optional
//        calibration group, and the caller's own attributes. The file is built beside the destination and published by
//        atomic rename, so a failed or cancelled write leaves the destination as it was.
//
//  Two ways in. `EMDDatacubeWriter.write(...)` takes the whole cube. The class takes it a band of scan rows at a time, for a
//  cube read from a source with awaits in between (no HDF5 handle and no lock is held between calls).
//
//  Layout (py4DSTEM 0.14, emdfile 0.0.15; the first consumer's output for the details they do not fix):
//    /                                emd_group_type=file, version_major=1, version_minor=0, UUID, authoring_*, + header attributes
//    /<root>                          emd_group_type=root, python_class=Root, + root attributes
//    /<root>/<node>                   emd_group_type=array, python_class=DataCube, + node attributes
//    /<root>/<node>/data              float32 [Rx, Ry, Qx, Qy], chunk [1, 1, Qx, Qy], units="pixel intensity"
//    /<root>/<node>/dim0..dim3        float64 [0, step] (or [0] for an axis of one), name Rx Ry Qx Qy, units
//    /<root>/metadatabundle/calibration   when a calibration is given, targeting /<node>
//

import Foundation
import FormatoCore

/// The shape, identity and annotations of a datacube file.
public nonisolated struct EMDDatacubeLayout: Sendable, Equatable {
    /// `[scanRows, scanColumns, detectorRows, detectorColumns]`, all at least 1.
    public var shape: [Int]
    public var header: EMDFileHeader
    public var rootName: String
    public var nodeName: String
    /// Written as the calibration group, and its pixel sizes and units become the axes (real-space steps on `dim0`, `dim1`,
    /// diffraction steps on `dim2`, `dim3`; a missing step is 1 and missing units are "pixels").
    public var calibration: EMDCalibration?
    public var booleanStorage: EMDBooleanStorage
    /// The names of `dim0...dim3`.
    public var axisNames: [String]
    /// The `units` attribute of `data`.
    public var dataUnits: String
    /// Attributes on the root group and on the DataCube group (caller's: provenance, a derivation record).
    public var rootAttributes: [String: HDF5AttributeValue]
    public var nodeAttributes: [String: HDF5AttributeValue]

    public init(shape: [Int], header: EMDFileHeader, rootName: String = "datacube_root", nodeName: String = "datacube",
                calibration: EMDCalibration? = nil, booleanStorage: EMDBooleanStorage = .h5pyEnum,
                axisNames: [String] = ["Rx", "Ry", "Qx", "Qy"], dataUnits: String = "pixel intensity",
                rootAttributes: [String: HDF5AttributeValue] = [:], nodeAttributes: [String: HDF5AttributeValue] = [:]) {
        self.shape = shape; self.header = header; self.rootName = rootName; self.nodeName = nodeName
        self.calibration = calibration; self.booleanStorage = booleanStorage; self.axisNames = axisNames
        self.dataUnits = dataUnits; self.rootAttributes = rootAttributes; self.nodeAttributes = nodeAttributes
    }
}

/// A datacube file being filled band by band. Not thread-safe; one caller at a time.
public nonisolated final class EMDDatacubeWriter: @unchecked Sendable {
    public let layout: EMDDatacubeLayout
    private let pending: HDF5PendingFile
    private let dataPath: String
    private var nextRow = 0

    /// Starts the file: writes the whole structure and allocates `data` (nothing is read or written for the pixels yet).
    /// - Parameter sourcePath: the file the pixels come from; a destination that is that file (by identity) is refused
    ///   (`destinationIsSource`) before anything is written.
    /// - Throws: `invalidArgument` for a shape or name the layout refuses; `HDF5FileError` otherwise.
    public init(destination: URL, layout: EMDDatacubeLayout, sourcePath: String? = nil) throws {
        guard layout.shape.count == 4, layout.shape.allSatisfy({ $0 >= 1 }) else {
            throw HDF5FileError.invalidArgument("a datacube shape is four extents of at least 1, not \(layout.shape)")
        }
        guard layout.axisNames.count == 4 else { throw HDF5FileError.invalidArgument("a datacube has four axis names") }
        guard let elements = try? FormatoArray.elementCount(layout.shape), !elements.multipliedReportingOverflow(by: 4).overflow else {
            throw HDF5FileError.limitExceeded("the datacube \(layout.shape) is too large")
        }
        self.layout = layout
        let rootPath = try HDF5WriteSession.child("/", layout.rootName)
        let nodePath = try HDF5WriteSession.child(rootPath, layout.nodeName)
        dataPath = try HDF5WriteSession.child(nodePath, "data")
        pending = try HDF5PendingFile(destination: destination, sourcePath: sourcePath)
        do {
            try pending.append { session in
                try session.writeEMDFileHeader(layout.header)
                try session.createEMDRoot(layout.rootName, attributes: layout.rootAttributes)
                try session.createGroup(nodePath)
                try HDF5WriteSession.refuse(layout.nodeAttributes.keys, owned: ["emd_group_type", "python_class"])
                try session.setVariableLengthTextAttribute("emd_group_type", on: nodePath, "array")
                try session.setVariableLengthTextAttribute("python_class", on: nodePath, "DataCube")
                try session.setEMDAttributes(layout.nodeAttributes, on: nodePath)
                let chunk = [1, 1, layout.shape[2], layout.shape[3]]
                try session.createDataset(self.dataPath, dataType: .float32, shape: layout.shape, chunk: chunk)
                try session.setVariableLengthTextAttribute("units", on: self.dataPath, layout.dataUnits)
                let cal = layout.calibration
                let rStep = cal?.rPixelSize ?? 1, qStep = cal?.qPixelSize ?? 1
                let rUnits = cal?.rPixelUnits ?? "pixels", qUnits = cal?.qPixelUnits ?? "pixels"
                let steps = [rStep, rStep, qStep, qStep], units = [rUnits, rUnits, qUnits, qUnits]
                for axis in 0..<4 {
                    try session.writeEMDAxis(nodePath, "dim\(axis)", layout.shape[axis] > 1 ? [0, steps[axis]] : [0],
                                             name: layout.axisNames[axis], units: units[axis])
                }
                if let cal {
                    try session.writeEMDCalibration(cal, inRoot: rootPath, targetPath: "/" + layout.nodeName,
                                                    booleanStorage: layout.booleanStorage)
                }
            }
        } catch {
            pending.discard()
            throw error
        }
    }

    /// Scan rows written so far (rows are written in order from 0).
    public var rowsWritten: Int { nextRow }

    /// Writes the next `rows` scan rows: `values` holds `rows * shape[1] * shape[2] * shape[3]` float32 in C order. Rows go in
    /// order; a band past the end or of the wrong size throws `invalidArgument` and writes nothing.
    public func write(rows: Int, values: [Float]) throws {
        let band = [rows] + Array(layout.shape.dropFirst())
        guard rows >= 1, nextRow + rows <= layout.shape[0] else {
            throw HDF5FileError.invalidArgument("\(rows) rows after \(nextRow) leave a scan of \(layout.shape[0]) rows")
        }
        let array = try FormatoArray(dataType: .float32, shape: band, bytes: values.withUnsafeBytes { Data($0) })
        let start = nextRow
        try pending.append { try $0.writeSlab(dataPath, start: [start, 0, 0, 0], array) }
        nextRow += rows
    }

    /// Publishes the file onto the destination (the item that was there when this writer started is replaced; one that
    /// appeared since is left alone and the call throws `cannotWrite`). Every row must have been written (`invalidArgument`
    /// otherwise, the file left unpublished until `cancel`).
    public func publish() throws {
        guard nextRow == layout.shape[0] else {
            throw HDF5FileError.invalidArgument("\(nextRow) of \(layout.shape[0]) scan rows were written")
        }
        try pending.publish()
    }

    /// Abandons the file and removes the scratch; the destination is untouched.
    public func cancel() { pending.discard() }

    /// Writes a whole cube. `values` is C order, `layout.shape` many float32; the file is published atomically.
    public static func write(_ values: [Float], layout: EMDDatacubeLayout, to destination: URL, sourcePath: String? = nil,
                             cancelled: @Sendable () -> Bool = FormatoCancellation.task) throws {
        let writer = try EMDDatacubeWriter(destination: destination, layout: layout, sourcePath: sourcePath)
        do {
            let rowCount = layout.shape[1] * layout.shape[2] * layout.shape[3]
            guard values.count == layout.shape[0] * rowCount else {
                throw HDF5FileError.invalidArgument("\(values.count) values for the shape \(layout.shape)")
            }
            // Bands of about 16 Mi values keep a large cube's memory flat.
            let rowsPerBand = max(1, (16 << 20) / max(1, rowCount))
            var row = 0
            while row < layout.shape[0] {
                try FormatoCancellation.check(cancelled)
                let rows = min(rowsPerBand, layout.shape[0] - row)
                try writer.write(rows: rows, values: Array(values[(row * rowCount)..<((row + rows) * rowCount)]))
                row += rows
            }
            try FormatoCancellation.check(cancelled)
            try writer.publish()
        } catch {
            writer.cancel()
            throw error
        }
    }
}
