//
//  DMSignalsPlantedTests.swift
//  Registration §4, planted truth independent of RosettaSciIO: SpectroKit's generator (tools/eels-reader/make_planted.py,
//  its fixture copied byte for byte) writes x origin 1.5, scale 2.5 nm; y origin 0, scale 3.5 nm; energy origin -40, scale
//  0.25 eV on every 3 x 2 x 5 cube, so offset = -origin * scale is -3.75, -0.0 and 10 by closed form, and the array shape is
//  [5, 2, 3]. Mutations: the minus sign dropped (1), the axes not reversed (2), int16 read as uint16 (7) - red.
//

import XCTest
import FormatoCore
import FormatoDM

final class DMSignalsPlantedTests: XCTestCase {
    private static let planted = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/eels-planted.dm4").path

    func testPlantedCubeAxesAreTheClosedForm() throws {
        let dm = try DMFile(path: Self.planted)
        let s = try dm.signal(index: 2).load()
        XCTAssertEqual(s.data.shape, [5, 2, 3])
        XCTAssertEqual(s.data.dataType, .float32)
        XCTAssertEqual(s.axes.map(\.units), ["eV", "nm", "nm"])
        XCTAssertEqual(s.axes.map(\.scale), [0.25, 3.5, 2.5])
        XCTAssertEqual(s.axes[0].offset, 10)
        XCTAssertEqual(s.axes[1].offset.bitPattern, (-0.0).bitPattern, "origin 0: -(0 * 3.5) is -0.0")
        XCTAssertEqual(s.axes[2].offset, -3.75)
        XCTAssertEqual(s.axes.map(\.name), ["Energy loss", "y", "x"])
        XCTAssertEqual(s.signalType, "EELS")
        XCTAssertEqual(s.metadata["General.title"]?.provenance.source, "ImageList.2.Name")
    }

    /// The int16 cube holds negative counts the generator wrote: read as stored, they stay negative.
    func testInt16CubeKeepsItsSign() throws {
        let dm = try DMFile(path: Self.planted)
        let s = try dm.signal(index: 3).load()
        XCTAssertEqual(s.data.dataType, .int16)
        let moved = try DM4Experiment.readEELSSpectrumImage(path: Self.planted, index: 3)
        // The moved reader returns (y, x, channel) as Float32; the signal is (channel, y, x) as stored.
        let v = s.data.doubles()
        for y in 0..<2 { for x in 0..<3 { for c in 0..<5 {
            XCTAssertEqual(v[(c * 2 + y) * 3 + x], Double(moved.counts[(y * 3 + x) * 5 + c]), "\(y) \(x) \(c)")
        } } }
    }

    func testRefusedTypesAndMissingObjectsAreNamed() throws {
        let dm = try DMFile(path: Self.planted)
        XCTAssertThrowsError(try dm.signal(index: 99)) { XCTAssertTrue("\($0)".contains("no image object 99")) }
        XCTAssertNil(DMFile.dataType(code: 23)); XCTAssertNil(DMFile.dataType(code: 13)); XCTAssertNil(DMFile.dataType(code: 14))
    }
}
