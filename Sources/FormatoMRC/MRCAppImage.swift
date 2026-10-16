//
//  MRCAppImage.swift
//  The first consumer's reading of one MRC2014 image (nz = 1) as a Float32 image: the named option beside `MRCReader`
//  (RosettaSciIO's reading). Pinned to the consumer's source (macTEM cb6e164 MRCImageReader.swift), compiled unchanged
//  by tools/acq-metadata/generate.py, and to mrcfile 1.5.4's `voxel_size` for the calibration.
//
//  WHAT IS READ: the 1024-byte header, then the extended header skipped by NSYMBT, then nx x ny samples in the byte
//  order the machine stamp names (44 44 or 44 41 little-endian, 11 11 big-endian). Modes 0 (int8, signed, as MRC2014
//  defines it), 1 (int16), 2 (float32), 6 (uint16), 12 (float16). Refused by name: a stack (nz > 1), any other mode, an
//  unknown machine stamp, a file without the "MAP " id, axes other than mapc/mapr/maps = 1/2/3, and data or an extended
//  header that runs past the end.
//
//  CALIBRATION: per axis cella / m in Angstrom, rounded to float32 as mrcfile's `voxel_size` stores it; the header
//  origin is not read (origin 0). A cell length that gives a non-positive or non-finite scale opens uncalibrated and
//  says so, and so does a Thermo/FEI file (an extended header of exactly 128 * 1024 bytes), whose pixel size sits in
//  that header. DIFFERENCES from `MRCReader`: signed mode 0, the stamp honoured, Angstrom not nm, stacks and
//  modes 4 / 12 refused or converted, Float32 pixels, no squeeze, no FEI pixel size, no origin.
//

import Foundation
import FormatoCore

public nonisolated enum MRCAppImage {

    /// One calibrated axis: the physical value at pixel `i` is `(i - origin) * scale`.
    public struct Axis: Sendable, Equatable {
        public let origin: Double
        public let scale: Double
        public let units: String

        public init(origin: Double, scale: Double, units: String) {
            self.origin = origin; self.scale = scale; self.units = units
        }
    }

    /// One 2D Float32 image and the calibration of each axis, nil where the file gives none.
    public struct Image: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// Row-major, `width` fastest.
        public let pixels: [Float]
        public let x: Axis?
        public let y: Axis?
        public let fileName: String
        public let source: String
        public let notes: [String]
    }

    public enum Note {
        public static let nonPositiveCell = "uncalibrated: the cell length is not positive"
        public static let feiHeader = "uncalibrated: an FEI extended header holds the pixel size, not read"
    }

    /// `acceptStacks` exists for one caller: tools/parity/mrc-reader-parity's negative control, which must show the stack
    /// refusal is live. It reads the first image instead of refusing.
    public static func read(path: String, acceptStacks: Bool = false) throws -> Image {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) } catch {
            throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), error.localizedDescription)
        }
        return try read(data: data, fileName: formatoDisplayFileName(path), acceptStacks: acceptStacks)
    }

    public static func read(data: Data, fileName: String, acceptStacks: Bool = false) throws -> Image {
        guard data.count >= 1024 else { throw MRCError.notMRC("\(data.count) bytes, shorter than an MRC header") }
        let bytes = [UInt8](data.prefix(1024))
        guard bytes[208..<212].elementsEqual(Array("MAP ".utf8)) else { throw MRCError.notMRC("no \"MAP \" id") }
        let stamp = Array(bytes[212..<216])
        let bigEndian: Bool
        switch (stamp[0], stamp[1]) {
        case (0x44, 0x44), (0x44, 0x41): bigEndian = false
        case (0x11, 0x11): bigEndian = true
        default: throw MRCError.byteOrder(stamp: stamp)
        }
        func word(_ index: Int) -> UInt32 {
            let b = bytes[(4 * index)..<(4 * index + 4)].map(UInt32.init)
            return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
        }
        func int(_ index: Int) -> Int { Int(Int32(bitPattern: word(index))) }
        func float(_ index: Int) -> Float { Float(bitPattern: word(index)) }

        let nx = int(0), ny = int(1), nz = int(2), mode = int(3)
        // When a file has several defects, the one named is the first in this order: header, size, mode, stack, axes,
        // length — the harness's reference derives its cause in the same order.
        guard nx > 0, ny > 0, nz > 0 else { throw MRCError.notMRC("\(nx) × \(ny) × \(nz)") }
        let size: Int
        switch mode {
        case 0: size = 1
        case 1, 6, 12: size = 2
        case 2: size = 4
        default: throw MRCError.mode(mode)
        }
        if nz > 1, !acceptStacks { throw MRCError.stack(frames: nz) }
        let (mapc, mapr, maps) = (int(16), int(17), int(18))
        guard (mapc, mapr, maps) == (1, 2, 3) else { throw MRCError.axisOrder(mapc: mapc, mapr: mapr, maps: maps) }

        let extended = int(23)
        guard extended >= 0 else { throw MRCError.truncated }
        let (count, overflow) = nx.multipliedReportingOverflow(by: ny)
        let (needed, overflow2) = count.multipliedReportingOverflow(by: size)
        guard !overflow, !overflow2, extended <= data.count - 1024, needed <= data.count - 1024 - extended else {
            throw MRCError.truncated
        }
        let start = data.startIndex + 1024 + extended

        var pixels = [Float](repeating: 0, count: count)
        data[start ..< start + needed].withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            func u16(_ i: Int) -> UInt16 {
                let v = buffer.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)
                return bigEndian ? UInt16(bigEndian: v) : UInt16(littleEndian: v)
            }
            for i in 0..<count {
                switch mode {
                case 0: pixels[i] = Float(Int8(bitPattern: buffer[i]))
                case 1: pixels[i] = Float(Int16(bitPattern: u16(i)))
                case 6: pixels[i] = Float(u16(i))
                case 12: pixels[i] = Float(Float16(bitPattern: u16(i)))
                default:
                    let v = buffer.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)
                    pixels[i] = Float(bitPattern: bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
                }
            }
        }

        // mrcfile's voxel_size: float32 cella over the integer sampling, computed in float64, stored as float32.
        let mx = int(7), my = int(8)
        let xScale = Double(Float(Double(float(10)) / Double(mx)))
        let yScale = Double(Float(Double(float(11)) / Double(my)))
        var x: Axis?, y: Axis?, notes: [String] = []
        if extended == 128 * 1024 {
            notes.append(Note.feiHeader)
        } else if xScale.isFinite, xScale > 0, yScale.isFinite, yScale > 0 {
            x = Axis(origin: 0, scale: xScale, units: "Å")
            y = Axis(origin: 0, scale: yScale, units: "Å")
        } else {
            notes.append(Note.nonPositiveCell)
        }
        let kind = ["int8", "int16", "float32", "", "", "", "uint16"].indices.contains(mode)
            ? ["int8", "int16", "float32", "", "", "", "uint16"][mode] : "float16"
        return Image(width: nx, height: ny, pixels: pixels, x: x, y: y, fileName: fileName,
                     source: (["MRC · mode \(mode) \(kind)"] + notes).joined(separator: " · "), notes: notes)
    }
}
