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
    // Write-side symbols (FormatoKit Unreleased: BraggVectorsEMD). Same loader, same lock, same exit barrier.
    package typealias H5Fcreate = @convention(c) (UnsafePointer<CChar>?, UInt32, hid_t, hid_t) -> hid_t
    package typealias H5Gcreate2 = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t, hid_t, hid_t) -> hid_t
    package typealias H5Dcreate2 = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t, hid_t, hid_t, hid_t, hid_t) -> hid_t
    package typealias H5Dwrite = @convention(c) (hid_t, hid_t, hid_t, hid_t, hid_t, UnsafeRawPointer?) -> herr_t
    package typealias H5Screate = @convention(c) (Int32) -> hid_t
    package typealias H5Acreate2 = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t, hid_t, hid_t, hid_t) -> hid_t
    package typealias H5Awrite = @convention(c) (hid_t, hid_t, UnsafeRawPointer?) -> herr_t
    package typealias H5Aexists = @convention(c) (hid_t, UnsafePointer<CChar>?) -> Int32
    package typealias H5Tcreate = @convention(c) (Int32, Int) -> hid_t
    package typealias H5Tinsert = @convention(c) (hid_t, UnsafePointer<CChar>?, Int, hid_t) -> herr_t
    package typealias H5TvlenCreate = @convention(c) (hid_t) -> hid_t
    package typealias H5TsetSize = @convention(c) (hid_t, Int) -> herr_t
    package typealias H5TsetCset = @convention(c) (hid_t, Int32) -> herr_t
    package typealias H5TenumCreate = @convention(c) (hid_t) -> hid_t
    package typealias H5TenumInsert = @convention(c) (hid_t, UnsafePointer<CChar>?, UnsafeRawPointer?) -> herr_t
    package let h5fcreate: H5Fcreate, h5gcreate2: H5Gcreate2, h5dcreate2: H5Dcreate2, h5dwrite: H5Dwrite
    package let h5screate: H5Screate, h5acreate2: H5Acreate2, h5awrite: H5Awrite, h5aexists: H5Aexists
    package let h5tcreate: H5Tcreate, h5tinsert: H5Tinsert, h5tvlenCreate: H5TvlenCreate, h5tsetSize: H5TsetSize
    package let h5tsetCset: H5TsetCset, h5tenumCreate: H5TenumCreate, h5tenumInsert: H5TenumInsert
    /// `H5T_C_S1`: the C string type, copied and sized by the writer.
    package let stringC1: hid_t
    // Sidecar-file symbols (FormatoKit Unreleased: HDF5RootAttributes): file-access properties with library-version bounds,
    // string padding, the object header probe and the error stack. Optional ones are nil when the library lacks them.
    package typealias H5Pcreate = @convention(c) (hid_t) -> hid_t
    package typealias H5PsetLibverBounds = @convention(c) (hid_t, Int32, Int32) -> herr_t
    package typealias H5TsetStrpad = @convention(c) (hid_t, Int32) -> herr_t
    package typealias H5SgetNpoints = @convention(c) (hid_t) -> Int64
    package typealias H5OgetNativeInfo = @convention(c) (hid_t, UnsafeMutableRawPointer?, UInt32) -> herr_t
    package typealias H5Eprint2 = @convention(c) (hid_t, UnsafeMutablePointer<FILE>?) -> herr_t
    package let h5pcreate: H5Pcreate, h5pclose: H5Close, h5psetLibverBounds: H5PsetLibverBounds, h5tsetStrpad: H5TsetStrpad
    package let h5sgetNpoints: H5SgetNpoints, h5ogetNativeInfo: H5OgetNativeInfo, h5eprint2: H5Eprint2?
    /// `H5P_CLS_FILE_ACCESS_ID_g`'s value: the file-access property class.
    package let fileAccessClass: hid_t

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
    // Low-level access and append symbols (FormatoKit Unreleased: HDF5Reader, HDF5AppendWriter).
    package typealias H5Ldelete = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> herr_t
    package typealias H5Lexists = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t) -> Int32
    package typealias H5IgetType = @convention(c) (hid_t) -> Int32
    package typealias H5Literate2 = @convention(c) (hid_t, Int32, Int32, UnsafeMutablePointer<hsize_t>?, H5Literate, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5Aoperator = @convention(c) (hid_t, UnsafePointer<CChar>?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5Aiterate2 = @convention(c) (hid_t, Int32, Int32, UnsafeMutablePointer<hsize_t>?, H5Aoperator, UnsafeMutableRawPointer?) -> herr_t
    package typealias H5Adelete = @convention(c) (hid_t, UnsafePointer<CChar>?) -> herr_t
    package typealias H5Ocopy = @convention(c) (hid_t, UnsafePointer<CChar>?, hid_t, UnsafePointer<CChar>?, hid_t, hid_t) -> herr_t
    package typealias H5DgetCreatePlist = @convention(c) (hid_t) -> hid_t
    package typealias H5PgetLayout = @convention(c) (hid_t) -> Int32
    package typealias H5PgetChunk = @convention(c) (hid_t, Int32, UnsafeMutablePointer<hsize_t>?) -> Int32
    package typealias H5PsetChunk = @convention(c) (hid_t, Int32, UnsafePointer<hsize_t>?) -> herr_t
    package let h5ldelete: H5Ldelete, h5lexists: H5Lexists, h5igetType: H5IgetType, h5literate2: H5Literate2
    package let h5aiterate2: H5Aiterate2, h5adelete: H5Adelete, h5psetChunk: H5PsetChunk
    package let h5ocopy: H5Ocopy
    package let h5dgetCreatePlist: H5DgetCreatePlist, h5pgetLayout: H5PgetLayout, h5pgetChunk: H5PgetChunk
    /// `H5P_CLS_DATASET_CREATE_ID_g`'s value: the dataset-creation property class.
    package let datasetCreateClass: hid_t

    /// The standard lookup shared by the HDF5 readers and writers in this package: the `FORMATO_HDF5_PATH` override, the host
    /// app's `Frameworks/libhdf5.dylib`, the copy FormatoKit ships, then the loader's search path. Call under `HDF5Serial`.
    package static func loadStandard() throws -> SharedHDF5 {
        let candidates = [ProcessInfo.processInfo.environment["FORMATO_HDF5_PATH"],
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libhdf5.dylib").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("../Frameworks/libhdf5.dylib").standardized.path,
            FormatoHDF5Library.bundledLibraryPath, "libhdf5.dylib"].compactMap { $0 }
        return try load(candidates: candidates)
    }

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
            h5fcreate: try symbol("H5Fcreate", as: H5Fcreate.self), h5gcreate2: try symbol("H5Gcreate2", as: H5Gcreate2.self),
            h5dcreate2: try symbol("H5Dcreate2", as: H5Dcreate2.self),
            h5dwrite: try symbol("H5Dwrite", as: H5Dwrite.self), h5screate: try symbol("H5Screate", as: H5Screate.self),
            h5acreate2: try symbol("H5Acreate2", as: H5Acreate2.self), h5awrite: try symbol("H5Awrite", as: H5Awrite.self),
            h5aexists: try symbol("H5Aexists", as: H5Aexists.self), h5tcreate: try symbol("H5Tcreate", as: H5Tcreate.self),
            h5tinsert: try symbol("H5Tinsert", as: H5Tinsert.self), h5tvlenCreate: try symbol("H5Tvlen_create", as: H5TvlenCreate.self),
            h5tsetSize: try symbol("H5Tset_size", as: H5TsetSize.self), h5tsetCset: try symbol("H5Tset_cset", as: H5TsetCset.self),
            h5tenumCreate: try symbol("H5Tenum_create", as: H5TenumCreate.self), h5tenumInsert: try symbol("H5Tenum_insert", as: H5TenumInsert.self),
            stringC1: try global("H5T_C_S1_g"),
            h5pcreate: try symbol("H5Pcreate", as: H5Pcreate.self), h5pclose: try symbol("H5Pclose", as: H5Close.self),
            h5psetLibverBounds: try symbol("H5Pset_libver_bounds", as: H5PsetLibverBounds.self),
            h5tsetStrpad: try symbol("H5Tset_strpad", as: H5TsetStrpad.self),
            h5sgetNpoints: try symbol("H5Sget_simple_extent_npoints", as: H5SgetNpoints.self),
            h5ogetNativeInfo: try symbol("H5Oget_native_info", as: H5OgetNativeInfo.self),
            h5eprint2: dlsym(handle, "H5Eprint2").map { unsafeBitCast($0, to: H5Eprint2.self) },
            fileAccessClass: try global("H5P_CLS_FILE_ACCESS_ID_g"),
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
            float64: try global("H5T_NATIVE_DOUBLE_g"),
            h5ldelete: try symbol("H5Ldelete", as: H5Ldelete.self), h5lexists: try symbol("H5Lexists", as: H5Lexists.self),
            h5igetType: try symbol("H5Iget_type", as: H5IgetType.self), h5literate2: try symbol("H5Literate2", as: H5Literate2.self),
            h5aiterate2: try symbol("H5Aiterate2", as: H5Aiterate2.self), h5adelete: try symbol("H5Adelete", as: H5Adelete.self),
            h5psetChunk: try symbol("H5Pset_chunk", as: H5PsetChunk.self),
            h5ocopy: try symbol("H5Ocopy", as: H5Ocopy.self),
            h5dgetCreatePlist: try symbol("H5Dget_create_plist", as: H5DgetCreatePlist.self),
            h5pgetLayout: try symbol("H5Pget_layout", as: H5PgetLayout.self),
            h5pgetChunk: try symbol("H5Pget_chunk", as: H5PgetChunk.self),
            datasetCreateClass: try global("H5P_CLS_DATASET_CREATE_ID_g"))
    }
}

