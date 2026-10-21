//
//  HDF5ReaderTests.swift
//  The low-level reader (HDF5Reader) against h5py: every object of two h5py-written files (tools/hdf5-append/generate.py,
//  Fixtures/low-level/pins.json) read back exactly as h5py reads it (kinds, children, attributes bit for bit, shapes, types,
//  SHA-256 of the little-endian bytes, a slab, strings), the refusals by typed error, the bounds, and concurrent use.
//

import CryptoKit
import Foundation
import Testing
import FormatoCore
import FormatoHDF5

struct PinValue: Decodable {
    var int: Int64?, string: String?, ints: [Int64]?, strings: [String]?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int64.self) { int = v }
        else if let v = try? c.decode(String.self) { string = v }
        else if let v = try? c.decode([Int64].self) { ints = v }
        else { strings = try c.decode([String].self) }
    }
}
struct AttrPin: Decodable { var type: String; var value: PinValue?; var name: String? }
struct SlabPin: Decodable { var start: [Int]; var count: [Int]; var sha256: String }
struct ObjectPin: Decodable {
    var kind: String
    var children: [String]?
    var attrs: [String: AttrPin]?
    var shape: [Int]?
    var type: String?
    var sha256: String?
    var slab: SlabPin?
    var strings: [String]?
}
struct FilePins: Decodable { var objects: [String: ObjectPin]; var absent: [String] }
struct PinFile: Decodable { var files: [String: FilePins] }

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func bytewiseSorted(_ names: [String]) -> [String] { names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }

func hexDouble(_ text: String) -> Double { Double(text)! }

func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-h5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite(.serialized) struct HDF5ReaderTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/low-level")
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    static func pins() throws -> PinFile {
        try JSONDecoder().decode(PinFile.self, from: Data(contentsOf: fixture("pins.json")))
    }

    /// The value h5py read, as the reader should return it.
    static func expected(_ pin: AttrPin) -> HDF5AttributeValue? {
        switch pin.type {
        case "text": .text(pin.value!.string!)
        case "texts": .texts(pin.value!.strings!)
        case "integer": .integer(pin.value!.int!)
        case "integers": .integers(pin.value!.ints!)
        case "real": .real(hexDouble(pin.value!.string!))
        case "reals": .reals(pin.value!.strings!.map(hexDouble))
        default: nil
        }
    }

    static func same(_ a: HDF5AttributeValue, _ b: HDF5AttributeValue) -> Bool {
        switch (a, b) {      // reals by bit pattern: exact, and NaN-safe
        case (.real(let x), .real(let y)): x.bitPattern == y.bitPattern
        case (.reals(let x), .reals(let y)): x.map(\.bitPattern) == y.map(\.bitPattern)
        default: a == b
        }
    }

    static func check(_ reader: HDF5Reader, _ path: String, _ pin: ObjectPin) throws {
        #expect(try reader.exists(path), "\(path)")
        for (name, attr) in pin.attrs ?? [:] {
            let label = "\(path)@\(name)"
            switch attr.type {
            case "unsupported":
                #expect(throws: HDF5FileError.unsupportedType(path: label, type: attr.name!), "\(label)") { try reader.attribute(name, of: path) }
            case "limit":
                #expect(throws: HDF5FileError.limitExceeded("\(label) holds an unsigned 64-bit value over \(Int64.max)"), "\(label)") {
                    try reader.attribute(name, of: path)
                }
            default:
                let got = try reader.attribute(name, of: path)
                #expect(same(got, expected(attr)!), "\(label): \(got)")
            }
        }
        if pin.kind == "other" {
            #expect(try reader.kind(of: path) == .other, "\(path)")
            return
        }
        #expect(try reader.attributeNames(of: path) == bytewiseSorted(Array((pin.attrs ?? [:]).keys)), "\(path) attribute names")
        if pin.kind == "group" {
            #expect(try reader.kind(of: path) == .group)
            #expect(try reader.children(of: path) == pin.children, "\(path) children")
            return
        }
        #expect(try reader.kind(of: path) == .dataset)
        let info = try reader.datasetInfo(path)
        #expect(info.shape == pin.shape, "\(path) shape")
        let type = pin.type!
        let kind = type.split(separator: ":", maxSplits: 1).map(String.init)
        switch kind[0] {
        case "numeric":
            #expect(info.type == .numeric(FormatoDataType(rawValue: kind[1])!), "\(path)")
            let all = try reader.readDataset(path)
            #expect(all.shape == pin.shape && all.dataType.rawValue == kind[1])
            #expect(sha256Hex(all.bytes) == pin.sha256, "\(path) bytes")
            if let slab = pin.slab {
                let part = try reader.readDataset(path, start: slab.start, count: slab.count)
                #expect(part.shape == slab.count && sha256Hex(part.bytes) == slab.sha256, "\(path) slab")
                #expect(part == (try all.slab(start: slab.start, count: slab.count)), "\(path) slab equals the eager slab")
            }
            #expect(throws: HDF5FileError.self) { try reader.readStrings(path) }
        case "string":
            #expect(info.type == .string(variableLength: kind[1] == "variable"), "\(path)")
            #expect(try reader.readStrings(path) == pin.strings, "\(path) strings")
            #expect(throws: HDF5FileError.self) { try reader.readDataset(path) }
        default:
            #expect(info.type == .unsupported(kind[1]), "\(path)")
            // float16 is the one "unsupported" type readDataset widens (to float32, since 0.7.0).
            if kind[1] != "float16" { #expect(throws: HDF5FileError.unsupportedType(path: path, type: kind[1])) { try reader.readDataset(path) } }
            #expect(throws: HDF5FileError.unsupportedType(path: path, type: kind[1])) { try reader.readStrings(path) }
        }
    }

    @Test(arguments: ["assorted.h5", "latest.h5"])
    func testEveryObjectReadsAsH5pyReadsIt(name: String) throws {
        let pinned = try #require(Self.pins().files[name])
        let reader = try HDF5Reader(url: Self.fixture(name))
        #expect(pinned.objects.count >= 3)
        for (path, pin) in pinned.objects { try Self.check(reader, path, pin) }
        for path in pinned.absent {
            #expect(try !reader.exists(path), "\(path)")
            #expect(throws: HDF5FileError.notFound(path)) { try reader.kind(of: path) }
        }
    }

    /// 0.7.0 asks: chunk shape, recursive listing, h5py bool, float16 widened (values from tools/hdf5-append/generate.py).
    @Test func testChunkShapeDescendantsBooleansAndHalfFloats() throws {
        let reader = try HDF5Reader(url: Self.fixture("assorted.h5"))
        #expect(try reader.chunkShape(of: "/a/data/chunked") == [2, 3, 7])
        #expect(try reader.chunkShape(of: "/a/data/rank1") == nil)
        #expect(throws: HDF5FileError.self) { try reader.chunkShape(of: "/a") }
        let pinned = try #require(Self.pins().files["assorted.h5"]).objects
        let all = try reader.descendants()
        #expect(Set(all.map(\.path)) == Set(pinned.keys).subtracting(["/"]))
        #expect(all.count == Set(all.map(\.path)).count)
        for (path, kind) in all { #expect(pinned[path]?.kind == (kind == .group ? "group" : kind == .dataset ? "dataset" : "other"), "\(path)") }
        #expect(try reader.descendants(of: "/strings").map(\.path) == ["/strings/fixed", "/strings/fixed_utf8", "/strings/long", "/strings/scalar_vlen", "/strings/variable"])
        #expect(throws: HDF5FileError.self) { try reader.descendants(of: "/a/data/chunked") }
        #expect(throws: HDF5FileError.self) { try reader.descendants(maximumObjects: 3) }
        #expect(try reader.readBooleans("/a/data/flags") == [true, false, true])
        #expect(throws: HDF5FileError.self) { try reader.readBooleans("/a/data/rank1") }
        let half = try reader.readDataset("/a/data/f16")
        #expect(half.dataType == .float32 && half.shape == [2])
        #expect(half.bytes == Data([0, 0, 0, 0x3F, 0, 0, 0xC0, 0x3F]))
    }

    @Test func testTheFixturesCoverTheTypesThatMatter() throws {
        let objects = try #require(Self.pins().files["assorted.h5"]).objects
        let types = Set(objects.values.compactMap(\.type))
        for need in ["numeric:int8", "numeric:uint64", "numeric:float32", "numeric:float64", "string:fixed", "string:variable",
                     "unsupported:enum", "unsupported:compound", "unsupported:float16"] { #expect(types.contains(need), "\(need)") }
        let attrTypes = Set(objects.values.flatMap { ($0.attrs ?? [:]).values.map(\.type) })
        for need in ["text", "texts", "integer", "integers", "real", "reals", "unsupported", "limit"] { #expect(attrTypes.contains(need), "\(need)") }
        #expect(objects["/dangling"]?.kind == "other" && objects["/link"]?.kind == "dataset")
        #expect(try #require(Self.pins().files["latest.h5"]).objects["/dense"]?.attrs?.count == 40)
    }

    // MARK: Values the pins cannot say by name

    @Test func testByteOrderAndSpecialValuesAreExact() throws {
        let reader = try HDF5Reader(url: Self.fixture("assorted.h5"))
        // Big-endian on disk, little-endian in the FormatoArray.
        let be = try reader.readDataset("/a/data/be_i2")
        #expect(be.dataType == .int16 && be.shape == [2, 3] && be.doubles() == [1, -2, 258, 300, -301, 32767])
        #expect(be.bytes.prefix(6) == Data([1, 0, 0xFE, 0xFF, 2, 1]))
        #expect(try reader.readDataset("/a/data/be_f8").doubles() == [0.1, -2.5e300, Double.pi])
        let f32 = try reader.readDataset("/a/data/f32").doubles()
        #expect(f32[1].isNaN && f32[2] == -.infinity)
        let u64 = try reader.readDataset("/a/data/u64").doubles()
        #expect(u64[23] == Double(UInt64.max))
        #expect(try reader.readDataset("/a/data/scalar_f8").doubles() == [2.718281828459045])
        let scalar = try reader.readDataset("/a/data/scalar_i4")
        #expect(scalar.shape == [] && scalar.doubles() == [-5])
        let empty = try reader.readDataset("/a/data/empty")
        #expect(empty.shape == [0, 3] && empty.bytes.isEmpty)
        #expect(try reader.attribute("u64fits", of: "/edge") == .integer(Int64.max))
        #expect(try reader.attribute("i64min", of: "/edge") == .integer(Int64.min))
        #expect(try reader.attribute("big_endian", of: "/") == .integers([258, 3]))
        #expect(try reader.readStrings("/strings/fixed_utf8") == ["Å日", "x"])
        #expect(try reader.readDataset("/link").doubles().count == 24, "a soft link is followed")
    }

    @Test func testZeroCountAndWholeDatasetSlabs() throws {
        let reader = try HDF5Reader(url: Self.fixture("assorted.h5"))
        let zero = try reader.readDataset("/a/data/chunked", start: [1, 2, 3], count: [0, 4, 4])
        #expect(zero.shape == [0, 4, 4] && zero.bytes.isEmpty)
        let corner = try reader.readDataset("/a/data/chunked", start: [4, 5, 6], count: [1, 1, 1])
        #expect(corner.doubles() == [Double(5 * 6 * 7 - 1)])
        let whole = try reader.readDataset("/a/data/chunked", start: [0, 0, 0], count: [5, 6, 7])
        #expect(whole == (try reader.readDataset("/a/data/chunked")))
    }

    // MARK: Refusals and bounds

    @Test func testRefusalsAreTypedErrors() throws {
        let reader = try HDF5Reader(url: Self.fixture("assorted.h5"))
        #expect(throws: HDF5FileError.notFound("/nope")) { try reader.children(of: "/nope") }
        #expect(throws: HDF5FileError.notFound("/nope")) { try reader.attributeNames(of: "/nope") }
        #expect(throws: HDF5FileError.notFound("/nope")) { try reader.datasetInfo("/nope") }
        #expect(throws: HDF5FileError.notFound("/nope")) { try reader.readDataset("/nope") }
        #expect(throws: HDF5FileError.notFound("/@missing")) { try reader.attribute("missing", of: "/") }
        #expect(throws: HDF5FileError.wrongKind(path: "/a/data/i8", expected: "group")) { try reader.children(of: "/a/data/i8") }
        #expect(throws: HDF5FileError.wrongKind(path: "/a", expected: "dataset")) { try reader.datasetInfo("/a") }
        #expect(throws: HDF5FileError.wrongKind(path: "/a", expected: "dataset")) { try reader.readDataset("/a") }
        for bad in ["", "/a/../b", "/a/./b", "a\0b"] {
            #expect(throws: HDF5FileError.invalidPath(bad), "\(bad.debugDescription)") { try reader.exists(bad) }
        }
        #expect(throws: HDF5FileError.invalidPath("")) { try reader.attribute("", of: "/") }
        // A slab outside the dataset, of the wrong rank, or negative.
        for (start, count) in [([0, 0, 0], [3, 3, 4]), ([0, 0, 1], [2, 3, 4]), ([0, 0], [2, 3]), ([-1, 0, 0], [1, 1, 1])] {
            #expect(throws: HDF5FileError.self, "\(start) \(count)") { try reader.readDataset("/a/data/i8", start: start, count: count) }
        }
        // The byte cap: 24 int8 values are 24 bytes.
        #expect(try reader.readDataset("/a/data/i8", maximumBytes: 24).bytes.count == 24)
        #expect(throws: HDF5FileError.limitExceeded("reading /a/data/i8 needs more than 23 bytes")) {
            try reader.readDataset("/a/data/i8", maximumBytes: 23)
        }
        // The string caps.
        #expect(try reader.readStrings("/strings/long", maximumStringBytes: 5000).first?.utf8.count == 5000)
        #expect(throws: HDF5FileError.stringTooLong(attribute: "/strings/long", bytes: 5000)) {
            try reader.readStrings("/strings/long", maximumStringBytes: 4999)
        }
        #expect(throws: HDF5FileError.stringTooLong(attribute: "/strings/fixed", bytes: 3)) {
            try reader.readStrings("/strings/fixed", maximumStringBytes: 2)
        }
        #expect(throws: HDF5FileError.limitExceeded("reading /strings/variable needs more than 31 bytes")) {
            try reader.readStrings("/strings/variable", maximumBytes: 31)
        }
    }

    @Test func testFilesThatAreNotReadableHDF5() throws {
        #expect(throws: HDF5FileError.self) { try HDF5Reader(url: URL(fileURLWithPath: "/nonexistent-dir/none.h5")) }
        let notHDF5 = HDF5RootAttributesTests.fixture("not-hdf5.h5")
        do { _ = try HDF5Reader(url: notHDF5); Issue.record("a text file opened as HDF5") } catch let error as HDF5FileError {
            guard case .cannotOpen = error else { Issue.record("\(error)"); return }
        }
        #expect(throws: HDF5FileError.cannotOpen("not a file URL")) { try HDF5Reader(url: URL(string: "https://example.com/a.h5")!) }
    }

    @Test func testReadingNeverChangesTheFile() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("copy.h5")
        try FileManager.default.copyItem(at: Self.fixture("assorted.h5"), to: copy)
        let before = try Data(contentsOf: copy)
        let reader = try HDF5Reader(url: copy)
        for (path, pin) in try #require(Self.pins().files["assorted.h5"]).objects { try Self.check(reader, path, pin) }
        #expect(try Data(contentsOf: copy) == before)
    }

    // MARK: Concurrency (every HDF5 call under HDF5Serial)

    @Test func testConcurrentReadersAgree() throws {
        let pinned = try #require(Self.pins().files["assorted.h5"]).objects
        let datasets = pinned.filter { $0.value.type?.hasPrefix("numeric:") == true }.map { ($0.key, $0.value.sha256!) }
        let reader = try HDF5Reader(url: Self.fixture("assorted.h5"))
        let failures = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            for round in 0..<10 {
                let (path, hash) = datasets[(i + round) % datasets.count]
                let ok = (try? sha256Hex(reader.readDataset(path).bytes)) == hash
                    && (try? reader.attribute("count", of: "/")) == .integer(7)
                    && (try? reader.children(of: "/a/data"))?.isEmpty == false
                if !ok { failures.add() }
            }
        }
        #expect(failures.value == 0)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
