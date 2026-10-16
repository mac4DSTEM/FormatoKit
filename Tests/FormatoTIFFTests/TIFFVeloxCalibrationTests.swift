//
//  TIFFVeloxCalibrationTests.swift
//  The pixel size of a Velox TIFF (tag 34683): the default reading equals RosettaSciIO 049e7d70 (which reads no such tag,
//  so the axes stay uncalibrated unless FEI SEM tags exist), and `TIFFReadOptions.veloxCalibration` equals the consumer's
//  reader (macTEM cb6e164, compiled unchanged). Files and pins: tools/acq-metadata/generate.py.
//

import Foundation
import Testing
import FormatoCore
import FormatoTIFF

@Suite struct TIFFVeloxCalibrationTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/image-readers")
    static var pins: [[String: Any]] {
        let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as? [String: Any]
        return root?["cases"] as? [[String: Any]] ?? []
    }

    static func path(_ name: String) -> String { fixtures.appendingPathComponent(name + ".tif").path }
    static func axes(_ name: String, _ options: TIFFReadOptions) throws -> (axes: [FormatoAxis], metadata: FormatoMetadata) {
        let s = try TIFFSignals(path: path(name), options: options).signal(series: 0)
        return (s.axes, s.metadata)
    }

    @Test func testDefaultAxesEqualRosettaSciIO() throws {
        #expect(Self.pins.count == 11)
        for c in Self.pins {
            let name = c["name"] as! String
            let ref = (c["reference"] as! [String: Any])["axes"] as! [[String: Any]]
            let got = try Self.axes(name, TIFFReadOptions()).axes
            #expect(got.count == ref.count, "\(name)")
            for (g, r) in zip(got, ref) {
                #expect(g.name == r["name"] as? String && g.units == r["units"] as? String && g.navigate == r["navigate"] as? Bool, "\(name)")
                #expect(g.scale == (r["scale"] as! NSNumber).doubleValue && g.offset == (r["offset"] as! NSNumber).doubleValue, "\(name)")
            }
        }
    }

    @Test func testTheOptionEqualsTheConsumersCalibration() throws {
        let options = TIFFReadOptions(veloxCalibration: true)
        for c in Self.pins {
            let name = c["name"] as! String
            let app = c["app"] as! [String: Any]
            let (axes, metadata) = try Self.axes(name, options)
            let width = try #require(axes.first { $0.name == "width" }), height = try #require(axes.first { $0.name == "height" })
            for (axis, pin) in [(width, app["x"]), (height, app["y"])] {
                if let p = pin as? [String: Any] {
                    #expect(axis.scale == (p["scale"] as! NSNumber).doubleValue && axis.units == p["units"] as? String, "\(name)")
                    #expect(axis.offset == 0 && (p["origin"] as! NSNumber).doubleValue == 0, "\(name)")
                } else {
                    #expect(axis.scale == 1 && axis.units == "", "\(name) uncalibrated axis")
                }
            }
            let notes = app["notes"] as! [String]
            #expect(metadata["FormatoKit.policy.velox_calibration"]?.value.text == notes.first, "\(name)")
        }
    }

    @Test func testNamedCases() throws {
        let options = TIFFReadOptions(veloxCalibration: true)
        // Disagreement between the XML and the resolution tags: uncalibrated, with the reason.
        let disagree = try Self.axes("velox-disagree", options)
        #expect(disagree.axes.allSatisfy { $0.units == "" })
        #expect(disagree.metadata["FormatoKit.policy.velox_calibration"]?.value.text == TIFFVeloxCalibration.disagreeNote)
        // Velox's float32-rounded pixels per centimetre still agree.
        #expect(try Self.axes("velox-float32-rounded", options).axes.first?.units == "m")
        // FEI SEM tags come first; a plain file and an XML without a pixel size are untouched.
        for name in ["velox-and-fei", "plain", "velox-no-pixel-size", "velox-refused-xml"] {
            #expect(try Self.axes(name, options).axes == Self.axes(name, TIFFReadOptions()).axes, "\(name)")
        }
        // The page-level reader.
        let file = try TIFFFile(path: Self.path("velox-nm"))
        #expect(TIFFVeloxCalibration.read(file.directories[0]) == .calibrated(xScale: 0.25, xUnit: "nm", yScale: 0.5, yUnit: "nm"))
        #expect(TIFFVeloxCalibration.read(try TIFFFile(path: Self.path("plain")).directories[0]) == nil)
    }
}
