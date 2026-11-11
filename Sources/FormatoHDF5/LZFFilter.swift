//
//  LZFFilter.swift
//  Role: reads HDF5 datasets compressed with h5py's LZF filter (HDF5 filter 32000): AZtec stores an .h5oina's EBSD patterns
//        with it (H5OINA formats 5.0 to 7.0), and h5py users choose it with `compression="lzf"`. The shipped libhdf5 has no LZF
//        filter, so `SharedHDF5.load` registers this decoder with `H5Zregister` right after `H5open` (FormatoKit#86). Decode
//        only: FormatoKit never writes LZF, so the class says it has no encoder.
//        `LZF.decompress` ports liblzf 3.6's `lzf_decompress` (lzf_d.c, Marc Alexander Lehmann, BSD 2-Clause, as h5py 3.16.0
//        vendors it) with every input check on (CHECK_INPUT). The filter callback follows h5py 3.16.0's lzf_filter.c (Andrew
//        Collette, BSD 3-Clause): the output buffer is `cd_values[2]` bytes (the chunk's size, which h5py's set_local stores),
//        else the input buffer's size, and the input buffer is freed and replaced when the decode succeeds. Where h5py grows the
//        buffer step by step until the output fits, this one measures the output once and allocates that. NOTICE carries both
//        licences.
//        Tests: LZFTests.
//

import Foundation
import Darwin

/// liblzf's decoder on raw bytes.
package nonisolated enum LZF {
    package enum Outcome: Sendable, Equatable {
        /// The input decoded to this many bytes at the start of the output.
        case decoded(Int)
        /// The output does not fit (liblzf's E2BIG).
        case outputTooSmall
        /// Not an LZF stream: empty, a run or a reference past the input's end, or a reference before the output's start
        /// (liblzf's EINVAL).
        case invalid
    }

    /// Decodes `input` into `output` as liblzf's `lzf_decompress` does with its input checks on. Literal runs copy, back
    /// references repeat earlier output byte by byte, so a reference that overlaps its own output repeats a pattern.
    package static func decompress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Outcome {
        guard let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count > 0 else { return .invalid }
        let target = output.baseAddress?.assumingMemoryBound(to: UInt8.self)
        let inEnd = input.count, outEnd = output.count
        var i = 0, o = 0
        repeat {
            let control = Int(source[i]); i += 1
            if control < 32 {                                  // a literal run of control + 1 bytes
                let run = control + 1
                guard o + run <= outEnd, let target else { return .outputTooSmall }
                guard i + run <= inEnd else { return .invalid }
                UnsafeMutableRawPointer(target + o).copyMemory(from: source + i, byteCount: run)
                o += run; i += run
            } else {                                           // a back reference of length + 2 bytes, distance + 1 back
                var length = control >> 5
                var distance = ((control & 0x1f) << 8) + 1
                guard i < inEnd else { return .invalid }
                if length == 7 {
                    length += Int(source[i]); i += 1
                    guard i < inEnd else { return .invalid }
                }
                distance += Int(source[i]); i += 1
                let count = length + 2
                guard o + count <= outEnd, let target else { return .outputTooSmall }
                guard distance <= o else { return .invalid }
                if distance >= count {
                    UnsafeMutableRawPointer(target + o).copyMemory(from: target + (o - distance), byteCount: count)
                    o += count
                } else {
                    for _ in 0 ..< count { target[o] = target[o - distance]; o += 1 }
                }
            }
        } while i < inEnd
        return .decoded(o)
    }

    /// The size `input` decodes to, or nil when it is not an LZF stream: the same walk as `decompress`, without writing.
    package static func decodedSize(_ input: UnsafeRawBufferPointer) -> Int? {
        guard let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self), input.count > 0 else { return nil }
        let inEnd = input.count
        var i = 0, o = 0
        repeat {
            let control = Int(source[i]); i += 1
            if control < 32 {
                let run = control + 1
                guard i + run <= inEnd else { return nil }
                o += run; i += run
            } else {
                var length = control >> 5
                var distance = ((control & 0x1f) << 8) + 1
                guard i < inEnd else { return nil }
                if length == 7 {
                    length += Int(source[i]); i += 1
                    guard i < inEnd else { return nil }
                }
                distance += Int(source[i]); i += 1
                guard distance <= o else { return nil }
                o += length + 2
            }
        } while i < inEnd
        return o
    }
}

/// h5py's LZF filter as an HDF5 filter class, decode only.
package nonisolated enum LZFFilter {
    /// h5py's registered id (H5PY_FILTER_LZF), the one AZtec's files carry.
    package static let id: Int32 = 32000
    /// `H5Z_FLAG_REVERSE`: the call decodes.
    package static let reverse: UInt32 = 0x0100

    /// `H5Z_func_t`: flags, cd_nelmts, cd_values, nbytes, *buf_size, **buf; returns the valid bytes in the new buffer, 0 on failure.
    package typealias Function = @convention(c) (UInt32, Int, UnsafePointer<UInt32>?, Int, UnsafeMutablePointer<Int>?,
                                                 UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int
    /// `H5Zregister(const void *cls)`.
    package typealias Register = @convention(c) (UnsafeRawPointer?) -> herr_t

    /// The filter HDF5 calls for each chunk. On success the input buffer is freed and replaced by a `malloc`ed one that HDF5
    /// frees, as h5py's filter does; on failure nothing changes and HDF5 reports the read as failed.
    package static let function: Function = { flags, valueCount, values, inputCount, bufferSize, buffer in
        LZFFilter.decode(flags: flags, values: valueCount >= 3 ? values.map { Int($0[2]) } : nil,
                         inputCount: inputCount, bufferSize: bufferSize, buffer: buffer)
    }

    /// The callback's work. `values` is `cd_values[2]` when the filter carries it (the chunk's size in bytes).
    package static func decode(flags: UInt32, values chunkBytes: Int?, inputCount: Int, bufferSize: UnsafeMutablePointer<Int>?,
                               buffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int {
        // Encoding is never asked for: the class has no encoder, so HDF5 refuses to write with it before calling here.
        guard flags & reverse != 0, let buffer, let bufferSize, let input = buffer.pointee, inputCount > 0 else { return 0 }
        let source = UnsafeRawBufferPointer(start: input, count: inputCount)
        var size = chunkBytes.flatMap { $0 > 0 ? $0 : nil } ?? bufferSize.pointee
        for attempt in 0 ..< 2 {
            guard size > 0, let output = malloc(size) else { return 0 }
            switch LZF.decompress(source, into: UnsafeMutableRawBufferPointer(start: output, count: size)) {
            case .decoded(let count):
                free(input)
                buffer.pointee = output
                bufferSize.pointee = size
                return count
            case .outputTooSmall where attempt == 0:
                free(output)
                guard let needed = LZF.decodedSize(source), needed > size else { return 0 }
                size = needed
            case .outputTooSmall, .invalid:
                free(output)
                return 0
            }
        }
        return 0
    }

    /// The filter's name, a static C string: HDF5 keeps the pointer for the life of the process.
    private static let name: StaticString = "lzf"

    /// Registers the decoder with the library `register` came from: HDF5 copies the class into its filter table (H5Z.c,
    /// `H5Z_register`), and a second registration replaces the first. Call under `HDF5Serial`, after `H5open`. Returns whether
    /// HDF5 took it; when it did not, an LZF dataset fails to read as before.
    @discardableResult
    package static func register(with register: Register) -> Bool {
        // H5Z_class2_t (H5Zdevelop.h, HDF5 2.1.1) on a 64-bit Mac: int version, int id, unsigned encoder_present,
        // unsigned decoder_present, then four pointers: name, can_apply, set_local, filter.
        let size = 48
        precondition(MemoryLayout<Function>.size == 8 && MemoryLayout<UnsafeRawPointer>.size == 8, "a 64-bit C function pointer")
        let cls = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { cls.deallocate() }
        cls.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        cls.storeBytes(of: 1, toByteOffset: 0, as: Int32.self)                      // H5Z_CLASS_T_VERS
        cls.storeBytes(of: id, toByteOffset: 4, as: Int32.self)
        cls.storeBytes(of: 0, toByteOffset: 8, as: UInt32.self)                     // no encoder
        cls.storeBytes(of: 1, toByteOffset: 12, as: UInt32.self)                    // a decoder
        cls.storeBytes(of: UnsafeRawPointer(name.utf8Start), toByteOffset: 16, as: UnsafeRawPointer.self)
        // can_apply (24) and set_local (32) stay NULL: nothing is written with this filter.
        withUnsafeBytes(of: function) { cls.advanced(by: 40).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return register(UnsafeRawPointer(cls)) >= 0
    }
}
