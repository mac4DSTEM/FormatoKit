import Foundation
import Testing
import FormatoCore
import FormatoMIB
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
private struct Pins: Decodable { let cases: [Pin]; let raw: [Raw] }
private struct Raw: Decodable { let name: String; let error: String }
private struct Pin: Decodable {
    let name: String; let shape: [Int]; let dtype: String; let axes: [Axis]
    let metadata: [String: [String: Value]]; let navigation: [Int]?; let first: Int?; let last: Int?; let app: Bool
}
private enum Value: Decodable { case text(String), number(Double)
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let s = try? c.decode(String.self) { self = .text(s) } else { self = .number(try c.decode(Double.self)) } }
}
private struct Axis: Decodable { let name: String; let size: Int; let scale: Double; let offset: Double; let units: String; let navigate: Bool }
private func inflate(_ name: String) throws -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-dc", fixtures.appendingPathComponent(name).path]
    let pipe = Pipe(); p.standardOutput = pipe; try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    #expect(p.terminationStatus == 0); return data
}
private func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
}
@Test func mibOracleBytesShapeAxesMetadataAndAppOption() throws {
    let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: fixtures.appendingPathComponent("pins.json")))
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    for pin in pins.cases {
        let path = dir.appendingPathComponent(pin.name + ".mib")
        try inflate(pin.name + ".mib.gz").write(to: path)
        let hdr = fixtures.appendingPathComponent(pin.name + ".hdr")
        if FileManager.default.fileExists(atPath: hdr.path) { try FileManager.default.copyItem(at: hdr, to: path.deletingPathExtension().appendingPathExtension("hdr")) }
        let lazy = try MIBReader(path: path.path, navigationShape: pin.navigation, firstFrame: pin.first, lastFrame: pin.last,
                                 convention: pin.app ? .appScanXY : .rosettaSciIO).signal
        let eager = try lazy.load()
        #expect(eager.data.shape == pin.shape); #expect(eager.data.dataType.rawValue == pin.dtype)
        #expect(eager.data.bytes == (try inflate(pin.name + ".data.gz")))
        if !pin.app {
            #expect(eager.axes.count == pin.axes.count)
            for (a, e) in zip(eager.axes, pin.axes) { #expect(a.isBitwiseEqual(to: FormatoAxis(name: e.name, size: e.size, scale: e.scale, offset: e.offset, units: e.units, navigate: e.navigate))) }
            let entries = pin.metadata.flatMap { g,v in v.map { (g + "." + $0.key, $0.value) } }
            #expect(eager.metadata.keys.sorted() == entries.map(\.0).sorted())
            for (key, value) in entries {
                switch value {
                case .text(let s): #expect(eager.metadata[key]?.value.text == s)
                case .number(let n): #expect(eager.metadata[key]?.value.number?.bitPattern == n.bitPattern)
                }
                #expect(eager.metadata[key]?.provenance.file == path.lastPathComponent)
            }
        }
        for n in 0..<8 {
            let start = pin.shape.enumerated().map { ($0.offset * 11 + n * 7) % $0.element }
            let count = zip(start, pin.shape).map { min(3, $1 - $0) }
            #expect(try lazy.array.read(start: start, count: count) == eager.data.slab(start: start, count: count))
        }
        #expect(try lazy.array.read(start: pin.shape, count: pin.shape.map { _ in 0 }).bytes.isEmpty)
        #expect(throws: FormatoArrayError.self) { try lazy.array.read(start: [-1], count: [1]) }
    }
    for pin in pins.raw {
        let path = dir.appendingPathComponent(pin.name + ".mib"); try inflate(pin.name + ".mib.gz").write(to: path)
        for convention in [MIBConvention.rosettaSciIO, .appScanXY] {
            #expect(throws: MIBError.unsupported("RAW MIB data not supported.")) { try MIBReader(path: path.path, convention: convention) }
        }
    }
}
@Test func mibMalformedAndLifetime() throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("input.mib")
    #expect(throws: MIBError.self) { try MIBReader(path: path.path) }
    let original = try inflate("processed12-explicit.mib.gz")
    for data in [Data(), Data("MQ1,0,00384".utf8), original.prefix(383), original.dropLast()] {
        try data.write(to: path); #expect(throws: MIBError.self) { try MIBReader(path: path.path) }
    }
    try original.write(to: path)
    #expect(throws: MIBError.self) { try MIBReader(path: path.path, navigationShape: [Int.max, 2]) }
    #expect(throws: MIBError.self) { try MIBReader(path: path.path, navigationShape: [0, 2]) }
    #expect(throws: MIBError.self) { try MIBReader(path: path.path, convention: .appScanXY) }
    let lazy = try MIBReader(path: path.path, navigationShape: [3,2]).signal
    #expect(try lazy.array.read(start: [1,2,2,3], count: [1,1,1,1]).bytes.count == 2)
    let file = try FileHandle(forWritingTo: path); try file.truncate(atOffset: 1); try file.close()
    #expect(throws: MIBError.self) { try lazy.load() }
}
@Test func mibTimestampOverflowIsTyped() throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("extreme.mib")
    var data = try inflate("processed12-timestamps.mib.gz")
    let stride = 384 + 3 * 4 * 2
    for frame in 0..<6 {
        let range = (frame * stride)..<(frame * stride + 384)
        let text = String(decoding: data[range], as: UTF8.self)
        let changed = text.replacingOccurrences(of: "2026-", with: frame % 2 == 0 ? "1700-" : "2240-")
        data.replaceSubrange(range, with: changed.utf8)
    }
    try data.write(to: path)
    #expect(throws: MIBError.self) { try MIBReader(path: path.path) }
}
