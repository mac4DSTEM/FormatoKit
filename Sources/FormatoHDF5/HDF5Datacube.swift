import Foundation
import FormatoCore

/// A failed HDF5 read, unsupported layout, or malformed calibration.
public nonisolated enum HDF5DatacubeError: Error, Sendable, Equatable {
    case libraryUnavailable(String)
    case cannotOpen(String)
    case malformed(String)
    case unsupported(String)
    case readFailed(String)
}

/// An explicitly selected rank-four dataset in stored C order, without transposing the scan or detector axes.
/// Opening reads only the shape, type and calibration; hyperslabs read only the requested region through HDF5,
/// including compressed/chunked files. Keep the file unchanged while a reader or its lazy signal exists.
/// App-specific sidecar recognition and dataset selection belong to the caller.
public nonisolated struct HDF5Datacube: FormatoLazyArray {
    private let storage: CubeStorage
    private let calibrationPath: String
    public let shape: [Int]
    public let dataType: FormatoDataType
    /// Calibration axes in stored order; the first two navigate, the last two describe diffraction.
    public let axes: [FormatoAxis]
    /// Scalar py4DSTEM calibration entries as stored, with their HDF5 path and interpretation.
    public let calibration: FormatoMetadata
    /// The selected HDF5 dataset path.
    public let datasetPath: String

    /// Open a numeric four-dimensional dataset using FormatoKit's shared HDF5 loader.
    public init(path: String, datasetPath: String) throws {
        let storage = try CubeStorage(path: path)
        let info = try storage.describe(datasetPath)
        guard info.shape.count == 4 else { throw HDF5DatacubeError.unsupported("Expected rank 4: \(info.shape)") }
        guard info.shape.allSatisfy({ $0 > 0 }) else { throw HDF5DatacubeError.malformed("Empty datacube") }
        _ = try checkedBytes(info.shape, info.type)
        self.storage = storage
        self.datasetPath = datasetPath
        shape = info.shape
        dataType = info.type
        let parent = (datasetPath as NSString).deletingLastPathComponent
        let root = (parent as NSString).deletingLastPathComponent
        let calPath = (root == "/" ? "" : root) + "/metadatabundle/calibration"
        calibrationPath = calPath
        var metadata = FormatoMetadata()
        for key in ["R_pixel_size", "Q_pixel_size", "R_pixel_units", "Q_pixel_units", "QR_flip",
                    "QR_rotation", "QR_rotation_degrees", "qx0_mean", "qy0_mean", "a", "b", "theta", "probe_semiangle"] {
            if let value = try storage.scalar(key, group: calPath) {
                metadata.set(FormatoMetadataEntry(key: key, value: value, units: nil,
                    provenance: FormatoProvenance(file: URL(fileURLWithPath: path).lastPathComponent,
                        source: calPath + "/" + key, rule: "py4DSTEM calibration, stored value")))
            }
        }
        calibration = metadata
        var result: [FormatoAxis] = []
        for i in 0..<4 {
            let prefix = i < 2 ? "R" : "Q"
            let dimPath = parent + "/dim\(i)"
            let dim = try storage.dim(dimPath, size: shape[i])
            let scale = metadata[prefix + "_pixel_size"]?.value.number ?? dim?.scale ?? 1
            let units = metadata[prefix + "_pixel_units"]?.value.text ?? dim?.units ?? "pixels"
            result.append(FormatoAxis(name: dim?.name, size: shape[i], scale: scale,
                offset: dim?.offset ?? 0, units: units, navigate: i < 2))
        }
        axes = result
    }

    /// The datacube as a lazy FormatoCore signal, with stored calibration metadata.
    public var signal: FormatoLazySignal {
        FormatoLazySignal(title: (datasetPath as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "",
            signalType: "electron_diffraction", axes: axes, metadata: calibration, array: self)
    }

    /// A lazy fitted or measured origin map in the datacube's stored scan order.
    /// Returns nil if absent; a present map must have exactly the two scan dimensions.
    public func originMap(_ component: HDF5OriginComponent) throws -> (any FormatoLazyArray)? {
        let path = calibrationPath + "/" + component.rawValue
        guard storage.exists(path) else { return nil }
        let info = try storage.describe(path)
        guard info.shape == Array(shape.prefix(2)) else { throw HDF5DatacubeError.malformed("Origin map shape: \(path)") }
        _ = try checkedBytes(info.shape, info.type)
        return CubeArray(storage: storage, path: path, shape: info.shape, dataType: info.type)
    }

    /// Read a rectangular hyperslab in stored order, preserving the numeric type and bits.
    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        return try storage.read(datasetPath, shape: shape, type: dataType, start: start, count: count)
    }
}

/// py4DSTEM's fitted and measured per-position detector origin components.
public nonisolated enum HDF5OriginComponent: String, Sendable, CaseIterable {
    case fittedX = "qx0", fittedY = "qy0", measuredX = "qx0_meas", measuredY = "qy0_meas"
}

private nonisolated struct CubeArray: FormatoLazyArray {
    let storage: CubeStorage
    let path: String
    let shape: [Int]
    let dataType: FormatoDataType
    func read(start: [Int], count: [Int]) throws -> FormatoArray {
        try FormatoArray.validateSlab(start: start, count: count, shape: shape)
        return try storage.read(path, shape: shape, type: dataType, start: start, count: count)
    }
}

private func checkedBytes(_ shape: [Int], _ type: FormatoDataType) throws -> Int {
    let n = try FormatoArray.elementCount(shape)
    let (bytes, overflow) = n.multipliedReportingOverflow(by: type.byteSize)
    guard !overflow else { throw HDF5DatacubeError.malformed("Byte count overflows") }
    return bytes
}

// Immutable file handle. All accesses, including destruction, hold the process-wide recursive lock.
private nonisolated final class CubeStorage: @unchecked Sendable {
    let h5: SharedHDF5
    let file: hid_t
    init(path: String) throws {
        (h5, file) = try HDF5Serial.run {
            let lib = try SharedHDF5.loadStandard()
            let id = path.withCString { lib.h5fopen($0, 0, 0) }
            guard id >= 0 else { throw HDF5DatacubeError.cannotOpen(path) }
            return (lib, id)
        }
    }
    deinit { HDF5Serial.run { _ = h5.h5fclose(file) } }
    private func silence() { _ = h5.h5eSetAuto2(0, nil, nil) }
    func exists(_ path: String) -> Bool {
        HDF5Serial.run {
            silence()
            let id = path.withCString { h5.h5oopen(file, $0, 0) }
            guard id >= 0 else { return false }
            _ = h5.h5oclose(id)
            return true
        }
    }
    private func dataset(_ path: String) throws -> hid_t {
        let ds = path.withCString { h5.h5dopen2(file, $0, 0) }
        guard ds >= 0 else { throw HDF5DatacubeError.readFailed(path) }
        return ds
    }
    private func dimensions(_ space: hid_t) throws -> [Int] {
        guard space >= 0 else { throw HDF5DatacubeError.readFailed("dataspace") }
        let rank = h5.h5sgetNdims(space)
        guard rank >= 0, rank <= 32 else { throw HDF5DatacubeError.malformed("Invalid rank") }
        if rank == 0 { return [] }
        var dims = [hsize_t](repeating: 0, count: Int(rank))
        guard h5.h5sgetDims(space, &dims, nil) >= 0,
              dims.allSatisfy({ $0 <= UInt64(Int.max) }) else { throw HDF5DatacubeError.malformed("Invalid dimensions") }
        let shape = dims.map(Int.init)
        _ = try FormatoArray.elementCount(shape)
        return shape
    }
    func describe(_ path: String) throws -> (shape: [Int], type: FormatoDataType) {
        try HDF5Serial.run {
            silence()
            let ds = try dataset(path); defer { _ = h5.h5dclose(ds) }
            let space = h5.h5dgetSpace(ds); defer { _ = h5.h5sclose(space) }
            let type = h5.h5dgetType(ds); defer { _ = h5.h5tclose(type) }
            let size = h5.h5tgetSize(type), cls = h5.h5tgetClass(type)
            let name = cls == 1 ? "float\(size * 8)" : cls == 0 ? "\(h5.h5tgetSign(type) == 1 ? "int" : "uint")\(size * 8)" : "unsupported"
            guard let dtype = FormatoDataType(rawValue: name) else { throw HDF5DatacubeError.unsupported("HDF5 type \(name)") }
            return (try dimensions(space), dtype)
        }
    }
    private func native(_ type: FormatoDataType) throws -> hid_t {
        switch type {
        case .float32: h5.float32
        case .float64: h5.float64
        case .uint8: h5.uint8
        case .uint16: h5.uint16
        case .uint32: h5.uint32
        case .uint64: h5.uint64
        case .int8: h5.int8
        case .int16: h5.int16
        case .int32: h5.int32
        case .int64: h5.int64
        default: throw HDF5DatacubeError.unsupported(type.rawValue)
        }
    }
    func read(_ path: String, shape: [Int], type: FormatoDataType, start: [Int], count: [Int]) throws -> FormatoArray {
        try HDF5Serial.run {
            silence()
            let n = try checkedBytes(count, type)
            var bytes = Data(count: n)
            if n > 0 {
                let ds = try dataset(path); defer { _ = h5.h5dclose(ds) }
                let space = h5.h5dgetSpace(ds); defer { _ = h5.h5sclose(space) }
                guard try dimensions(space) == shape else { throw HDF5DatacubeError.malformed("Dataset shape changed") }
                let c = count.map(UInt64.init), s = start.map(UInt64.init)
                guard h5.h5sselectHyperslab(space, 0, s, nil, c, nil) >= 0 else { throw HDF5DatacubeError.readFailed("hyperslab") }
                let mem = h5.h5screateSimple(Int32(c.count), c, nil)
                guard mem >= 0 else { throw HDF5DatacubeError.readFailed("memory space") }
                defer { _ = h5.h5sclose(mem) }
                let nativeType = try native(type)
                let status = bytes.withUnsafeMutableBytes { h5.h5dread(ds, nativeType, mem, space, 0, $0.baseAddress) }
                guard status >= 0 else { throw HDF5DatacubeError.readFailed(path) }
            }
            return try FormatoArray(dataType: type, shape: count, bytes: bytes)
        }
    }

    // A scalar dataset takes precedence over the older attribute representation.
    func scalar(_ key: String, group: String) throws -> FormatoValue? {
        try HDF5Serial.run {
            silence()
            let path = group + "/" + key
            let ds = path.withCString { h5.h5dopen2(file, $0, 0) }
            if ds >= 0 {
                defer { _ = h5.h5dclose(ds) }
                let space = h5.h5dgetSpace(ds); defer { _ = h5.h5sclose(space) }
                let type = h5.h5dgetType(ds); defer { _ = h5.h5tclose(type) }
                guard try FormatoArray.elementCount(dimensions(space)) == 1 else { throw HDF5DatacubeError.malformed("Non-scalar \(path)") }
                return try value(type: type, key: key) { h5.h5dread(ds, $0, 0, 0, 0, $1) }
            }
            return try attribute(key, path: group)
        }
    }
    private func attribute(_ key: String, path: String) throws -> FormatoValue? {
        let obj = path.withCString { h5.h5oopen(file, $0, 0) }
        guard obj >= 0 else { return nil }; defer { _ = h5.h5oclose(obj) }
        let attr = key.withCString { h5.h5aopen(obj, $0, 0) }
        guard attr >= 0 else { return nil }; defer { _ = h5.h5aclose(attr) }
        let space = h5.h5agetSpace(attr); defer { _ = h5.h5sclose(space) }
        guard try FormatoArray.elementCount(dimensions(space)) == 1 else { throw HDF5DatacubeError.malformed("Non-scalar attribute \(key)") }
        let type = h5.h5agetType(attr); defer { _ = h5.h5tclose(type) }
        return try value(type: type, key: key) { h5.h5aread(attr, $0, $1) }
    }
    private func value(type: hid_t, key: String, read: (hid_t, UnsafeMutableRawPointer?) -> herr_t) throws -> FormatoValue {
        let cls = h5.h5tgetClass(type)
        if cls == 3 {
            if h5.h5tisVariableStr(type) > 0 {
                var ptr: UnsafeMutablePointer<CChar>?
                let status = withUnsafeMutableBytes(of: &ptr) { read(type, $0.baseAddress) }
                guard status >= 0, let ptr else { throw HDF5DatacubeError.readFailed(key) }
                defer { _ = h5.h5freeMemory(ptr) }
                return .text(String(cString: ptr))
            }
            let n = h5.h5tgetSize(type)
            guard n > 0, n < 65536 else { throw HDF5DatacubeError.malformed("Invalid string size") }
            var bytes = [CChar](repeating: 0, count: n + 1)
            guard bytes.withUnsafeMutableBytes({ read(type, $0.baseAddress) }) >= 0 else { throw HDF5DatacubeError.readFailed(key) }
            return .text(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        if key == "QR_flip" {
            var v: Int32 = 0
            guard withUnsafeMutableBytes(of: &v, { read(h5.int32, $0.baseAddress) }) >= 0 else { throw HDF5DatacubeError.readFailed(key) }
            return .flag(v != 0)
        }
        guard cls == 0 || cls == 1 else { throw HDF5DatacubeError.unsupported("Calibration type for \(key)") }
        var v: Double = 0
        guard withUnsafeMutableBytes(of: &v, { read(h5.float64, $0.baseAddress) }) >= 0 else { throw HDF5DatacubeError.readFailed(key) }
        return .number(v)
    }
    func dim(_ path: String, size: Int) throws -> (name: String?, units: String?, scale: Double?, offset: Double)? {
        try HDF5Serial.run {
            silence()
            let obj = path.withCString { h5.h5oopen(file, $0, 0) }
            guard obj >= 0 else { return nil }; _ = h5.h5oclose(obj)
            let info = try describe(path)
            guard info.shape.count == 1, info.shape[0] == 2 || info.shape[0] == size else {
                throw HDF5DatacubeError.malformed("Dimension vector length: \(path)")
            }
            let n = info.shape[0]
            let values = try read(path, shape: info.shape, type: info.type, start: [0], count: [min(n, 2)]).doubles()
            let scale: Double? = n > 1 ? values[1] - values[0] : nil
            if n > 2, let scale {
                // Full coordinate vectors must be exactly representable by FormatoCore's uniform axis.
                // Check in bounded blocks, without loading a potentially large vector all at once.
                for first in stride(from: 0, to: n, by: 4096) {
                    let block = try read(path, shape: info.shape, type: info.type,
                        start: [first], count: [min(4096, n - first)]).doubles()
                    guard block.enumerated().allSatisfy({ i, value in value == values[0] + Double(first + i) * scale }) else {
                        throw HDF5DatacubeError.unsupported("Nonuniform dimension vector: \(path)")
                    }
                }
            }
            return (try attribute("name", path: path)?.text, try attribute("units", path: path)?.text,
                    scale, values[0])
        }
    }
}
