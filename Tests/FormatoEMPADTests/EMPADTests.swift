import Foundation
import Testing
import FormatoCore
import FormatoEMPAD
import FormatoKitTestSupport

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
/// In this process, not a gzip child: a child would hold copies of other tests' HDF5 descriptors (FormatoKit#49).
private func inflate(_ name: String) throws -> Data { try Gunzip.contents(of: fixtures.appendingPathComponent(name)) }
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
            #expect(actual.bitwiseEquals(FormatoAxis(name: expected.name, size: expected.size,
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

/// 0.7.0 asks: `scan_resolution_x/y` under any raw file name, a raw file with no XML, the resolved raw path.
@Test func empadResolutionRawOnlyAndRawPath() throws {
    let dir = try temporaryPair()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = dir.appendingPathComponent("scan_x3_y2.raw")
    let reference = try EMPADReader(rawPath: original.path)               // the name carries x3 y2
    let expected = try reference.signal.load().data
    #expect(expected.shape == [2, 3, 128, 128])
    #expect(reference.rawPath == original.path)
    let renamed = dir.appendingPathComponent("capture.raw")
    try FileManager.default.copyItem(at: original, to: renamed)
    #expect(try EMPADReader(rawPath: renamed.path, scanSize: (y: 2, x: 3)).signal.load().data == expected)
    // 6 frames is not square: refused by name; a wrong explicit size is the length check.
    #expect(throws: EMPADError.self) { try EMPADReader(rawPath: renamed.path) }
    #expect(throws: EMPADError.self) { try EMPADReader(rawPath: renamed.path, scanSize: (y: 3, x: 3)) }
    // An XML with scan_resolution_x/y and an arbitrary raw name, as an acquire-mode header writes it.
    let xml = dir.appendingPathComponent("capture.xml")
    try """
    <root><raw_file filename="capture.raw"/><scan_parameters mode="acquire" scan_resolution_x="3" scan_resolution_y="2"/></root>
    """.write(to: xml, atomically: true, encoding: .utf8)
    let fromXML = try EMPADReader(path: xml.path)
    #expect(try fromXML.signal.load().data == expected)
    #expect(fromXML.rawPath == renamed.standardizedFileURL.path)
}

@Test func empadPreferScanResolutionPicksTheAcquisitionExtents() throws {
    let dir = try temporaryPair()
    defer { try? FileManager.default.removeItem(at: dir) }
    let xml = dir.appendingPathComponent("both.xml")
    let raw = dir.appendingPathComponent("scan_x3_y2.raw")
    let bytes = try Data(contentsOf: raw).count
    // pix_x/pix_y say 1 x 1 (the raw is 6 frames), scan_resolution says 3 x 2.
    try Data("<root><raw_file filename='scan_x3_y2.raw'/><pix_x>1</pix_x><pix_y>1</pix_y><scan_parameters><scan_resolution_x>3</scan_resolution_x><scan_resolution_y>2</scan_resolution_y></scan_parameters></root>".utf8).write(to: xml)
    #expect(bytes == 130 * 128 * 4 * 6)
    #expect(throws: EMPADError.self) { try EMPADReader(path: xml.path) }          // default: pix_x/pix_y first, length mismatch
    let preferred = try EMPADReader(path: xml.path, preferScanResolution: true)
    #expect(preferred.signal.array.shape.prefix(2) == [2, 3])
}

/// Two `scan_parameters` blocks, the acquisition first: its `scan_resolution_x/y` are the scan, wherever the block sits (the app read
/// the `mode="acquire"` block). `series_count` keeps RosettaSciIO 049e7d70: its XML dictionary keeps the LAST block (measured: acquire
/// series_count 3 then search 9 reads 9), so a planted pair gives the last block there.
@Test func empadTheAcquireBlockGivesTheScanWhereverItSits() throws {
    let dir = try temporaryPair()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = dir.appendingPathComponent("scan_x3_y2.raw")
    let expected = try EMPADReader(rawPath: original.path).signal.load().data
    try FileManager.default.copyItem(at: original, to: dir.appendingPathComponent("capture.raw"))
    let acquire = "<scan_parameters mode='acquire'><scan_resolution_x>3</scan_resolution_x><scan_resolution_y>2</scan_resolution_y></scan_parameters>"
    let search = "<scan_parameters mode='search'><scan_resolution_x>9</scan_resolution_x><scan_resolution_y>9</scan_resolution_y></scan_parameters>"
    let first: String = acquire + search, last: String = search + acquire
    let cases: [(String, String)] = [("first", first), ("last", last)]
    for (name, blocks) in cases {
        let xml = dir.appendingPathComponent(name + ".xml")
        let text: String = "<root><raw_file filename='capture.raw'/>" + blocks + "</root>"
        try Data(text.utf8).write(to: xml)
        for prefer in [false, true] {
            let reader = try EMPADReader(path: xml.path, preferScanResolution: prefer)
            #expect(reader.signal.array.shape == [2, 3, 128, 128], "\(name) \(prefer)")
            #expect(try reader.signal.load().data == expected, "\(name) \(prefer)")
        }
    }
    // series_count: the last block, as RosettaSciIO (6 frames as a series of 6; the acquire block says 3, which the length refuses).
    let series = dir.appendingPathComponent("series.xml")
    try Data("<root><raw_file filename='capture.raw'/><scan_parameters mode='acquire'><series_count>3</series_count></scan_parameters><scan_parameters mode='search'><series_count>6</series_count></scan_parameters></root>".utf8).write(to: series)
    #expect(try EMPADReader(path: series.path).signal.array.shape == [6, 128, 128])
}
