import Foundation
import Testing
import FormatoCore
import FormatoKitTestSupport
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
/// In this process, not a gzip child: a child would hold copies of other tests' HDF5 descriptors (FormatoKit#49).
private func inflate(_ name: String) throws -> Data { try Gunzip.contents(of: fixtures.appendingPathComponent(name)) }
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
            for (a, e) in zip(eager.axes, pin.axes) { #expect(a.bitwiseEquals(FormatoAxis(name: e.name, size: e.size, scale: e.scale, offset: e.offset, units: e.units, navigate: e.navigate))) }
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

/// `.appScanXY` takes a header size other than 384 / 768 (the original reader did); RosettaSciIO's convention still refuses it.
@Test func mibOtherHeaderSizeIsTheAppConventionsAndPixelCodeIsExposed() throws {
    let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: fixtures.appendingPathComponent("pins.json")))
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let pin = try #require(pins.cases.first { $0.app })
    let source = try inflate(pin.name + ".mib.gz")
    let fields = String(decoding: source.prefix(384), as: UTF8.self).components(separatedBy: ",")
    let width = try #require(Int(fields[4])), height = try #require(Int(fields[5]))
    let bytes = ["U08": 1, "U16": 2, "U32": 4][fields[6]]!
    let stride = 384 + width * height * bytes
    #expect(source.count % stride == 0)
    var wide = Data()
    for frame in 0..<(source.count / stride) {
        var header = Data(source[(frame * stride)..<(frame * stride + 384)])
        let marker = Data("00384".utf8), at = try #require(header.range(of: marker))
        header.replaceSubrange(at, with: Data("00512".utf8))
        wide += header + Data(repeating: 0x20, count: 128) + source[(frame * stride + 384)..<((frame + 1) * stride)]
    }
    let path = dir.appendingPathComponent("wide.mib"); try wide.write(to: path)
    let reference = dir.appendingPathComponent("plain.mib"); try source.write(to: reference)
    let hdr = fixtures.appendingPathComponent(pin.name + ".hdr")
    for target in [path, reference] where FileManager.default.fileExists(atPath: hdr.path) {
        try FileManager.default.copyItem(at: hdr, to: target.deletingPathExtension().appendingPathExtension("hdr"))
    }
    let app = try MIBReader(path: path.path, convention: .appScanXY)
    let plain = try MIBReader(path: reference.path, convention: .appScanXY)
    #expect(app.pixelCode == fields[6] && plain.pixelCode == fields[6])
    #expect(try app.signal.load().data == plain.signal.load().data)
    #expect(throws: MIBError.self) { try MIBReader(path: path.path) }
}

/// The direct "YYYY-MM-DDTHH:MM:SS" reading (0.9.0) agrees with `ISO8601DateFormatter` over a sweep of instants, leap days included.
@Test func mibPlainTimestampEqualsTheFormatter() throws {
    let formatter = ISO8601DateFormatter()
    var t = 951_782_400.0   // 2000-02-29
    var checked = 0
    while t < 4_102_444_800 {   // to 2100-01-01
        let stamp = formatter.string(from: Date(timeIntervalSince1970: t))
        #expect(mibPlainUTCSeconds(String(stamp.dropLast())) == t, "\(stamp)")
        #expect(formatter.date(from: stamp)?.timeIntervalSince1970 == t)
        t += 86_400 * 37 + 3_671
        checked += 1
    }
    #expect(checked > 600)
}

/// 0.9.1: the 0.9.0 reader copies whole runs (8-bit copy, 16- and 32-bit byte swap in lanes, an unaligned path). Every fixture is the
/// RosettaSciIO bytes (`pins.json`, `*.data.gz`); here every one-index slice along every axis, each of which crosses frame, row and
/// flip boundaries differently, equals the matching slab of those bytes. The 0.8.x element-by-element reader gave the same bytes
/// (the rewrite changed speed only), so no assertion here can fail against it; they pin the new copy paths.
@Test func mibEveryAxisSliceEqualsTheRosettaSciIOBytes() throws {
    let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: fixtures.appendingPathComponent("pins.json")))
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var slices = 0
    for pin in pins.cases {
        let path = dir.appendingPathComponent(pin.name + ".mib")
        try inflate(pin.name + ".mib.gz").write(to: path)
        let hdr = fixtures.appendingPathComponent(pin.name + ".hdr")
        if FileManager.default.fileExists(atPath: hdr.path) { try FileManager.default.copyItem(at: hdr, to: path.deletingPathExtension().appendingPathExtension("hdr")) }
        let lazy = try MIBReader(path: path.path, navigationShape: pin.navigation, firstFrame: pin.first, lastFrame: pin.last,
                                 convention: pin.app ? .appScanXY : .rosettaSciIO).signal
        let expected = try FormatoArray(dataType: lazy.array.dataType, shape: pin.shape, bytes: inflate(pin.name + ".data.gz"))
        for axis in 0..<pin.shape.count {
            for k in 0..<pin.shape[axis] {
                var start = pin.shape.map { _ in 0 }, count = pin.shape
                start[axis] = k; count[axis] = 1
                #expect(try lazy.array.read(start: start, count: count).bytes == expected.slab(start: start, count: count).bytes, "\(pin.name) axis \(axis) index \(k)")
                slices += 1
            }
        }
    }
    #expect(slices > 100)
}

/// An odd header size (the app convention allows 384...65536) puts 16- and 32-bit pixels at odd addresses: the unaligned path of the
/// byte swap must give the bytes of the same file with the 384-byte header, for every stored pixel width.
@Test func mibOddHeaderSizeGivesTheSameBytesForEveryPixelWidth() throws {
    let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: fixtures.appendingPathComponent("pins.json")))
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var widths = Set<String>()
    for pin in pins.cases where pin.app {
        let source = try inflate(pin.name + ".mib.gz")
        let fields = String(decoding: source.prefix(384), as: UTF8.self).components(separatedBy: ",")
        let width = try #require(Int(fields[4])), height = try #require(Int(fields[5]))
        let bytes = try #require(["U08": 1, "U16": 2, "U32": 4][fields[6]])
        let stride = 384 + width * height * bytes
        guard source.count % stride == 0 else { continue }
        var odd = Data()
        for frame in 0..<(source.count / stride) {
            var header = Data(source[(frame * stride)..<(frame * stride + 384)])
            let marker = Data("00384".utf8), at = try #require(header.range(of: marker))
            header.replaceSubrange(at, with: Data("00513".utf8))
            odd += header + Data(repeating: 0x20, count: 129) + source[(frame * stride + 384)..<((frame + 1) * stride)]
        }
        let oddPath = dir.appendingPathComponent(pin.name + "-odd.mib"), plainPath = dir.appendingPathComponent(pin.name + ".mib")
        try odd.write(to: oddPath); try source.write(to: plainPath)
        let hdr = fixtures.appendingPathComponent(pin.name + ".hdr")
        if FileManager.default.fileExists(atPath: hdr.path) {
            for target in [oddPath, plainPath] { try FileManager.default.copyItem(at: hdr, to: target.deletingPathExtension().appendingPathExtension("hdr")) }
        }
        let a = try MIBReader(path: oddPath.path, convention: .appScanXY).signal.load()
        let b = try MIBReader(path: plainPath.path, convention: .appScanXY).signal.load()
        #expect(a.data == b.data, "\(pin.name)")
        #expect(a.data.bytes == (try inflate(pin.name + ".data.gz")), "\(pin.name) against the pinned bytes")
        widths.insert(fields[6])
    }
    #expect(widths == ["U08", "U16", "U32"])
}

/// A header with no detector width and height, or one whose width and height disagree with its assembly: the app read the frames by the
/// assembly (1x1 = 256, 2x2 = 512, 2x2G = 514) and the header size, so `.appScanXY` does too, giving the bytes of the same file with a
/// regular header. RosettaSciIO refuses both (it needs the width and height; a disagreeing pair is read by the header, a different shape).
@Test func mibHeaderWithoutOrAgainstItsShapeIsReadByTheAssemblyInTheAppConvention() throws {
    let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: fixtures.appendingPathComponent("pins.json")))
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var checked = 0
    for pin in pins.cases where pin.app {
        let source = try inflate(pin.name + ".mib.gz")
        let fields = String(decoding: source.prefix(384), as: UTF8.self).components(separatedBy: ",")
        let width = try #require(Int(fields[4])), height = try #require(Int(fields[5]))
        let bytes = try #require(["U08": 1, "U16": 2, "U32": 4][fields[6]])
        let headerSize = try #require(Int(fields[2]))
        let stride = headerSize + width * height * bytes
        try #require(source.count % stride == 0)
        let plainPath = dir.appendingPathComponent(pin.name + ".mib")
        try source.write(to: plainPath)
        let hdr = fixtures.appendingPathComponent(pin.name + ".hdr")
        try FileManager.default.copyItem(at: hdr, to: plainPath.deletingPathExtension().appendingPathExtension("hdr"))
        let expected = try MIBReader(path: plainPath.path, convention: .appScanXY).signal.load()
        // Each variant rewrites fields 4 and 5 of every frame header with text of the same length.
        let blank = String(repeating: " ", count: fields[4].count), blankHeight = String(repeating: " ", count: fields[5].count)
        let other = String(format: "%0\(fields[4].count)d", 17), otherHeight = String(format: "%0\(fields[5].count)d", 9)
        for (label, w, h) in [("headerless", blank, blankHeight), ("disagree", other, otherHeight)] {
            var data = Data()
            for frame in 0..<(source.count / stride) {
                var parts = String(decoding: source[(frame * stride)..<(frame * stride + headerSize)], as: UTF8.self).components(separatedBy: ",")
                parts[4] = w; parts[5] = h
                let header = Data(parts.joined(separator: ",").utf8)
                try #require(header.count == headerSize)
                data += header + source[(frame * stride + headerSize)..<((frame + 1) * stride)]
            }
            let path = dir.appendingPathComponent(pin.name + "-" + label + ".mib")
            try data.write(to: path)
            try FileManager.default.copyItem(at: hdr, to: path.deletingPathExtension().appendingPathExtension("hdr"))
            let reader = try MIBReader(path: path.path, convention: .appScanXY)
            #expect(reader.pixelCode == fields[6])
            let read = try reader.signal.load()
            #expect(read.data == expected.data, "\(pin.name) \(label)")
            #expect(read.data.bytes == (try inflate(pin.name + ".data.gz")), "\(pin.name) \(label) against the pinned bytes")
            if label == "headerless" { #expect(throws: MIBError.self) { try MIBReader(path: path.path) } }
            checked += 1
        }
    }
    #expect(checked == 10)
}
