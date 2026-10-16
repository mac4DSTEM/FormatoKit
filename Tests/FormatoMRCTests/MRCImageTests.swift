//
//  MRCImageTests.swift
//  MRCReader against RosettaSciIO 049e7d70 `mrc` (data bytes, dtype, shape, axes bit for bit) and MRCAppImage against the
//  consumer's reader (macTEM cb6e164 MRCImageReader.swift, compiled unchanged), on files written byte by byte by
//  tools/acq-metadata/generate.py.
//

import Foundation
import Testing
import FormatoCore
import FormatoMRC

@Suite struct MRCImageTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/image-readers")
    static var pins: [[String: Any]] {
        let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as? [String: Any]
        return root?["cases"] as? [[String: Any]] ?? []
    }
    static func path(_ name: String) -> String { fixtures.appendingPathComponent(name + ".mrc").path }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    @Test func testReaderEqualsRosettaSciIO() throws {
        #expect(Self.pins.count == 17)
        for c in Self.pins {
            let name = c["name"] as! String
            let ref = c["reference"] as! [String: Any]
            if ref["error"] != nil {
                #expect(throws: (any Error).self, "\(name): RosettaSciIO raises") { try MRCReader(path: Self.path(name)) }
                continue
            }
            let dtype = ref["dtype"] as! String
            if dtype == "complex64" || dtype == "float16" {
                // Read by RosettaSciIO; FormatoDataType has neither: refused by name, never converted.
                #expect(throws: FormatoReadError.self, "\(name)") { try MRCReader(path: Self.path(name)) }
                continue
            }
            let signal = try MRCReader(path: Self.path(name)).signal.load()
            #expect(signal.data.dataType.rawValue == dtype, "\(name)")
            #expect(signal.data.shape == (ref["shape"] as! [Int]), "\(name)")
            #expect(Self.hex(signal.data.bytes) == ref["data_hex"] as? String, "\(name)")
            let axes = ref["axes"] as! [[String: Any]]
            #expect(signal.axes.count == axes.count, "\(name)")
            for (g, r) in zip(signal.axes, axes) {
                #expect(g.name == r["name"] as? String && g.size == r["size"] as? Int && g.units == r["units"] as? String
                        && g.navigate == r["navigate"] as? Bool, "\(name)")
                #expect(g.scale.bitPattern == (r["scale"] as! NSNumber).doubleValue.bitPattern
                        && g.offset.bitPattern == (r["offset"] as! NSNumber).doubleValue.bitPattern, "\(name) axis \(g.name ?? "")")
            }
        }
    }

    @Test func testSlabsAreLazy() throws {
        let signal = try MRCReader(path: Self.path("f32-3x2")).signal
        let slab = try signal.array.read(start: [1, 1], count: [1, 2])
        #expect(slab.doubles() == [5, 6])
        #expect(signal.metadata["General.original_filename"]?.value.text == "f32-3x2.mrc")
    }

    @Test func testAppImageEqualsTheConsumersReader() throws {
        for c in Self.pins {
            let name = c["name"] as! String
            let app = c["app"] as! [String: Any]
            if let expected = app["error"] as? String {
                do {
                    _ = try MRCAppImage.read(path: Self.path(name))
                    Issue.record("\(name): expected \(expected)")
                } catch { #expect("\(error)" == expected, "\(name)") }
                continue
            }
            let image = try MRCAppImage.read(path: Self.path(name))
            #expect(image.width == app["width"] as? Int && image.height == app["height"] as? Int, "\(name)")
            #expect(image.pixels.map(Double.init) == (app["pixels"] as! [NSNumber]).map(\.doubleValue), "\(name)")
            #expect(image.notes == app["notes"] as? [String], "\(name)")
            #expect(image.source == app["source"] as? String, "\(name)")
            for (axis, pin) in [(image.x, app["x"]), (image.y, app["y"])] {
                if let p = pin as? [String: Any] {
                    #expect(axis == MRCAppImage.Axis(origin: (p["origin"] as! NSNumber).doubleValue,
                                                     scale: (p["scale"] as! NSNumber).doubleValue, units: p["units"] as! String), "\(name)")
                } else { #expect(axis == nil, "\(name)") }
            }
        }
    }

    @Test func testNamedDifferences() throws {
        // Mode 0: unsigned for RosettaSciIO, signed for the consumer.
        #expect(try MRCReader(path: Self.path("int8-signed")).signal.load().data.doubles() == [0, 127, 128, 255])
        #expect(try MRCAppImage.read(path: Self.path("int8-signed")).pixels == [0, 127, -128, -1])
        // A stack is read by RosettaSciIO and refused by the consumer, unless asked.
        #expect(try MRCReader(path: Self.path("stack-3")).signal.array.shape == [3, 2, 2])
        #expect(throws: MRCError.stack(frames: 3)) { try MRCAppImage.read(path: Self.path("stack-3")) }
        // The machine stamp: honoured by the consumer, ignored by RosettaSciIO.
        #expect(try MRCAppImage.read(path: Self.path("big-endian")).pixels == [1, 2, 3, 4])
        // An FEI header: RosettaSciIO takes the pixel size from it (nm); the consumer opens uncalibrated.
        #expect(try MRCReader(path: Self.path("fei-128")).signal.axes.last?.scale == Double(Float(2.5e-10) * Float(1e9)))
        #expect(try MRCAppImage.read(path: Self.path("fei-128")).notes == [MRCAppImage.Note.feiHeader])
        #expect(throws: FormatoReadError.self) { try MRCReader(path: "/nonexistent/none.mrc") }
    }
}
