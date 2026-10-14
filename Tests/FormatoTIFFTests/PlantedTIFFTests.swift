//
//  PlantedTIFFTests.swift
//  Registration step 2 §4: planted TIFFs written byte by byte by tools/step-2/make_planted.py (struct only), their values
//  stated here as literals, independent of RosettaSciIO and tifffile. Planned mutants caught here: 1 (big-endian not
//  swapped), 2 (RowsPerStrip default), 5 (rationals), 6 (the height/width cross-over), 7 (micron), 8 (IRBeam), 9 (DM
//  65009), 12 (RGB planar), 13 (tiles), 14 (beam energy).
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct PlantedTIFFTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/planted")
    private func load(_ name: String) throws -> FormatoSignal {
        try TIFFSignals(path: Self.dir.appendingPathComponent(name).path).signal(series: 0).load()
    }

    @Test func testUInt16InBothByteOrdersIsThousandRowPlusColumn() throws {
        for name in ["le-u16-3strips.tif", "be-u16-3strips.tif"] {
            let s = try load(name)
            #expect(s.data.shape == [3, 5], "\(name)")
            #expect(s.data.dataType == .uint16)
            #expect(s.data.doubles() == (0..<3).flatMap { r in (0..<5).map { c in Double(1000 * r + c) } }, "\(name)")
            #expect(s.axes.map(\.name) == ["height", "width"])
        }
    }

    @Test func testBigTIFFFloat32KeepsItsBits() throws {
        let s = try load("bigtiff-f32.tif")
        #expect(s.data.shape == [2, 3])
        let v = s.data.doubles()
        #expect(v[0].bitPattern == (-0.0).bitPattern)
        #expect(v[2] == 3.5)
        #expect(v[4] == -2.5)
        #expect(v[5] == Double(Float.greatestFiniteMagnitude))
    }

    @Test func testColourAndStacks() throws {
        let rgb = try load("rgb8.tif")
        #expect(rgb.data.dataType == .rgb8)
        #expect(rgb.data.shape == [2, 2])
        #expect(rgb.data.bytes.count == 12)
        let rgba = try load("rgba16.tif")
        #expect(rgba.data.dataType == .rgba16)
        #expect(rgba.data.bytes.count == 32)
        let stack = try load("stack-i16.tif")
        #expect(stack.data.shape == [2, 2, 3])
        #expect(stack.data.dataType == .int16)
        #expect(stack.data.doubles().contains { $0 < 0 })
        #expect(stack.axes.map(\.name) == ["image series", "height", "width"])
    }

    @Test func testImageJMicronCrossesResolutionOntoTheAxes() throws {
        let s = try load("imagej-micron-asym.tif")
        // XResolution 4/1, YResolution 2/1: height takes 1/2, width 1/4 (RosettaSciIO's cross-over).
        #expect(s.axes[s.axes.count - 2].scale == 0.5)
        #expect(s.axes[s.axes.count - 1].scale == 0.25)
        #expect(s.axes.suffix(2).allSatisfy { $0.units == "µm" })
    }

    @Test func testDMTagsCalibrateEachAxis() throws {
        let s = try load("dm-tags-stack.tif")
        let (z, h, w) = (s.axes[0], s.axes[1], s.axes[2])
        #expect((w.scale, w.offset, w.units) == (2.5, -1.5, "nm"))
        #expect((h.scale, h.offset, h.units) == (4.0, 0.25, "µm"))
        #expect((z.scale, z.offset, z.units) == (0.125, 1.0, "s"))
        #expect(s.metadata["Signal.Noise_properties.Variance_linear_model.gain_offset"]?.value == .number(3.0))
        #expect(s.metadata["Signal.Noise_properties.Variance_linear_model.gain_factor"]?.value == .number(0.5))
    }

    @Test func testFEIPixelSizeAndMapping() throws {
        let asym = try load("fei-helios-asym.tif")
        #expect(asym.axes[0].scale == 1.5e-09)   // height takes PixelWidth
        #expect(asym.axes[1].scale == 2.5e-09)
        #expect(asym.axes.allSatisfy { $0.units == "m" })
        let ir = try load("fei-irbeam.tif")
        #expect(ir.axes[0].scale == 1e-05)      // HFW / ResolutionX
        #expect(ir.axes[1].scale == 3e-05)      // VFW / ResolutionY
        let fei = try load("fei-helios.tif")
        #expect(fei.metadata["Acquisition_instrument.SEM.beam_energy"]?.value == .number(200.0))
        #expect(fei.metadata["General.date"]?.value == .text("2026-10-14"))
        #expect(fei.metadata["General.time"]?.value == .text("23:22:33"))
        #expect(fei.metadata["Acquisition_instrument.SEM.beam_energy"]?.provenance.source == "fei_metadata.Beam.HV")
    }

    @Test func testRefusalsAreNamed() {
        for (name, word) in [("lzw.tif", "compressed"), ("tiled.tif", "tiled"), ("strip-past-end.tif", "strip")] {
            let error = #expect(throws: (any Error).self, "\(name)") { _ = try TIFFSignals(path: Self.dir.appendingPathComponent(name).path) }
            #expect(error.map { "\($0)".lowercased().contains(word) } == true, "\(name): \(String(describing: error))")
        }
    }
}
