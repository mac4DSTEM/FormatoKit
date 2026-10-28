//
//  HDF5AppendTests.swift
//  The append writer (HDF5AppendWriter, HDF5WriteSession): the operations in Fixtures/append/inputs.json (written by
//  tools/hdf5-append/generate.py, which also wrote base.h5 with h5py) applied to copies of base.h5, then
//    - read back through HDF5Reader against the operations, and every object they did not touch compared before and after;
//    - the committed swift-*.h5 files (this writer's output), which h5py has read in full and compared with "base.h5 plus the
//      operations" (check-result.json, pinned here with each file's SHA-256).
//  Atomicity (a failing body leaves the destination byte for byte), replace semantics, refusals, in-place mode, other files'
//  content surviving, and concurrent appends.
//
//  Regenerating the swift-*.h5 fixtures (a change on purpose): FORMATO_WRITE_GOLDEN=1 swift test -c release --filter
//  HDF5AppendTests, then tools/hdf5-append/generate.py (its docstring has the line), then commit both with check-result.json.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5

struct AppendOp: Decodable {
    var op: String
    var path: String?
    var dtype: String?
    var shape: [Int]?
    var hex: String?
    var chunk: [Int]?
    var replace: Bool?
    var on: String?
    var name: String?
    var type: String?
    var value: PinValue?
}
struct AppendScenario: Decodable { var name: String; var base: Bool; var file: String; var ops: [AppendOp] }
struct AppendInputs: Decodable { var scenarios: [AppendScenario] }
struct CheckResult: Decodable {
    struct Entry: Decodable { var sha256: String; var equals_base_plus_operations: Bool; var h5py_opens: Bool }
    var files: [String: Entry]
}

/// One object as the reader sees it: what must be unchanged when it was not touched.
struct Entry: Equatable {
    var kind: HDF5ObjectKind
    var attrs: [String: String]
    var children: [String]
    var data: String
}

func snapshot(_ url: URL) throws -> [String: Entry] {
    let reader = try HDF5Reader(url: url)
    var out: [String: Entry] = [:]
    func walk(_ path: String) throws {
        let kind = try reader.kind(of: path)
        var attrs: [String: String] = [:]
        for name in try reader.attributeNames(of: path) {
            attrs[name] = (try? "\(reader.attribute(name, of: path))") ?? "unsupported"
        }
        var data = "", children: [String] = []
        switch kind {
        case .group: children = try reader.children(of: path)
        case .dataset:
            let info = try reader.datasetInfo(path)
            switch info.type {
            case .numeric: data = "\(info.shape) \(info.type) \(sha256Hex(try reader.readDataset(path).bytes))"
            case .string: data = "\(info.shape) \(try reader.readStrings(path))"
            case .unsupported: data = "\(info.shape) \(info.type)"
            }
        case .other: break
        }
        out[path] = Entry(kind: kind, attrs: attrs, children: children, data: data)
        for child in children { try walk(path == "/" ? "/" + child : path + "/" + child) }
    }
    try walk("/")
    return out
}

func dataType(_ numpy: String) -> FormatoDataType {
    switch String(numpy.dropFirst()) {
    case "i1": .int8
    case "i2": .int16
    case "i4": .int32
    case "i8": .int64
    case "u1": .uint8
    case "u2": .uint16
    case "u4": .uint32
    case "u8": .uint64
    case "f4": .float32
    case "f8": .float64
    default: fatalError(numpy)
    }
}

func hexData(_ hex: String) -> Data {
    var data = Data(), index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

func array<T: BitwiseCopyable>(_ type: FormatoDataType, _ shape: [Int], _ values: [T]) -> FormatoArray {
    try! FormatoArray(dataType: type, shape: shape, bytes: values.withUnsafeBytes { Data($0) })
}

func attributeValue(_ op: AppendOp) -> HDF5AttributeValue {
    let v = op.value!
    switch op.type! {
    case "text": return .text(v.string!)
    case "texts": return .texts(v.strings!)
    case "integer": return .integer(v.int!)
    case "integers": return .integers(v.ints!)
    case "real": return .real(hexDouble(v.string!))
    default: return .reals(v.strings!.map(hexDouble))
    }
}

func apply(_ op: AppendOp, _ session: HDF5WriteSession) throws {
    switch op.op {
    case "group": try session.createGroup(op.path!)
    case "dataset":
        let a = try FormatoArray(dataType: dataType(op.dtype!), shape: op.shape!, bytes: hexData(op.hex!))
        try session.writeDataset(op.path!, a, chunk: op.chunk, replace: op.replace ?? false)
    case "attr": try session.setAttribute(op.name!, on: op.on!, attributeValue(op))
    case "delete": try session.deleteLink(op.path!)
    default: fatalError(op.op)
    }
}

/// The state the operations leave, computed from the operations alone.
struct Model {
    var datasets: [String: FormatoArray] = [:]
    var attributes: [String: [String: HDF5AttributeValue]] = [:]
    var groups: Set<String> = []
    var removed: Set<String> = []
    init(_ ops: [AppendOp]) throws {
        for op in ops {
            switch op.op {
            case "group": groups.insert(op.path!)
            case "dataset":
                datasets[op.path!] = try FormatoArray(dataType: dataType(op.dtype!), shape: op.shape!, bytes: hexData(op.hex!))
                removed.remove(op.path!)
            case "attr": attributes[op.on!, default: [:]][op.name!] = attributeValue(op)
            default:
                let gone = op.path!
                removed.insert(gone)
                datasets = datasets.filter { $0.key != gone && !$0.key.hasPrefix(gone + "/") }
                attributes = attributes.filter { $0.key != gone && !$0.key.hasPrefix(gone + "/") }
            }
        }
    }
}

@Suite(.serialized) struct HDF5AppendTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/append")
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    static var golden: Bool { ProcessInfo.processInfo.environment["FORMATO_WRITE_GOLDEN"] != nil }
    static func scenarios() throws -> [AppendScenario] {
        try JSONDecoder().decode(AppendInputs.self, from: Data(contentsOf: fixture("inputs.json"))).scenarios
    }

    /// Applies the scenario's operations at `destination` (a copy of base.h5 first when it has a base).
    static func run(_ scenario: AppendScenario, at destination: URL, mode: HDF5AppendMode = .atomicCopy) throws {
        try? FileManager.default.removeItem(at: destination)
        if scenario.base { try FileManager.default.copyItem(at: fixture("base.h5"), to: destination) }
        try HDF5AppendWriter.append(to: destination, mode: mode) { session in
            for op in scenario.ops { try apply(op, session) }
        }
    }

    /// `url` holds exactly the operations' effect on `before` (nil: a new file).
    static func verify(_ url: URL, _ scenario: AppendScenario, before: [String: Entry]?, _ label: String) throws {
        let model = try Model(scenario.ops)
        let reader = try HDF5Reader(url: url)
        for (path, expected) in model.datasets {
            let got = try reader.readDataset(path)
            #expect(got == expected, "\(label): \(path)")
            #expect(try reader.kind(of: path) == .dataset)
        }
        for (path, names) in model.attributes {
            for (name, value) in names { #expect(HDF5ReaderTests.same(try reader.attribute(name, of: path), value), "\(label): \(path)@\(name)") }
        }
        for path in model.groups { #expect(try reader.kind(of: path) == .group, "\(label): \(path)") }
        for path in model.removed { #expect(try !reader.exists(path), "\(label): \(path) was removed") }
        guard let before else { return }
        let after = try snapshot(url)
        let touchedAttributes = Dictionary(grouping: scenario.ops.filter { $0.op == "attr" }, by: { $0.on! }).mapValues { Set($0.map { $0.name! }) }
        for (path, was) in before {
            if model.removed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let now = try #require(after[path], "\(label): \(path) vanished")
            #expect(now.kind == was.kind, "\(label): \(path)")
            let skip = touchedAttributes[path] ?? []
            if model.datasets[path] == nil {         // a replaced dataset is a new object: it starts with no attributes
                #expect(now.attrs.filter { !skip.contains($0.key) } == was.attrs.filter { !skip.contains($0.key) }, "\(label): \(path) attributes")
            }
            if was.kind == .group {
                let kept = was.children.filter { child in
                    let full = path == "/" ? "/" + child : path + "/" + child
                    return !model.removed.contains(full)
                }
                #expect(Set(kept).isSubset(of: Set(now.children)), "\(label): \(path) children")
            } else if model.datasets[path] == nil {
                #expect(now.data == was.data, "\(label): \(path) data")
            }
        }
    }

    // MARK: The scenarios

    @Test func testOperationsLandAndNothingElseMoves() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let before = try snapshot(Self.fixture("base.h5"))
        for scenario in try Self.scenarios() {
            let destination = dir.appendingPathComponent(scenario.file)
            try Self.run(scenario, at: destination)
            try Self.verify(destination, scenario, before: scenario.base ? before : nil, scenario.name)
            if Self.golden {
                let committed = Self.fixture(scenario.file)
                try? FileManager.default.removeItem(at: committed)
                try Self.run(scenario, at: committed)
            }
        }
    }

    @Test func testInPlaceGivesTheSameResultAsTheAtomicCopy() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let before = try snapshot(Self.fixture("base.h5"))
        for scenario in try Self.scenarios() {
            let destination = dir.appendingPathComponent("inplace-" + scenario.file)
            try Self.run(scenario, at: destination, mode: .inPlace)
            try Self.verify(destination, scenario, before: scenario.base ? before : nil, scenario.name)
            let atomic = dir.appendingPathComponent("atomic-" + scenario.file)
            try Self.run(scenario, at: atomic)
            #expect(try snapshot(destination) == snapshot(atomic), "\(scenario.name)")
        }
    }

    @Test func testH5pyReadTheCommittedSwiftFilesAndFoundThemEqualToBasePlusOperations() throws {
        let result = try JSONDecoder().decode(CheckResult.self, from: Data(contentsOf: Self.fixture("check-result.json")))
        let before = try snapshot(Self.fixture("base.h5"))
        let scenarios = try Self.scenarios()
        #expect(Set(result.files.keys) == Set(scenarios.map(\.file)))
        for scenario in scenarios {
            let url = Self.fixture(scenario.file)
            let pinned = try #require(result.files[scenario.file])
            #expect(pinned.equals_base_plus_operations && pinned.h5py_opens, "h5py's verdict on \(scenario.file)")
            #expect(sha256Hex(try Data(contentsOf: url)) == pinned.sha256, "\(scenario.file) is not the file h5py checked")
            try Self.verify(url, scenario, before: scenario.base ? before : nil, "committed " + scenario.name)
        }
    }

    @Test func testBaseFixtureIsWhatTheModelAssumes() throws {
        let reader = try HDF5Reader(url: Self.fixture("base.h5"))
        #expect(try reader.children(of: "/") == ["empty", "grp1", "keep", "orphan", "strs"])
        #expect(try reader.attribute("version", of: "/") == .integer(3))
        #expect(try reader.readDataset("/grp1/data").doubles() == (0..<12).map { (i: Int) -> Double in Double(i * 11 - 5) })
    }

    // MARK: Atomicity

    struct Boom: Error {}

    /// `.formato-append-*` scratch files in the system's item-replacement area, which a failed append must not leave.
    static func scratchFiles(near destination: URL) -> [String] {
        guard let probe = HDF5RootAttributes.temporaryURL(for: destination).scratchDirectory else { return [] }
        defer { try? FileManager.default.removeItem(at: probe) }
        let parent = probe.deletingLastPathComponent()
        let directories = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return directories.flatMap { dir -> [String] in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".formato-append-") }
        }
    }

    @Test func testAFailingBodyLeavesTheDestinationByteForByteAndNoScratch() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        let before = try Data(contentsOf: destination)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let scratchBefore = Self.scratchFiles(near: destination)
        #expect(scratchBefore.isEmpty)
        // 1. The body throws its own error after it has written.
        #expect(throws: Boom.self) {
            try HDF5AppendWriter.append(to: destination) { s in
                try s.writeDataset("/zzz", array(.int32, [2], [Int32(1), 2]))
                try s.setAttribute("x", on: "/", .text("y"))
                try s.deleteLink("/keep")
                throw Boom()
            }
        }
        #expect(try Data(contentsOf: destination) == before)
        // 2. An HDF5 refusal partway (the second write hits an existing path).
        #expect(throws: HDF5FileError.alreadyExists("/orphan")) {
            try HDF5AppendWriter.append(to: destination) { s in
                try s.createGroup("/made/first")
                try s.writeDataset("/orphan", array(.float64, [], [1.0]))
            }
        }
        #expect(try Data(contentsOf: destination) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == siblings)
        #expect(Self.scratchFiles(near: destination) == scratchBefore)
        // 3. A new file is not created by a failing body.
        let fresh = dir.appendingPathComponent("fresh.h5")
        #expect(throws: Boom.self) { try HDF5AppendWriter.append(to: fresh) { s in try s.createGroup("/g"); throw Boom() } }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        #expect(Self.scratchFiles(near: fresh) == scratchBefore)
    }

    @Test func testNotHDF5DestinationIsRefusedAndKept() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("text.h5")
        try Data("this is not an HDF5 file\n".utf8).write(to: destination)
        for mode in [HDF5AppendMode.atomicCopy, .inPlace] {
            do { try HDF5AppendWriter.append(to: destination, mode: mode) { _ in Issue.record("body ran") }; Issue.record("no error") }
            catch let error as HDF5FileError { guard case .cannotOpen = error else { Issue.record("\(error)"); return } }
        }
        #expect(try Data(contentsOf: destination) == Data("this is not an HDF5 file\n".utf8))
        #expect(Self.scratchFiles(near: destination).isEmpty)
    }

    @Test func testAFileReplacedDuringTheBodyIsNotOverwritten() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        let other = Data("someone else's file".utf8)
        do {
            try HDF5AppendWriter.append(to: destination) { s in
                try s.createGroup("/g")
                try FileManager.default.removeItem(at: destination)
                try other.write(to: destination)
            }
            Issue.record("published over a file that was not the one copied")
        } catch let error as HDF5FileError {
            guard case .cannotWrite(let operation, _) = error else { Issue.record("\(error)"); return }
            #expect(operation == "publishing the file")
        }
        #expect(try Data(contentsOf: destination) == other)
        #expect(Self.scratchFiles(near: destination).isEmpty)
    }

    @Test func testANewFileThatAppearedDuringTheBodyIsNotOverwritten() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("new.h5")
        let other = Data("appeared meanwhile".utf8)
        #expect(throws: HDF5FileError.self) {
            try HDF5AppendWriter.append(to: destination) { s in try s.createGroup("/g"); try other.write(to: destination) }
        }
        #expect(try Data(contentsOf: destination) == other)
    }

    @Test func testInPlaceIsNotAtomicAndRemovesAFileItCreated() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        #expect(throws: Boom.self) {
            try HDF5AppendWriter.append(to: destination, mode: .inPlace) { s in try s.createGroup("/partial"); throw Boom() }
        }
        #expect(try HDF5Reader(url: destination).exists("/partial"), "documented: an in-place failure keeps what was done before it")
        #expect(try HDF5Reader(url: destination).exists("/grp1/data"))
        let fresh = dir.appendingPathComponent("fresh.h5")
        #expect(throws: Boom.self) { try HDF5AppendWriter.append(to: fresh, mode: .inPlace) { s in try s.createGroup("/g"); throw Boom() } }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        // A file that already exists is never created over in place either.
        try HDF5AppendWriter.append(to: fresh, mode: .inPlace) { s in try s.createGroup("/g") }
        try HDF5AppendWriter.append(to: fresh, mode: .inPlace) { s in try s.createGroup("/h") }
        #expect(try HDF5Reader(url: fresh).children(of: "/") == ["g", "h"])
    }

    @Test func testDestinationThatIsASymbolicLinkOrADirectoryIsRefused() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.h5"), link = dir.appendingPathComponent("link.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let before = try Data(contentsOf: target)
        #expect(throws: HDF5FileError.self) { try HDF5AppendWriter.append(to: link) { s in try s.createGroup("/g") } }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try Data(contentsOf: target) == before)
        // In place follows the link and changes the target.
        try HDF5AppendWriter.append(to: link, mode: .inPlace) { s in try s.createGroup("/g") }
        #expect(try HDF5Reader(url: target).exists("/g"))
        #expect(throws: HDF5FileError.cannotOpen("not a regular file")) { try HDF5AppendWriter.append(to: dir) { _ in } }
        #expect(throws: HDF5FileError.cannotOpen("not a file URL")) {
            try HDF5AppendWriter.append(to: URL(string: "https://example.com/a.h5")!) { _ in }
        }
    }

    // MARK: Datasets

    @Test func testExistingPathsAreRefusedUnlessReplaceIsAsked() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        try HDF5AppendWriter.append(to: destination) { s in
            #expect(throws: HDF5FileError.alreadyExists("/orphan")) { try s.writeDataset("/orphan", array(.int8, [1], [Int8(1)])) }
            #expect(throws: HDF5FileError.alreadyExists("/grp1")) { try s.writeDataset("/grp1", array(.int8, [1], [Int8(1)])) }
            #expect(throws: HDF5FileError.alreadyExists("/grp1 (a group; use deleteLink)")) {
                try s.writeDataset("/grp1", array(.int8, [1], [Int8(1)]), replace: true)
            }
            #expect(throws: HDF5FileError.wrongKind(path: "/orphan", expected: "group")) {
                try s.writeDataset("/orphan/inside", array(.int8, [1], [Int8(1)]))
            }
            #expect(throws: HDF5FileError.wrongKind(path: "/orphan", expected: "group")) { try s.createGroup("/orphan/deeper/still") }
            #expect(throws: HDF5FileError.wrongKind(path: "/orphan", expected: "group")) { try s.createGroup("/orphan") }
            #expect(try !s.exists("/orphan/deeper"), "a refused createGroup created nothing")
            try s.writeDataset("/orphan", array(.int16, [2, 2], [Int16(1), 2, 3, 4]), replace: true)       // another type and shape
            try s.writeDataset("/grp1/data", array(.float32, [3], [Float(0.5), 1.5, 2.5]), chunk: [3], replace: true)
        }
        let reader = try HDF5Reader(url: destination)
        #expect(try reader.readDataset("/orphan") == array(.int16, [2, 2], [Int16(1), 2, 3, 4]))
        #expect(try reader.readDataset("/grp1/data") == array(.float32, [3], [Float(0.5), 1.5, 2.5]))
        #expect(try reader.attributeNames(of: "/orphan").isEmpty, "a replaced dataset starts without the old attributes")
        #expect(try reader.readDataset("/grp1/sub/arr").doubles() == [1.5, -2.5, 3.25, 4.0, 5.0])
    }

    @Test func testChunkAndTypeRefusalsLeaveTheFileAsItWas() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        let before = try snapshot(destination)
        let a = array(.int32, [4, 6], [Int32](0..<24))
        try HDF5AppendWriter.append(to: destination) { s in
            for chunk in [[2], [0, 3], [5, 3], [2, 7], [-1, 2], [2, 3, 1]] {
                #expect(throws: HDF5FileError.invalidArgument("chunk \(chunk) does not fit shape [4, 6]"), "\(chunk)") {
                    try s.writeDataset("/bad", a, chunk: chunk)
                }
            }
            #expect(throws: HDF5FileError.self) { try s.writeDataset("/scalar", array(.int32, [], [Int32(1)]), chunk: []) }
            #expect(throws: HDF5FileError.self) { try s.writeDataset("/empty", array(.int32, [0, 3], [Int32]()), chunk: [1, 1]) }
            let colour = try FormatoArray(dataType: .rgb8, shape: [1], bytes: Data([1, 2, 3]))
            #expect(throws: HDF5FileError.invalidArgument("the rgb8 type cannot be written")) { try s.writeDataset("/colour", colour) }
            #expect(throws: HDF5FileError.limitExceeded("rank 33")) {
                try s.writeDataset("/rank33", array(.uint8, [Int](repeating: 1, count: 33), [UInt8(1)]))
            }
            #expect(throws: HDF5FileError.invalidPath("/")) { try s.writeDataset("/", a) }
            #expect(throws: HDF5FileError.invalidPath("/a/../b")) { try s.writeDataset("/a/../b", a) }
            #expect(try !s.exists("/bad") && !s.exists("/colour") && !s.exists("/rank33"))
        }
        let after = try snapshot(destination)
        #expect(after == before)
    }

    @Test func testChunkedDatasetsAreChunked() throws {
        // The reader has no layout query; the bytes of a chunked write must equal the contiguous one's, and h5py (the
        // `appended` scenario's /new/f32, chunk [2, 5]) checks the chunk shape itself.
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("c.h5")
        let a = array(.float64, [5, 7, 3], (0..<105).map { Double($0) / 3 })
        try HDF5AppendWriter.append(to: destination) { s in
            try s.writeDataset("/contiguous", a)
            try s.writeDataset("/chunked", a, chunk: [2, 7, 3])
            try s.writeDataset("/chunked_edge", a, chunk: [5, 7, 3])
        }
        let reader = try HDF5Reader(url: destination)
        for name in ["contiguous", "chunked", "chunked_edge"] { #expect(try reader.readDataset("/" + name) == a, "\(name)") }
        #expect(try reader.readDataset("/chunked", start: [1, 2, 1], count: [3, 4, 2]) == (try a.slab(start: [1, 2, 1], count: [3, 4, 2])))
    }

    @Test func testEveryNumericTypeRoundTripsItsExtremes() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("t.h5")
        let all: [FormatoArray] = [
            array(.int8, [3], [Int8.min, 0, .max]), array(.int16, [3], [Int16.min, 0, .max]),
            array(.int32, [3], [Int32.min, 0, .max]), array(.int64, [3], [Int64.min, 0, .max]),
            array(.uint8, [3], [UInt8.min, 7, .max]), array(.uint16, [3], [UInt16.min, 7, .max]),
            array(.uint32, [3], [UInt32.min, 7, .max]), array(.uint64, [3], [UInt64.min, 7, .max]),
            array(.float32, [4], [Float.leastNonzeroMagnitude, -0.0, .infinity, Float(bitPattern: 0x7FC0_1234)]),
            array(.float64, [4], [Double.greatestFiniteMagnitude, -0.0, -.infinity, Double(bitPattern: 0x7FF8_0000_0000_1234)]),
        ]
        try HDF5AppendWriter.append(to: destination) { s in
            for a in all { try s.writeDataset("/types/\(a.dataType.rawValue)", a) }
        }
        let reader = try HDF5Reader(url: destination)
        for a in all {
            let got = try reader.readDataset("/types/\(a.dataType.rawValue)")
            #expect(got == a, "\(a.dataType)")        // equal bytes: NaN payloads and the sign of zero included
            #expect(try reader.datasetInfo("/types/\(a.dataType.rawValue)") == HDF5DatasetInfo(shape: a.shape, type: .numeric(a.dataType)))
        }
    }

    // MARK: Attributes and links

    @Test func testAttributesReplaceByNameAndChangeType() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        try HDF5AppendWriter.append(to: destination) { s in
            try s.setAttribute("a", on: "/orphan", .text("a long first text"))
            try s.setAttribute("a", on: "/orphan", .text("short"))
            try s.setAttribute("n", on: "/orphan", .integer(1))
            try s.setAttribute("n", on: "/orphan", .reals([0.5, .infinity, -0.0]))
            try s.setAttribute("e", on: "/orphan", .texts([]))
            try s.setAttribute("z", on: "/orphan", .integers([]))
            try s.setAttribute("only", on: "/", .real(1e-300))
            try s.setAttribute("title", on: "/grp1", .text(""))
            try s.setAttribute("multi", on: "/grp1/data", .texts(["Å日", "x", ""]))
            #expect(throws: HDF5FileError.embeddedNUL("bad")) { try s.setAttribute("bad", on: "/", .text("a\0b")) }
            #expect(throws: HDF5FileError.embeddedNUL("bad")) { try s.setAttribute("bad", on: "/", .texts(["ok", "a\0b"])) }
            #expect(throws: HDF5FileError.notFound("/nope")) { try s.setAttribute("x", on: "/nope", .integer(1)) }
            #expect(throws: HDF5FileError.invalidPath("")) { try s.setAttribute("", on: "/", .integer(1)) }
            #expect(throws: HDF5FileError.invalidPath("a\0b")) { try s.setAttribute("a\0b", on: "/", .integer(1)) }
        }
        let reader = try HDF5Reader(url: destination)
        #expect(try reader.attribute("a", of: "/orphan") == .text("short"))
        #expect(try reader.attribute("n", of: "/orphan") == .reals([0.5, .infinity, -0.0]))
        #expect(try reader.attribute("e", of: "/orphan") == .texts([]))
        #expect(try reader.attribute("z", of: "/orphan") == .integers([]))
        #expect(try reader.attributeNames(of: "/orphan") == ["a", "e", "n", "z"])
        #expect(try reader.attribute("only", of: "/") == .real(1e-300))
        #expect(try reader.attribute("title", of: "/grp1") == .text(""))
        #expect(try reader.attribute("multi", of: "/grp1/data") == .texts(["Å日", "x", ""]))
        #expect(try !reader.attributeNames(of: "/").contains("bad"))
        // The attribute that was not named stays.
        #expect(try reader.attribute("units", of: "/grp1/data") == .text("counts"))
    }

    @Test func testTextAttributesAreFixedLengthNullPaddedUTF8() throws {
        // Same layout as HDF5RootAttributes.write: read back by the sidecar reader, which takes only that layout.
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("s.h5")
        try HDF5AppendWriter.append(to: destination) { s in
            try s.setAttribute("text", on: "/", .text("Å 日本 😀 text"))
            try s.setAttribute("empty", on: "/", .text(""))
            try s.setAttribute("long", on: "/", .text(String(repeating: "x", count: 30000)))
        }
        let got = try HDF5RootAttributes.read(["text", "empty", "long"], from: destination)
        #expect(got["text"] == "Å 日本 😀 text" && got["empty"] == "" && got["long"]?.utf8.count == 30000)
    }

    @Test func testDeleteLinkRemovesTheSubtreeAndRefusesTheRest() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        try HDF5AppendWriter.append(to: destination) { s in
            try s.deleteLink("/grp1")
            #expect(try !s.exists("/grp1") && !s.exists("/grp1/data"))
            #expect(throws: HDF5FileError.notFound("/grp1")) { try s.deleteLink("/grp1") }
            #expect(throws: HDF5FileError.notFound("/never/was")) { try s.deleteLink("/never/was") }
            #expect(throws: HDF5FileError.invalidPath("/")) { try s.deleteLink("/") }
            try s.deleteLink("empty")                                                     // no leading slash is the same path
            try s.createGroup("/grp1/again")                                                // the name is free again
        }
        let reader = try HDF5Reader(url: destination)
        #expect(try reader.children(of: "/") == ["grp1", "keep", "orphan", "strs"])
        #expect(try reader.children(of: "/grp1") == ["again"])
        #expect(try reader.readDataset("/keep").doubles() == [0, 1, 2, 3, 4, 5])
    }

    @Test func testASessionIsDeadOutsideItsBody() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("a.h5")
        var kept: HDF5WriteSession?
        try HDF5AppendWriter.append(to: destination) { s in kept = s; try s.createGroup("/g") }
        let dead = try #require(kept)
        let message = HDF5FileError.invalidArgument("the write session is closed")
        #expect(throws: message) { try dead.exists("/g") }
        #expect(throws: message) { try dead.createGroup("/h") }
        #expect(throws: message) { try dead.writeDataset("/d", array(.int8, [1], [Int8(1)])) }
        #expect(throws: message) { try dead.setAttribute("a", on: "/", .integer(1)) }
        #expect(throws: message) { try dead.deleteLink("/g") }
        #expect(try HDF5Reader(url: destination).children(of: "/") == ["g"])
    }

    // MARK: Other writers' files

    @Test func testSidecarRootAttributesSurviveAnAppend() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("sidecar.h5")
        let attributes = HDF5RootAttributesTests.golden
        try HDF5RootAttributes.write(attributes, to: destination)
        try HDF5AppendWriter.append(to: destination) { s in
            try s.writeDataset("/maps/a", array(.float32, [2, 2], [Float(1), 2, 3, 4]), chunk: [2, 2])
            try s.setAttribute("note", on: "/maps", .text("added"))
        }
        let names = attributes.map(\.name)
        let got = try HDF5RootAttributes.read(names, from: destination)
        for (name, value) in attributes { #expect(got[name] == value, "\(name)") }
    }

    @Test func testBraggVectorsFileStillReadsAfterAnAppend() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/bragg/basic.h5")
        let destination = dir.appendingPathComponent("bragg.h5")
        try FileManager.default.copyItem(at: source, to: destination)
        let before = try BraggVectorsEMD.read(path: destination.path)
        let snapshotBefore = try snapshot(destination)
        try HDF5AppendWriter.append(to: destination) { s in
            try s.writeDataset("/extra/map", array(.float64, [2], [1.0, 2.0]))
            try s.setAttribute("appended", on: "/", .text("yes"))
        }
        let after = try BraggVectorsEMD.read(path: destination.path)
        #expect(after.peaks == before.peaks && after.scan == before.scan && after.detector == before.detector)
        #expect(after.calibration == before.calibration)
        let snapshotAfter = try snapshot(destination)
        for (path, was) in snapshotBefore where was.kind == .dataset { #expect(snapshotAfter[path]?.data == was.data, "\(path)") }
    }

    // MARK: Concurrency

    @Test func testConcurrentAppendsToOneFileAllLand() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("shared.h5")
        try FileManager.default.copyItem(at: Self.fixture("base.h5"), to: destination)
        let before = try snapshot(destination)
        let failures = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            do {
                try HDF5AppendWriter.append(to: destination) { s in
                    try s.writeDataset("/t/\(i)", array(.int32, [4], [Int32](repeating: Int32(i), count: 4)))
                    try s.setAttribute("who", on: "/t/\(i)", .integer(Int64(i)))
                }
                _ = try HDF5Reader(url: destination).children(of: "/")
            } catch { failures.add() }
        }
        #expect(failures.value == 0)
        let reader = try HDF5Reader(url: destination)
        #expect(try reader.children(of: "/t") == (0..<8).map(String.init))
        for i in 0..<8 {
            #expect(try reader.readDataset("/t/\(i)") == array(.int32, [4], [Int32](repeating: Int32(i), count: 4)))
            #expect(try reader.attribute("who", of: "/t/\(i)") == .integer(Int64(i)))
        }
        let after = try snapshot(destination)
        for (path, was) in before where was.kind == .dataset { #expect(after[path]?.data == was.data, "\(path)") }
        #expect(Self.scratchFiles(near: destination).isEmpty)
    }

    @Test func testConcurrentIndependentFilesAndReadersDoNotCrossTalk() throws {
        let dir = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let failures = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            do {
                let file = dir.appendingPathComponent("f\(i).h5")
                for round in 0..<5 {
                    try HDF5AppendWriter.append(to: file, mode: round % 2 == 0 ? .atomicCopy : .inPlace) { s in
                        try s.writeDataset("/r\(round)", array(.float64, [3], [Double(i), Double(round), 0.5]))
                    }
                    let got = try HDF5Reader(url: file).readDataset("/r\(round)")
                    if got != array(.float64, [3], [Double(i), Double(round), 0.5]) { failures.add() }
                }
                if try HDF5Reader(url: file).children(of: "/").count != 5 { failures.add() }
            } catch { failures.add() }
        }
        #expect(failures.value == 0)
    }
}
