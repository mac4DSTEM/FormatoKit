import Foundation
import Darwin

/// Shared dynamic bindings. Every caller holds HDF5Serial while loading or calling HDF5.
package nonisolated struct SharedHDF5: @unchecked Sendable {
    package typealias H5open = @convention(c) () -> herr_t
    package typealias H5EsetAuto2 = @convention(c) (hid_t, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5Fopen = @convention(c) (UnsafePointer<CChar>?, UInt32, hid_t) -> hid_t
    package typealias H5Close = @convention(c) (hid_t) -> herr_t
    package typealias H5Dopen2 = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> hid_t
    package typealias H5DgetSpace = @convention(c) (hid_t) -> hid_t
    package typealias H5DgetType = @convention(c) (hid_t) -> hid_t
    package typealias H5Dread = @convention(c) (hid_t, hid_t, hid_t, hid_t, hid_t, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5SgetNdims = @convention(c) (hid_t) -> Int32
    package typealias H5SgetDims = @convention(c) (hid_t, UnsafeMutablePointer<hsize_t>?, UnsafeMutablePointer<hsize_t>?) -> Int32
    package typealias H5SselectHyperslab = @convention(c) (hid_t, Int32, UnsafePointer<hsize_t>?, UnsafePointer<hsize_t>?, UnsafePointer<hsize_t>?, UnsafePointer<hsize_t>?) -> herr_t
    package typealias H5ScreateSimple = @convention(c) (Int32, UnsafePointer<hsize_t>?, UnsafePointer<hsize_t>?) -> hid_t
    package typealias H5Tcopy = @convention(c) (hid_t) -> hid_t
    package typealias H5TgetClass = @convention(c) (hid_t) -> Int32
    package typealias H5TisVariableStr = @convention(c) (hid_t) -> Int32
    package typealias H5TgetSize = @convention(c) (hid_t) -> Int
    package typealias H5TgetSign = @convention(c) (hid_t) -> Int32
    package typealias H5Oopen = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> hid_t
    package typealias H5Literate = @convention(c) (hid_t, UnsafePointer<CChar>?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5Lvisit2 = @convention(c) (hid_t, Int32, Int32, H5Literate, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5freeMemory = @convention(c) (UnsafeMutableRawPointer?) -> herr_t

    package typealias H5Aopen = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> hid_t
    package typealias H5Aread = @convention(c) (hid_t, hid_t, UnsafeMutableRawPointer?) -> herr_t
    package let h5aopen: H5Aopen, h5aread: H5Aread, h5aclose: H5Close
    package let h5agetSpace: H5DgetSpace, h5agetType: H5DgetType
    package let h5open: H5open, h5eSetAuto2: H5EsetAuto2, h5fopen: H5Fopen, h5fclose: H5Close
    package let h5dopen2: H5Dopen2, h5dclose: H5Close, h5dgetSpace: H5DgetSpace, h5dgetType: H5DgetType, h5dread: H5Dread
    package let h5sclose: H5Close, h5sgetNdims: H5SgetNdims, h5sgetDims: H5SgetDims
    package let h5sselectHyperslab: H5SselectHyperslab, h5screateSimple: H5ScreateSimple
    package let h5tcopy: H5Tcopy, h5tclose: H5Close, h5tgetClass: H5TgetClass, h5tisVariableStr: H5TisVariableStr
    package let h5tgetSize: H5TgetSize, h5tgetSign: H5TgetSign
    package let h5oopen: H5Oopen, h5oclose: H5Close, h5lvisit2: H5Lvisit2, h5freeMemory: H5freeMemory
    package let uint8: hid_t, uint16: hid_t, uint32: hid_t, uint64: hid_t, float32: hid_t
    /// FormatoKit step 3 (registration step 3 §1.1): the native types a stored-type image read needs beside the above.
    package let int8: hid_t, int16: hid_t, int32: hid_t, int64: hid_t, float64: hid_t

    package static func load(candidates: [String]) throws -> SharedHDF5 {
        var failures: [String] = []
        var handle: UnsafeMutableRawPointer?
        for path in candidates where handle == nil {
            dlerror()
            handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            if handle == nil { failures.append("\(path): \(dlerror().map { String(cString: $0) } ?? "unknown")") }
        }
        guard let handle else { throw HDF5DatacubeError.libraryUnavailable(failures.joined(separator: "\n")) }
        func symbol<T>(_ name: String, as: T.Type) throws -> T {
            guard let p = dlsym(handle, name) else { throw HDF5DatacubeError.libraryUnavailable("missing symbol \(name)") }
            return unsafeBitCast(p, to: T.self)
        }
        func global(_ name: String) throws -> hid_t {
            guard let p = dlsym(handle, name) else { throw HDF5DatacubeError.libraryUnavailable("missing symbol \(name)") }
            return p.assumingMemoryBound(to: hid_t.self).pointee
        }
        let open = try symbol("H5open", as: H5open.self)
        // After H5open, never before: it registers HDF5's atexit teardown (HDF5Types.swift).
        if open() >= 0 { HDF5Serial.installExitBarrier() }
        let auto = try symbol("H5Eset_auto2", as: H5EsetAuto2.self)
        _ = auto(0, nil, nil)     // a probe that finds nothing is an answer, not a stack dump
        return SharedHDF5(
            h5aopen: try symbol("H5Aopen", as: H5Aopen.self), h5aread: try symbol("H5Aread", as: H5Aread.self),
            h5aclose: try symbol("H5Aclose", as: H5Close.self),
            h5agetSpace: try symbol("H5Aget_space", as: H5DgetSpace.self), h5agetType: try symbol("H5Aget_type", as: H5DgetType.self),
            h5open: open, h5eSetAuto2: auto,
            h5fopen: try symbol("H5Fopen", as: H5Fopen.self), h5fclose: try symbol("H5Fclose", as: H5Close.self),
            h5dopen2: try symbol("H5Dopen2", as: H5Dopen2.self), h5dclose: try symbol("H5Dclose", as: H5Close.self),
            h5dgetSpace: try symbol("H5Dget_space", as: H5DgetSpace.self), h5dgetType: try symbol("H5Dget_type", as: H5DgetType.self),
            h5dread: try symbol("H5Dread", as: H5Dread.self),
            h5sclose: try symbol("H5Sclose", as: H5Close.self),
            h5sgetNdims: try symbol("H5Sget_simple_extent_ndims", as: H5SgetNdims.self),
            h5sgetDims: try symbol("H5Sget_simple_extent_dims", as: H5SgetDims.self),
            h5sselectHyperslab: try symbol("H5Sselect_hyperslab", as: H5SselectHyperslab.self),
            h5screateSimple: try symbol("H5Screate_simple", as: H5ScreateSimple.self),
            h5tcopy: try symbol("H5Tcopy", as: H5Tcopy.self), h5tclose: try symbol("H5Tclose", as: H5Close.self),
            h5tgetClass: try symbol("H5Tget_class", as: H5TgetClass.self),
            h5tisVariableStr: try symbol("H5Tis_variable_str", as: H5TisVariableStr.self),
            h5tgetSize: try symbol("H5Tget_size", as: H5TgetSize.self), h5tgetSign: try symbol("H5Tget_sign", as: H5TgetSign.self),
            h5oopen: try symbol("H5Oopen", as: H5Oopen.self), h5oclose: try symbol("H5Oclose", as: H5Close.self),
            h5lvisit2: try symbol("H5Lvisit2", as: H5Lvisit2.self), h5freeMemory: try symbol("H5free_memory", as: H5freeMemory.self),
            uint8: try global("H5T_NATIVE_UINT8_g"), uint16: try global("H5T_NATIVE_UINT16_g"),
            uint32: try global("H5T_NATIVE_UINT32_g"), uint64: try global("H5T_NATIVE_UINT64_g"),
            float32: try global("H5T_NATIVE_FLOAT_g"),
            int8: try global("H5T_NATIVE_INT8_g"), int16: try global("H5T_NATIVE_INT16_g"),
            int32: try global("H5T_NATIVE_INT32_g"), int64: try global("H5T_NATIVE_INT64_g"),
            float64: try global("H5T_NATIVE_DOUBLE_g"))
    }
}

