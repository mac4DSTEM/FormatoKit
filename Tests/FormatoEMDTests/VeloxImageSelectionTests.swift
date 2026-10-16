//
//  VeloxImageSelectionTests.swift
//  The consumer's object rule and axes for a Velox file (VeloxImageSelection) against its reader (macTEM cb6e164
//  VeloxImageReader.swift, compiled unchanged), on a file written by tools/acq-metadata/generate.py; and the axes against
//  VeloxImageSignals (RosettaSciIO 049e7d70) where they differ.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD

extension VeloxEMDSerialized {
    @Suite struct VeloxImageSelectionTests {
        static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/image-readers")
        static var path: String { fixtures.appendingPathComponent("velox-objects.emd").path }
        static var pins: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("pins.json"))) as? [String: Any]) ?? [:]
        }

        @Test func testObjectRuleEqualsTheConsumersOnEverySubset() throws {
            let all = try VeloxEMDReader(path: Self.path).images()
            let cases = Self.pins["cases"] as! [[String: Any]]
            #expect(cases.count == 5 && all.count == 7)
            for c in cases {
                let ids = c["ids"] as! [String]
                let subset = all.filter { ids.contains($0.id) }
                let app = c["app"] as! [String: Any]
                #expect(VeloxImageSelection.choose(subset)?.id == app["chosen"] as? String, "\(c["name"]!)")
                #expect(subset.filter(VeloxImageSelection.isCandidate).map(\.id) == app["candidates"] as? [String], "\(c["name"]!)")
            }
        }

        @Test func testAxesEqualTheConsumers() throws {
            let all = try VeloxEMDReader(path: Self.path).images()
            let app = ((Self.pins["cases"] as! [[String: Any]]).first { $0["name"] as? String == "all" }!["app"] as! [String: Any])["axes"] as! [String: [String: Any]]
            for e in all {
                let pin = try #require(app[e.id])
                let got = VeloxImageSelection.axes(of: e)
                for (axis, p) in [(got.x, pin["x"]), (got.y, pin["y"])] {
                    if let p = p as? [String: Any] {
                        #expect(axis == VeloxImageSelection.Axis(origin: (p["origin"] as! NSNumber).doubleValue,
                                                                 scale: (p["scale"] as! NSNumber).doubleValue, units: p["units"] as! String), "\(e.id)")
                    } else { #expect(axis == nil, "\(e.id)") }
                }
                #expect(e.metadata.accelerationVoltageVolts == (pin["voltage"] as? NSNumber)?.doubleValue)
            }
            // Offsets and a y unit of its own (the entry 'f-offsets-units'): origin = -offset / size, y in PixelUnitY.
            let f = VeloxImageSelection.axes(of: try #require(all.first { $0.id == "f-offsets-units" }))
            #expect(f.x == VeloxImageSelection.Axis(origin: -5, scale: 2e-10, units: "m"))
            #expect(f.y?.units == "nm")
            #expect(VeloxImageSelection.axes(of: try #require(all.first { $0.id == "g-zero-size" })).x == nil)
        }

        @Test func testResolvedDetectorFollowsTheImagesOwnName() throws {
            let all = try VeloxEMDReader(path: Self.path).images()
            let mismatch = try #require(all.first { $0.id == "d-ceta-index-mismatch" })
            #expect(mismatch.resolvedDetector?.name == "BM-Ceta" && mismatch.detectorType == "ImagingDetector")
            #expect(all.first { $0.id == "e-no-index" }?.resolvedDetector == nil)
        }
    }
}
