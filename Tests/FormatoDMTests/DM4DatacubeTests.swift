import Foundation
import Testing
import FormatoCore
import FormatoDM
private let gatherFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/gather")
private struct GatherPins: Decodable { let cases: [GatherPin] }
private struct GatherPin: Decodable { let name: String; let shape: [Int]; let dtype: String; let axes: [GatherAxis]; let app_shape: [Int]; let permutation: [Int] }
private struct GatherAxis: Decodable { let name: String?; let size: Int; let scale: Double; let offset: Double; let units: String; let navigate: Bool }
@Test func dm4GatherOracleAndAppBytesAxes() throws {
    let pins = try JSONDecoder().decode(GatherPins.self, from: Data(contentsOf: gatherFixtures.appendingPathComponent("pins.json")))
    for pin in pins.cases {
        let path = gatherFixtures.appendingPathComponent(pin.name + ".dm4").path
        let tree = try DM4Experiment.tagTree(path: path)
        #expect(tree.numbers.values.contains(200000))
        for convention in [DM4GatherConvention.rosettaSciIO, .appCalibratedAxes] {
            let cube = try DM4Datacube(path: path, convention: convention)
            let lazy = cube.signal
            let eager = try lazy.load()
            let app = convention == .appCalibratedAxes
            #expect(eager.data.shape == (app ? pin.app_shape : pin.shape))
            #expect(eager.data.dataType.rawValue == (app ? "float32" : pin.dtype))
            #expect(eager.data.bytes == (try Data(contentsOf: gatherFixtures.appendingPathComponent(pin.name + (app ? ".app.bin" : ".bin")))))
            #expect(cube.calibrationNote == nil)
            let permutation = app ? pin.permutation : [0,1,2,3]
            for i in 0..<4 {
                let e = pin.axes[permutation[i]]
                let a = eager.axes[i]
                #expect(a.scale.bitPattern == e.scale.bitPattern)
                #expect(a.offset.bitPattern == e.offset.bitPattern)
                #expect(a.units == e.units)
                #expect(a.size == e.size)
                if !app { #expect(a.name == e.name); #expect(a.navigate == e.navigate) }
            }
            for n in 0..<12 {
                let shape = eager.data.shape
                let start = shape.enumerated().map { ($0.offset * 5 + n * 3) % $0.element }
                let count = zip(start, shape).map { min(3, $1 - $0) }
                #expect(try lazy.array.read(start: start, count: count) == eager.data.slab(start: start, count: count))
            }
            #expect(try cube.frame(scanY: 0, scanX: 0) == eager.data.slab(start: [0,0,0,0], count: [1,1,eager.data.shape[2],eager.data.shape[3]]))
            #expect(try lazy.array.read(start: eager.data.shape, count: [0,0,0,0]).bytes.isEmpty)
            #expect(throws: FormatoArrayError.self) { try cube.frame(scanY: -1, scanX: 0) }
        }
    }
}
@Test func dm4GatherMappingLifetimeAndMalformedFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("test.dm4")
    #expect(throws: DM4Error.self) { try DM4Datacube(path: path.path) }
    let original = try Data(contentsOf: gatherFixtures.appendingPathComponent("scan-2.dm4"))
    for count in [0,15,original.count-1] {
        try original.prefix(count).write(to: path)
        #expect(throws: DM4Error.self) { try DM4Datacube(path: path.path) }
    }
    try original.write(to: path)
    #expect(throws: DM4Error.self) { try DM4Datacube(path: path.path, objectIndex: 999) }
    let lazy = try DM4Datacube(path: path.path, convention: .appCalibratedAxes).signal
    #expect(try lazy.array.read(start: [0,0,0,0], count: [1,1,1,1]).bytes.count == 4)
    let handle = try FileHandle(forWritingTo: path); try handle.truncate(atOffset: 1); try handle.close()
    #expect(throws: DM4Error.self) { try lazy.load() }
}
