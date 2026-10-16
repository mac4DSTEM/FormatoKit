import Foundation
import Testing
import FormatoCore
import FormatoEMPAD

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
private struct Pins: Decodable { let cases: [Pin] }
private struct Pin: Decodable {
    let name: String
    let shape: [Int]
    let axes: [Axis]
    let metadata: [String: [String: String]]
    let options: [String: Double]
}
private struct Axis: Decodable {
    let name: String; let size: Int; let scale: Double; let offset: Double; let units: String?; let navigate: Bool
}
private func inflate(_ name: String) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-dc", fixtures.appendingPathComponent(name).path]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return data
}
private func temporaryPair() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try inflate("scan_x3_y2.raw.gz").write(to: dir.appendingPathComponent("scan_x3_y2.raw"))
    return dir
}

@Test func empadOracleBytesAxesAndMetadata() throws {
    let pins = try JSONDecoder().decode(Pins.self, from: Data(contentsOf: fixtures.appendingPathComponent("pins.json")))
    let dir = try temporaryPair()
    defer { try? FileManager.default.removeItem(at: dir) }
    for pin in pins.cases {
        let xml = dir.appendingPathComponent(pin.name + ".xml")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(pin.name + ".xml"), to: xml)
        let file = try EMPADReader(path: xml.path, qCalibration: pin.options["q_calibration"])
        let lazy = file.signal
        let eager = try lazy.load()
        #expect(eager.data.shape == pin.shape)
        #expect(eager.data.dataType == .float32)
        #expect(eager.data.bytes == (try inflate(pin.name + ".data.gz")))
        #expect(eager.title == pin.name)
        #expect(eager.signalType == "electron_diffraction")
        #expect(eager.axes.count == pin.axes.count)
        for (actual, expected) in zip(eager.axes, pin.axes) {
            #expect(actual.isBitwiseEqual(to: FormatoAxis(name: expected.name, size: expected.size,
                scale: expected.scale, offset: expected.offset, units: expected.units ?? "", navigate: expected.navigate)))
        }
        let expectedMetadata = pin.metadata.flatMap { group, values in values.map { (group + "." + $0.key, $0.value) } }
        #expect(eager.metadata.keys.sorted() == expectedMetadata.map(\.0).sorted())
        for (key, value) in expectedMetadata {
            #expect(eager.metadata[key]?.value.text == value)
            #expect(eager.metadata[key]?.provenance.file == pin.name + ".xml")
        }
        // Cross frame/row boundaries, crops, last pixel and empty slabs, including squeezed rank.
        for n in 0..<12 {
            let start = pin.shape.enumerated().map { ($0.offset * 17 + n * 13) % $0.element }
            let count = zip(start, pin.shape).map { min(3, $1 - $0) }
            #expect(try lazy.array.read(start: start, count: count) == eager.data.slab(start: start, count: count))
        }
        #expect(try lazy.array.read(start: pin.shape, count: pin.shape.map { _ in 0 }).bytes.isEmpty)
        #expect(throws: FormatoArrayError.self) { try lazy.array.read(start: [-1], count: [1]) }
    }
}

@Test func empadMalformedFilesThrowTypedErrors() throws {
    let dir = try temporaryPair()
    defer { try? FileManager.default.removeItem(at: dir) }
    let xml = dir.appendingPathComponent("legacy.xml")
    let raw = dir.appendingPathComponent("scan_x3_y2.raw")
    #expect(throws: EMPADError.self) { try EMPADReader(path: xml.path) }
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("legacy.xml"), to: xml)
    #expect(throws: EMPADError.self) { try EMPADReader(path: raw.path) }
    let bytes = try Data(contentsOf: raw)
    try bytes.dropLast().write(to: raw)
    #expect(throws: EMPADError.rawSizeMismatch(expected: bytes.count, actual: bytes.count - 1)) { try EMPADReader(path: xml.path) }
    try (bytes + Data([0])).write(to: raw)
    #expect(throws: EMPADError.rawSizeMismatch(expected: bytes.count, actual: bytes.count + 1)) { try EMPADReader(path: xml.path) }
    for body in ["<root>", "<root/>", "<root><raw_file filename='scan_x3_y2.raw'/><pix_x>0</pix_x><pix_y>2</pix_y></root>",
                 "<root><raw_file filename='scan_x3_y2.raw'/><pix_x>9223372036854775807</pix_x><pix_y>2</pix_y></root>"] {
        try Data(body.utf8).write(to: xml)
        #expect(throws: EMPADError.self) { try EMPADReader(path: xml.path) }
    }
}

@Test func empadMissingRawCalibrationAndMappingLifetime() throws {
    let dir = try temporaryPair()
    defer { try? FileManager.default.removeItem(at: dir) }
    let xml = dir.appendingPathComponent("scan_x3_y2.xml")
    let raw = dir.appendingPathComponent("scan_x3_y2.raw")
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("legacy.xml"), to: xml)
    let lazy = try EMPADReader(path: raw.path).signal
    // The mapping stays alive after the reader value leaves scope, without materializing the full signal.
    #expect(try lazy.array.read(start: [1, 2, 127, 127], count: [1, 1, 1, 1]).doubles() == [5.125])
    #expect(throws: EMPADError.self) { try EMPADReader(path: xml.path, qCalibration: .infinity) }
    let handle = try FileHandle(forWritingTo: raw)
    try handle.truncate(atOffset: 1)
    try handle.close()
    #expect(throws: EMPADError.self) { try lazy.load() }
    try FileManager.default.removeItem(at: raw)
    #expect(throws: EMPADError.self) { try EMPADReader(path: xml.path) }
}
