//
//  DM4BlockedGatherTests.swift
//  The permuted (scan-fastest) gather is tiled over two output axes. Planted DM4 files, scan-fastest and
//  detector-fastest, in float32, uint16 and int8, with sizes that do not divide by the tile: every slab must equal the
//  element-by-element gather computed here from the planted values, bit for bit.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM

@Suite struct DM4BlockedGatherTests {
    enum Stored: CaseIterable { case float32, uint16, int8 }

    /// The value planted at stored C index `i`: distinct across the tile for every type, negative and fractional for float32.
    static func value(_ type: Stored, _ i: Int) -> Float {
        switch type {
        case .float32: Float(i) * 0.5 - 1000.25
        case .uint16: Float(UInt16(truncatingIfNeeded: i * 7 + 3))
        case .int8: Float(Int8(truncatingIfNeeded: i * 5 + 1))
        }
    }
    static func bytes(_ type: Stored, count n: Int) -> Data {
        var d = Data(capacity: n * 4)
        for i in 0..<n {
            switch type {
            case .float32: withUnsafeBytes(of: value(type, i).bitPattern.littleEndian) { d.append(contentsOf: $0) }
            case .uint16: withUnsafeBytes(of: UInt16(value(type, i)).littleEndian) { d.append(contentsOf: $0) }
            case .int8: d.append(UInt8(bitPattern: Int8(value(type, i))))
            }
        }
        return d
    }
    /// DM dimensions fastest first; `scanFirst` gives the two leading dimensions real-space units (scan-fastest storage).
    static func file(_ type: Stored, dims: [Int], scanFirst: Bool) throws -> String {
        let n = dims.reduce(1, *)
        let (code, enc): (Int32, UInt64) = switch type { case .float32: (2, 6); case .uint16: (10, 4); case .int8: (9, 9) }
        let units = scanFirst ? ["nm", "nm", "1/nm", "1/nm"] : ["1/nm", "1/nm", "nm", "nm"]
        let calibrations = PlantedDMNode.group("Calibrations", [.group("Dimension", dims.indices.map { i in
            .group(String(i), [.float64("Origin", 0), .float64("Scale", 1), .text("Units", units[i])])
        })])
        let image = PlantedDMNode.group("", [
            .group("ImageData", [calibrations, .int32("DataType", code),
                                 .group("Dimensions", dims.enumerated().map { .int32(String($0.offset), Int32($0.element)) }),
                                 .array("Data", encType: enc, count: n, bytes: bytes(type, count: n))]),
            .group("ImageTags", [.group("Microscope Info", [.float64("Voltage", 200_000)])]),
            .text("Name", "planted")])
        return try DM4ScanShapedTests.write(PlantedDMFile(version: 4, root: [.group("ImageList", [image])]), "gather.dm4")
    }

    /// Output slab as Float, element by element: output axis `i` is stored axis `permutation[i]`.
    static func expected(_ type: Stored, storedShape: [Int], permutation: [Int], start: [Int], count: [Int]) -> [Float] {
        var strides = [1, 1, 1, 1]
        for i in stride(from: 2, through: 0, by: -1) { strides[i] = strides[i + 1] * storedShape[i + 1] }
        let s = (0..<4).map { strides[permutation[$0]] }
        var out: [Float] = []; out.reserveCapacity(count.reduce(1, *))
        for a in 0..<count[0] { for b in 0..<count[1] { for c in 0..<count[2] { for d in 0..<count[3] {
            let i = (start[0] + a) * s[0] + (start[1] + b) * s[1] + (start[2] + c) * s[2] + (start[3] + d) * s[3]
            out.append(value(type, i))
        } } } }
        return out
    }
    static func floats(_ a: FormatoArray, as type: FormatoDataType) -> [Float] {
        a.bytes.withUnsafeBytes { raw in
            switch type {
            case .float32: raw.bindMemory(to: UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
            case .uint16: raw.bindMemory(to: UInt16.self).map { Float(UInt16(littleEndian: $0)) }
            default: raw.bindMemory(to: Int8.self).map { Float($0) }
            }
        }
    }

    /// Slabs over the output shape: the whole cube, the tail tiles, odd starts, a single frame, a single scan position row.
    static func slabs(_ shape: [Int]) -> [(start: [Int], count: [Int])] {
        [([0, 0, 0, 0], shape),
         ([1, 3, 2, 5], [shape[0] - 2, shape[1] - 4, shape[2] - 3, shape[3] - 6]),
         ([0, 16, 0, 16], [shape[0], shape[1] - 16, shape[2], shape[3] - 16]),
         ([2, 17, 1, 0], [1, 1, shape[2] - 1, shape[3]]),
         ([shape[0] - 1, 0, 3, 4], [1, shape[1], 1, 1]),
         ([0, 0, 0, shape[3] - 1], [shape[0], shape[1], shape[2], 1])]
    }

    /// DM dims [Rx=70, Ry=5, Qy=19, Qx=21] as scan-fastest (output [5, 70, 19, 21]) and as detector-fastest: 70 and 21 do
    /// not divide by the tile (64 x 16), so there are full tiles and partial ones on both tiled axes.
    @Test(arguments: Stored.allCases, [true, false])
    func gatherEqualsTheElementwiseGather(type: Stored, scanFirst: Bool) throws {
        let path = try Self.file(type, dims: [70, 5, 19, 21], scanFirst: scanFirst)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        for convention in [DM4GatherConvention.rosettaSciIO, .appCalibratedAxes] {
            let cube = try DM4Datacube(path: path, convention: convention)
            let app = convention == .appCalibratedAxes
            #expect(cube.layout.permutation == (app && scanFirst ? [2, 3, 1, 0] : [0, 1, 2, 3]))
            let shape = cube.signal.array.shape
            for (start, count) in Self.slabs(shape) {
                let slab = try cube.signal.array.read(start: start, count: count)
                #expect(slab.shape == count)
                let want = Self.expected(type, storedShape: cube.layout.storedShape, permutation: cube.layout.permutation,
                                         start: start, count: count)
                let got = Self.floats(slab, as: slab.dataType)
                #expect(got.map(\.bitPattern) == want.map(\.bitPattern), "\(type) scanFirst \(scanFirst) \(convention) \(start) \(count)")
            }
        }
    }
}
