import Foundation
import Testing
import FormatoCore
import FormatoHDF5

struct DatacubeTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/4d")
    }
    @Test func pinnedPy4DSTEMCubesAndHyperslabs() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as! [String: Any]
        #expect(json["py4dstem_commit"] as? String == "f050d207851f8accd3aa550365baaf1f38230428")
        for pin in json["cases"] as! [[String: Any]] {
            let name = pin["name"] as! String
            let path = fixtures.appendingPathComponent(name + ".h5").path
            let cube = try HDF5Datacube(path: path, datasetPath: pin["dataset"] as! String)
            #expect(cube.shape == pin["shape"] as! [Int])
            #expect(cube.dataType.rawValue == pin["dtype"] as! String)
            let expected = try FormatoArray(dataType: cube.dataType, shape: cube.shape,
                bytes: Data(contentsOf: fixtures.appendingPathComponent(name + ".bin")))
            #expect(try cube.readAll() == expected)
            for (start, count) in (name == "singleton" ? [([0,1,3,4],[1,2,7,9])] : [([1,2,3,4],[2,1,7,9]), ([3,3,15,15],[1,1,1,1]), ([4,0,0,0],[0,4,16,16])]) {
                #expect(try cube.read(start: start, count: count) == expected.slab(start: start, count: count))
            }
            let signal = cube.signal
            #expect(signal.axes.map(\.name) == ["Rx", "Ry", "Qx", "Qy"])
            let provenance = try #require(cube.calibration["QR_rotation"]?.provenance)
            #expect(provenance.file == name + ".h5")
            #expect(provenance.source == "/cube_root/metadatabundle/calibration/QR_rotation")
            #expect(!provenance.rule.isEmpty)
            for i in 0..<4 {
                #expect(signal.axes[i].size == cube.shape[i])
                #expect(signal.axes[i].navigate == (i < 2))
                #expect(signal.axes[i].scale.bitPattern == (pin[i < 2 ? "R_pixel_size" : "Q_pixel_size"] as! Double).bitPattern)
                #expect(signal.axes[i].offset.bitPattern == (pin["offsets"] as! [Double])[i].bitPattern)
                #expect(signal.axes[i].units == pin[i < 2 ? "R_pixel_units" : "Q_pixel_units"] as! String)
            }
            #expect(signal.metadata["QR_flip"]?.value == .flag(pin["QR_flip"] as! Bool))
            #expect(signal.metadata["QR_rotation"]?.value.number?.bitPattern == (pin["QR_rotation"] as! Double).bitPattern)
            for (key,value) in pin["scalars"] as! [String:Double] {
                #expect(cube.calibration[key]?.value.number?.bitPattern == value.bitPattern)
            }
            for component in HDF5OriginComponent.allCases {
                let map = try #require(try cube.originMap(component))
                let expectedMap = try FormatoArray(dataType: .float64, shape: Array(cube.shape.prefix(2)),
                    bytes: Data(contentsOf: fixtures.appendingPathComponent(name + "." + component.rawValue + ".bin")))
                #expect(try map.readAll() == expectedMap)
                #expect(try map.read(start: [0,2], count: [1,1]) == expectedMap.slab(start: [0,2], count: [1,1]))
            }
            #expect(try signal.load().data == expected)
            #expect(throws: FormatoArrayError.self) { try cube.read(start: [-1,0,0,0], count: [1,1,1,1]) }
            #expect(throws: FormatoArrayError.self) { try cube.read(start: [0,0,0,0], count: [Int.max,1,1,1]) }
        }
    }
    @Test func attributeCalibrationAndDimensionFallback() throws {
        let path = fixtures.appendingPathComponent("attributes.h5").path
        let cube = try HDF5Datacube(path: path, datasetPath: "/cube/data")
        #expect(cube.shape == [2,3,4,4])
        #expect(try cube.readAll().bytes == Data(contentsOf: fixtures.appendingPathComponent("attributes.bin")))
        #expect(cube.axes.map(\.scale) == [2.5,2.5,0.125,0.125])
        #expect(cube.axes.map(\.units) == ["nm","nm","1/nm","1/nm"])
        #expect(cube.calibration["QR_flip"]?.value == .flag(true))
        #expect(try cube.originMap(.fittedX) == nil)
        // Separate root without a calibration bundle exercises EMD dim-vector fallback.
        let fallback = try HDF5Datacube(path: path, datasetPath: "/uncalibrated/fallback/data")
        #expect(try fallback.readAll().bytes == Data(contentsOf: fixtures.appendingPathComponent("fallback.bin")))
        #expect(fallback.axes.map(\.scale) == [0.25,0.25,0.25,0.25])
        #expect(fallback.axes.map(\.offset) == [-1.5,-1.5,-1.5,-1.5])
        #expect(fallback.axes.map(\.units) == ["nm","nm","nm","nm"])
    }
    @Test func malformedCubesThrowTypedErrors() throws {
        let path = fixtures.appendingPathComponent("malformed.h5").path
        for dataset in ["/rank3", "/empty", "/complex", "/missing", "/badcal/data", "/badstring/cube/data", "/nonlinear/cube/data", "/badlength/cube/data"] {
            #expect(throws: HDF5DatacubeError.self) { try HDF5Datacube(path: path, datasetPath: dataset) }
        }
        #expect(throws: HDF5DatacubeError.self) { try HDF5Datacube(path: "/no/such/file", datasetPath: "/data") }
    }
}
