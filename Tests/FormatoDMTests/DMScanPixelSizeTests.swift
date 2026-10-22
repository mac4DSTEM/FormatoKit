//
//  DMScanPixelSizeTests.swift
//  FormatoKit 0.11.0: the scan pixel size of a DM spectrum image (`DM4EELSSpectrumImage.xAxis/yAxis`,
//  `DM4EDSSpectrumImage.xAxis/yAxis`) and of a 4D scan (`DM4Datacube`'s navigation axes), against RosettaSciIO 049e7d70's axes of
//  the same fixtures (tools/dm-scan/pins.py into dm-scan-pins.json): scale and offset to the bit, units as written.
//  Public API only.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM

@Suite struct DMScanPixelSizeTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private struct PinnedAxis: Decodable {
        let name: String?, size: Int, scale: Double, offset: Double, units: String?, navigate: Bool
        let scaleBits: String, offsetBits: String
    }
    private struct PinnedSignal: Decodable { let title: String; let shape: [Int]; let axes: [PinnedAxis] }
    private struct PinnedFile: Decodable { let file: String; let signals: [PinnedSignal]; let raises: String? }
    private struct Pins: Decodable { let files: [PinnedFile] }

    private func pins() throws -> [PinnedFile] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Pins.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("dm-scan-pins.json"))).files
    }
    private func bits(_ x: Double) -> String { String(format: "%016llx", x.bitPattern) }

    /// The axis as the file states it, against RosettaSciIO's: scale and offset (-origin * scale) to the bit, units as written.
    private func expectSame(_ mine: DM4Axis?, _ theirs: PinnedAxis, _ what: String) throws {
        let axis = try #require(mine, "\(what): no axis")
        #expect(bits(axis.scale) == theirs.scaleBits, "\(what): scale \(axis.scale) vs \(theirs.scale)")
        #expect(bits(-axis.origin * axis.scale) == theirs.offsetBits, "\(what): offset")
        #expect(axis.units == (theirs.units ?? ""), "\(what): units")
    }

    @Test func testSpectrumImagesCarryTheirScanPixelSizeAsRosettaSciIOReadsIt() throws {
        var checked = 0
        for file in try pins() where file.raises == nil {
            let path = Self.fixtures.appendingPathComponent(file.file).path
            let objects = try DMFile(path: path).objects
            guard objects.count == file.signals.count else { continue }
            for (object, signal) in zip(objects, file.signals) {
                let what = "\(file.file) object \(object.index)"
                switch object.role {
                case .eels:
                    guard let r = try? DM4Experiment.readEELSSpectrumImage(path: path, index: object.index) else { continue }
                    #expect(signal.axes.count == 3, "\(what)")
                    try expectSame(r.yAxis, signal.axes[1], what + " y")
                    try expectSame(r.xAxis, signal.axes[2], what + " x")
                    #expect(r.xAxis == r.object.axes[0] && r.yAxis == r.object.axes[1], "\(what): the object's own calibrations")
                    checked += 1
                case .eds:
                    guard let r = try? DM4Experiment.readEDSSpectrumImage(path: path, index: object.index) else { continue }
                    #expect(signal.axes.count == 3, "\(what)")
                    try expectSame(r.yAxis, signal.axes[1], what + " y")
                    try expectSame(r.xAxis, signal.axes[2], what + " x")
                    checked += 1
                default: break
                }
            }
        }
        #expect(checked >= 4, "spectrum images checked: \(checked)")
    }

    @Test func testFourDimensionalScansCarryTheirScanAxes() throws {
        var checked = 0
        for file in try pins() where file.raises == nil && file.file.hasPrefix("gather/") {
            let path = Self.fixtures.appendingPathComponent(file.file).path
            let cube = try DM4Datacube(path: path)
            let signal = try #require(file.signals.first { $0.shape.count == 4 })
            // The navigation axes of the stored reference order are the first two: RosettaSciIO's scan axes.
            for k in 0..<2 {
                let axis = cube.signal.axes[k]
                #expect(bits(axis.scale) == signal.axes[k].scaleBits, "\(file.file) scan axis \(k) scale")
                #expect(bits(axis.offset) == signal.axes[k].offsetBits, "\(file.file) scan axis \(k) offset")
                #expect(axis.units == (signal.axes[k].units ?? ""), "\(file.file) scan axis \(k) units")
                #expect(axis.navigate)
            }
            checked += 1
        }
        #expect(checked >= 3)
    }
}
