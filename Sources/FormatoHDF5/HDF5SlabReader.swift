//
//  HDF5SlabReader.swift
//  Role: repeated hyperslab reads of one numeric dataset through a file and dataset handle held open, for a consumer that
//        reads many small pieces (one diffraction pattern per call). `HDF5Reader` opens the file for every call; this
//        opens it once. The bytes are the ones `HDF5Reader.readDataset` returns.
//
//  Every call holds `HDF5Serial` for its own duration; the handles live as long as the reader (closed by `close()` or `deinit`,
//  also under the lock). Do not hold a reader across an `await` that something else must pass through: like every HDF5 user in the
//  kit, a call takes the process-wide lock, and a reader only keeps a file open, never the lock.
//

import Foundation
import Darwin
import FormatoCore

public nonisolated final class HDF5SlabReader: @unchecked Sendable {
    public let url: URL
    public let path: String
    /// The dataset's shape (C order) and stored element type, read once at `init`.
    public let shape: [Int]
    public let dataType: FormatoDataType

    private let h5: SharedHDF5
    private var file: hid_t
    private var dataset: hid_t
    private var space: hid_t
    private let native: hid_t

    /// Opens `url` and the numeric dataset at `path`. Throws what `HDF5Reader` throws for a missing file, object or an
    /// unsupported (string, compound, ...) type.
    public init(url: URL, path: String) throws {
        let parts = try HDF5Ops.components(path)
        let opened: (SharedHDF5, hid_t, hid_t, hid_t, hid_t, [Int], FormatoDataType) = try HDF5RootAttributes.withLibrary { h5 in
            let file = try HDF5RootAttributes.openForReading(url, h5)
            var dataset: hid_t = -1, space: hid_t = -1
            do {
                guard HDF5Ops.linkExists(h5, file, parts) else { throw HDF5FileError.notFound(path) }
                dataset = HDF5Ops.absolute(parts).withCString { h5.h5oopen(file, $0, 0) }
                guard dataset >= 0 else { throw HDF5FileError.notFound(path) }
                guard HDF5Ops.kindOf(h5, dataset) == .dataset else { throw HDF5FileError.wrongKind(path: path, expected: "dataset") }
                var found = try HDF5Ops.info(h5, dataset, path)
                if found.type == .unsupported("float16") { found = HDF5DatasetInfo(shape: found.shape, type: .numeric(.float32)) }
                guard case .numeric(let type) = found.type, let nativeType = HDF5Ops.native(h5, type) else {
                    throw HDF5FileError.unsupportedType(path: path, type: "\(found.type)")
                }
                space = h5.h5dgetSpace(dataset)
                guard space >= 0 else { throw HDF5RootAttributes.hdf5Failure("opening the space of \(path)", h5) }
                return (h5, file, dataset, space, nativeType, found.shape, type)
            } catch {
                if space >= 0 { _ = h5.h5sclose(space) }
                if dataset >= 0 { _ = h5.h5oclose(dataset) }
                _ = h5.h5fclose(file)
                throw error
            }
        }
        (h5, file, dataset, space, native, shape, dataType) = opened
        self.url = url
        self.path = path
    }

    deinit { close() }

    /// Closes the dataset and the file. Idempotent; a read after it throws `invalidArgument`.
    public func close() {
        HDF5Serial.run {
            guard file >= 0 else { return }
            _ = h5.h5sclose(space); _ = h5.h5oclose(dataset); _ = h5.h5fclose(file)
            file = -1; dataset = -1; space = -1
        }
    }

    /// The slab `start`/`count` (both of the dataset's rank) as a `FormatoArray` of the stored type, as little-endian bytes.
    public func read(start: [Int], count: [Int]) throws -> FormatoArray {
        let elements = try FormatoArray.elementCount(count)
        var data = Data(count: elements * dataType.byteSize)
        try data.withUnsafeMutableBytes { try read(start: start, count: count, into: $0) }
        return try FormatoArray(dataType: dataType, shape: count, bytes: data)
    }

    /// The same slab written into `buffer`, which must hold at least `count`'s elements times the element size. No allocation
    /// beyond HDF5's own: the loop entry for one pattern per call.
    public func read(start: [Int], count: [Int], into buffer: UnsafeMutableRawBufferPointer) throws {
        do { try FormatoArray.validateSlab(start: start, count: count, shape: shape) } catch {
            throw HDF5FileError.invalidArgument("slab \(start) of \(count) is outside \(path) of shape \(shape)")
        }
        let elements = try FormatoArray.elementCount(count)
        guard buffer.count >= elements * dataType.byteSize else {
            throw HDF5FileError.invalidArgument("the buffer holds \(buffer.count) bytes, the slab needs \(elements * dataType.byteSize)")
        }
        guard elements > 0 else { return }
        try HDF5Serial.run {
            guard file >= 0 else { throw HDF5FileError.invalidArgument("the reader is closed") }
            if shape.isEmpty {
                guard h5.h5dread(dataset, native, 0, 0, 0, buffer.baseAddress) >= 0 else {
                    throw HDF5RootAttributes.hdf5Failure("reading \(path)", h5)
                }
                return
            }
            let c = count.map(UInt64.init), s = start.map(UInt64.init)
            guard h5.h5sselectHyperslab(space, 0, s, nil, c, nil) >= 0 else {
                throw HDF5RootAttributes.hdf5Failure("selecting the slab of \(path)", h5)
            }
            let memory = h5.h5screateSimple(Int32(c.count), c, nil)
            guard memory >= 0 else { throw HDF5RootAttributes.hdf5Failure("making the memory space for \(path)", h5) }
            defer { _ = h5.h5sclose(memory) }
            guard h5.h5dread(dataset, native, memory, space, 0, buffer.baseAddress) >= 0 else {
                throw HDF5RootAttributes.hdf5Failure("reading \(path)", h5)
            }
        }
    }
}
