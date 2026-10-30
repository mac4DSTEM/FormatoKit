//
//  DM4ScanShapedTests.swift
//  Planted DM3/DM4 files written here byte by byte (the layout tools/dm4-gather/generate.py writes, plus DM3 and real tag
//  sizes): a rank-3 object (N, Qy, Qx) with "Scan shape X/Y" tags reads through `DM4Datacube` as the 4D cube
//  [scanY, scanX, Qy, Qx] (py4DSTEM's `_process_NCEM_TitanX_Tags` reshape: R_Nx = Scan shape Y, R_Ny = Scan shape X), the
//  bytes as stored; more than four dimensions and a DM3 data array declaring length 0 are refused with a sentence; a DM4
//  data array declaring length 0 is skipped by its tag size.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM

/// A DM tag tree, written as GMS writes it (big-endian structure, little-endian values).
indirect enum PlantedDMNode {
    case group(String, [PlantedDMNode])
    case int32(String, Int32)
    case float64(String, Double)
    case text(String, String)
    /// A `[20, encType, count]` array; `declaredCount` overrides the count written in the info array.
    case array(String, encType: UInt64, count: Int, bytes: Data, declaredCount: Int? = nil)
}

struct PlantedDMFile {
    let version: Int
    let root: [PlantedDMNode]

    private func special(_ v: Int) -> Data {
        version == 4 ? withUnsafeBytes(of: UInt64(v).bigEndian) { Data($0) } : withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) }
    }
    private func label(_ id: UInt8, _ name: String) -> Data {
        var d = Data([id]); let b = Data(name.utf8)
        d.append(contentsOf: withUnsafeBytes(of: UInt16(b.count).bigEndian) { Array($0) }); d.append(b); return d
    }
    private func tag(_ name: String, info: [Int], payload: Data) -> Data {
        var body = Data("%%%%".utf8); body.append(special(info.count))
        for i in info { body.append(special(i)) }
        body.append(payload)
        var d = label(21, name)
        if version == 4 { d.append(special(body.count)) }
        d.append(body); return d
    }
    private func groupBody(_ children: [PlantedDMNode]) -> Data {
        var body = Data([1, 0]); body.append(special(children.count))
        for c in children { body.append(encode(c)) }
        return body
    }
    private func encode(_ node: PlantedDMNode) -> Data {
        switch node {
        case .group(let name, let children):
            let body = groupBody(children)
            var d = label(20, name)
            if version == 4 { d.append(special(body.count)) }
            d.append(body); return d
        case .int32(let name, let v):
            return tag(name, info: [3], payload: withUnsafeBytes(of: v.littleEndian) { Data($0) })
        case .float64(let name, let v):
            return tag(name, info: [7], payload: withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) })
        case .text(let name, let s):
            let units = Array(s.utf16)
            var payload = Data(); for u in units { payload.append(contentsOf: withUnsafeBytes(of: u.littleEndian) { Array($0) }) }
            return tag(name, info: [20, 4, units.count], payload: payload)
        case .array(let name, let enc, let count, let bytes, let declared):
            return tag(name, info: [20, Int(enc), declared ?? count], payload: bytes)
        }
    }
    var bytes: Data {
        let rootBody = groupBody(root)
        var d = withUnsafeBytes(of: UInt32(version).bigEndian) { Data($0) }
        d.append(special(rootBody.count))
        d.append(withUnsafeBytes(of: UInt32(1).bigEndian) { Data($0) })
        d.append(rootBody); return d
    }
}

@Suite struct DM4ScanShapedTests {
    /// uint16 pixels 0, 3, 6, ... (+ 7): every element distinct, so a wrong reshape or transpose moves a value.
    static func pixels(_ n: Int) -> Data {
        var d = Data(); for i in 0..<n { d.append(contentsOf: withUnsafeBytes(of: UInt16(i * 3 + 7).littleEndian) { Array($0) }) }
        return d
    }
    /// One image object. `dims` fastest first (DM order). `dataFirst` writes Data before DataType and Dimensions, as GMS sorts them.
    static func object(dims: [Int], scanShape: (x: Double, y: Double)?, declaredCount: Int? = nil, dataFirst: Bool = false,
                       units: [String]? = nil) -> PlantedDMNode {
        let n = dims.reduce(1, *)
        let data = PlantedDMNode.array("Data", encType: 4, count: n, bytes: pixels(n), declaredCount: declaredCount)
        let calibrations = PlantedDMNode.group("Calibrations", [.group("Dimension", dims.indices.map { i in
            .group(String(i), [.float64("Origin", Double(i) + 0.5), .float64("Scale", 0.25 * Double(i + 1)),
                               .text("Units", units?[i] ?? ["1/nm", "1/nm", "nm", "nm", "nm"][i])])
        })])
        let shape: [PlantedDMNode] = [.int32("DataType", 10), .group("Dimensions", dims.enumerated().map { .int32(String($0.offset), Int32($0.element)) })]
        var tags: [PlantedDMNode] = [.group("Microscope Info", [.float64("Voltage", 300_000)])]
        if let s = scanShape { tags.append(.group("4D STEM Tags", [.float64("Scan shape X", s.x), .float64("Scan shape Y", s.y)])) }
        let imageData: [PlantedDMNode] = dataFirst ? [calibrations, data] + shape : [calibrations] + shape + [data]
        return .group("", [.group("ImageData", imageData), .group("ImageTags", tags), .text("Name", "planted")])
    }
    static func write(_ file: PlantedDMFile, _ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try file.bytes.write(to: url)
        return url.path
    }

    /// dims [Qx=5, Qy=3, N=12], scan shape X = 4, Y = 3: the cube is [3, 4, 3, 5], the bytes as stored, in both conventions.
    @Test(arguments: [3, 4])
    func rank3WithScanShapeTagsReadsAs4D(version: Int) throws {
        let path = try Self.write(PlantedDMFile(version: version, root: [.group("ImageList", [Self.object(dims: [5, 3, 12], scanShape: (4, 3))])]),
                                  "rank3.dm\(version)")
        let stored = try DM4Datacube(path: path)
        let s = try stored.signal.load()
        #expect(s.data.shape == [3, 4, 3, 5])
        #expect(s.data.dataType == .uint16)
        #expect(s.data.bytes == Self.pixels(180))
        #expect(stored.layout.storedShape == [3, 4, 3, 5] && stored.layout.permutation == [0, 1, 2, 3])
        #expect(stored.layout.storedType == .uint16 && stored.layout.outputType == .uint16)
        // The scan axes carry the stack axis's calibration (DM dimension 2: origin 2.5, scale 0.75, "nm").
        #expect(s.axes.map(\.size) == [3, 4, 3, 5])
        #expect(s.axes.map(\.scale) == [0.75, 0.75, 0.5, 0.25])
        #expect(s.axes.map(\.offset) == [-1.875, -1.875, -0.75, -0.125])
        #expect(s.axes.map(\.units) == ["nm", "nm", "1/nm", "1/nm"])
        #expect(s.axes.map(\.navigate) == [true, true, false, false])
        #expect(s.axes.map(\.name) == [nil, "z", "y", "x"])
        // One frame: scan (2, 1) is stack frame 2 * 4 + 1 = 9.
        let frame = try stored.frame(scanY: 2, scanX: 1)
        #expect(frame.bytes == Self.pixels(180).subdata(in: (9 * 15 * 2)..<(10 * 15 * 2)))

        let app = try DM4Datacube(path: path, convention: .appCalibratedAxes)
        let a = try app.signal.load()
        #expect(a.data.shape == [3, 4, 3, 5])
        #expect(a.data.dataType == .float32)
        #expect(a.data.doubles() == (0..<180).map { Double($0 * 3 + 7) })
        #expect(a.axes.map(\.name) == ["Ry", "Rx", "Qy", "Qx"])
        #expect(a.axes.map(\.scale) == [0.75, 0.75, 0.5, 0.25])
        #expect(app.calibrationNote == nil)
        #expect(app.layout.permutation == [0, 1, 2, 3] && !app.layout.scanFastest)
        for start in [[0, 0, 0, 0], [1, 2, 1, 3], [2, 3, 2, 4]] {
            let count = zip(start, a.data.shape).map { $1 - $0 }
            #expect(try app.signal.array.read(start: start, count: count) == a.data.slab(start: start, count: count))
        }
    }

    /// Without scan-shape tags, or with tags whose product is not the stack length, a rank-3 object is no datacube.
    @Test func rank3WithoutMatchingTagsIsRefused() throws {
        for scan in [nil, (x: 5.0, y: 3.0)] as [(x: Double, y: Double)?] {
            let path = try Self.write(PlantedDMFile(version: 4, root: [.group("ImageList", [Self.object(dims: [5, 3, 12], scanShape: scan)])]), "r.dm4")
            #expect(throws: DM4Error.self) { try DM4Datacube(path: path) }
            #expect(throws: DM4Error.self) { try DM4Datacube(path: path, objectIndex: 1) }
        }
    }

    /// A rank-4 object still wins over nothing; a rank-3 scan-shaped object listed first is the first datacube.
    @Test func firstDatacubeInListOrder() throws {
        let path = try Self.write(PlantedDMFile(version: 4, root: [.group("ImageList", [
            Self.object(dims: [5, 3, 12], scanShape: (4, 3)), Self.object(dims: [2, 3, 4, 5], scanShape: nil)])]), "two.dm4")
        #expect(try DM4Datacube(path: path).signal.array.shape == [3, 4, 3, 5])
        #expect(try DM4Datacube(path: path, objectIndex: 2).signal.array.shape == [5, 4, 3, 2])
    }

    /// Five dimensions: refused with a sentence that names the count, by index and when it is the only object.
    @Test func fiveDimensionsRefusedWithASentence() throws {
        let path = try Self.write(PlantedDMFile(version: 4, root: [.group("ImageList", [Self.object(dims: [2, 3, 2, 2, 2], scanShape: nil)])]), "five.dm4")
        for index in [nil, 1] as [Int?] {
            let error = #expect(throws: DM4Error.self) { try DM4Datacube(path: path, objectIndex: index) }
            #expect(error?.localizedDescription.contains("5 dimensions") == true, "\(String(describing: error?.localizedDescription))")
        }
    }

    /// DM3 records no length but the array's own: a declared length of 0 cannot be skipped, and is refused with a sentence.
    @Test func dm3DeclaredLengthZeroRefusedWithASentence() throws {
        let path = try Self.write(PlantedDMFile(version: 3, root: [.group("ImageList", [
            Self.object(dims: [5, 3, 2, 2], scanShape: nil, declaredCount: 0, dataFirst: true)])]), "zero.dm3")
        let error = #expect(throws: DM4Error.self) { try DM4Datacube(path: path) }
        #expect(error?.localizedDescription.contains("length 0") == true, "\(String(describing: error?.localizedDescription))")
        #expect(throws: DM4Error.self) { try DMFile(path: path) }
    }

    /// DM4 gives every tag its size: a data array declaring length 0 is skipped by it, so the tags after it (here DataType and
    /// Dimensions, in GMS's sorted order) are read and the cube is exact.
    @Test func dm4DeclaredLengthZeroSkippedByTagSize() throws {
        let path = try Self.write(PlantedDMFile(version: 4, root: [.group("ImageList", [
            Self.object(dims: [5, 3, 2, 2], scanShape: nil, declaredCount: 0, dataFirst: true)])]), "zero.dm4")
        let cube = try DM4Datacube(path: path)
        let s = try cube.signal.load()
        #expect(s.data.shape == [2, 2, 3, 5])
        #expect(s.data.bytes == Self.pixels(60))
        #expect(cube.object.voltage == 300_000)
        #expect(try DMFile(path: path).signal(index: 1).load().data.bytes == Self.pixels(60))
    }
}
