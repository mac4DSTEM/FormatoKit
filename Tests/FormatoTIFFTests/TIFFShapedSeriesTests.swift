//
//  TIFFShapedSeriesTests.swift
//  FormatoKit 0.11.0: tifffile's shaped description (`{"shape": [...]}`, what `imwrite(array)` stores) opens. The files are
//  tifffile-written (tools/shaped-tiff/pins.py, Fixtures/shaped); the truth here is stated as literals and as the bytes of the
//  pages read through the tag directories, independent of the series rule. The comparison with RosettaSciIO is
//  FormatoTIFFPinsTests.testShapedSeriesFilesAgreeWithRosettaSciIO.
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFShapedSeriesTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/shaped")
    private func open(_ name: String) throws -> TIFFSignals { try TIFFSignals(path: Self.dir.appendingPathComponent(name + ".tif").path) }

    /// The pixel bytes of the pages `range` of the file, little-endian, read from the tag directories (strips in order).
    private func pageBytes(_ name: String, _ range: Range<Int>, bytesPerSample: Int) throws -> Data {
        let file = try TIFFFile(path: Self.dir.appendingPathComponent(name + ".tif").path)
        let raw = try Data(contentsOf: Self.dir.appendingPathComponent(name + ".tif"))
        var out = Data()
        for d in file.directories[range] {
            let offsets = try #require(d[273]?.integers), counts = try #require(d[279]?.integers)
            var page = Data()
            for (o, c) in zip(offsets, counts) { page.append(raw[Int(o)..<Int(o + c)]) }
            if file.bigEndian && bytesPerSample > 1 {
                var swapped = Data(count: page.count)
                for i in stride(from: 0, to: page.count, by: bytesPerSample) {
                    for k in 0..<bytesPerSample { swapped[i + k] = page[i + bytesPerSample - 1 - k] }
                }
                page = swapped
            }
            out.append(page)
        }
        return out
    }

    @Test func testDefaultTifffileStackOpensWithAnUnnamedImageAxis() throws {
        let tiff = try open("stack_u2_be")
        #expect(tiff.series.count == 1)
        #expect(tiff.series[0].axes == "QYX" && tiff.series[0].shape == [5, 7, 9])
        let s = try tiff.signal(series: 0).load()
        #expect(s.data.dataType == .uint16 && s.data.shape == [5, 7, 9])
        #expect(s.data.bytes == (try pageBytes("stack_u2_be", 0..<5, bytesPerSample: 2)))
        let names: [String?] = s.axes.map(\.name)
        let want: [String?] = ["None", "height", "width"]
        #expect(names == want)
        #expect(s.axes.map(\.navigate) == [true, false, false])
        #expect(s.metadata["General.original_filename"]?.value.text == "stack_u2_be.tif")
    }

    @Test func testTwoDimensionalFileKeepsItsPageAxes() throws {
        let tiff = try open("2d_f4_be")
        #expect(tiff.series[0].axes == "YX" && tiff.series[0].shape == [7, 9])
        let s = try tiff.signal(series: 0).load()
        #expect(s.data.dataType == .float32)
        #expect(s.data.bytes == (try pageBytes("2d_f4_be", 0..<1, bytesPerSample: 4)))
    }

    @Test func testMultiDimensionalSeriesKeepsItsLengthOneAxes() throws {
        // A shaped series is not squeezed: (5, 1, 7, 9) stays four-dimensional.
        let t = try open("singleton_second")
        #expect(t.series[0].axes == "QQYX" && t.series[0].shape == [5, 1, 7, 9])
        #expect(try t.signal(series: 0).load().data.bytes == (try pageBytes("singleton_second", 0..<5, bytesPerSample: 2)))
        let m = try open("multi5d_u2")
        #expect(m.series[0].axes == "QQQYX" && m.series[0].shape == [2, 3, 5, 6, 8])
        let s = try m.signal(series: 0).load()
        #expect(s.data.bytes == (try pageBytes("multi5d_u2", 0..<30, bytesPerSample: 2)))
        #expect(s.axes.map(\.navigate) == [true, true, true, false, false])
    }

    @Test func testAxesFromTheDescriptionNameTheDimensions() throws {
        let t = try open("axes_tzyx_extra")
        #expect(t.series[0].axes == "TZYX" && t.series[0].shape == [2, 5, 7, 9])
        let names: [String?] = try t.signal(series: 0).load().axes.map(\.name)
        let want: [String?] = ["time", "depth", "height", "width"]
        #expect(names == want)
        // axes of the wrong length are ignored, as tifffile does: the page's own axes with an unnamed image axis.
        #expect(try open("axes_wrong_length").series[0].axes == "QYX")
    }

    @Test func testTruncatedFileHoldsOnePageAndTheDataFollowsIt() throws {
        let tiff = try open("stack_truncated")
        let file = tiff.file
        #expect(file.directories.count == 1)
        #expect(tiff.series[0].shape == [5, 7, 9] && tiff.series[0].axes == "QYX")
        let raw = try Data(contentsOf: Self.dir.appendingPathComponent("stack_truncated.tif"))
        let start = Int(try #require(file.directories[0][273]?.integers?.first))
        let s = try tiff.signal(series: 0).load()
        #expect(s.data.bytes == raw[start..<(start + 5 * 7 * 9 * 2)])
    }

    @Test func testShapeWithTrailingOnesReadsThroughTheFlatOrder() throws {
        // (5, 7, 9, 1): the last two dimensions are not a page's rows and columns.
        let tiff = try open("tail1_stack")
        #expect(tiff.series[0].axes == "QYXQ" && tiff.series[0].shape == [5, 7, 9, 1])
        let lazy = try tiff.signal(series: 0)
        let all = try lazy.load()
        #expect(all.data.bytes == (try pageBytes("tail1_stack", 0..<5, bytesPerSample: 2)))
        let names: [String?] = all.axes.map(\.name)
        let want: [String?] = ["None", "height", "width", "None"]
        #expect(names == want)
        let slab = try lazy.array.read(start: [1, 2, 3, 0], count: [3, 4, 5, 1])
        let want2 = try all.data.slab(start: [1, 2, 3, 0], count: [3, 4, 5, 1])
        #expect(slab == want2)
    }

    @Test func testRGBPagesDropTheSampleAxis() throws {
        let t = try open("rgb8_stack")
        #expect(t.series[0].axes == "QYXS" && t.series[0].shape == [2, 7, 9, 3])
        let s = try t.signal(series: 0).load()
        #expect(s.data.dataType == .rgb8 && s.data.shape == [2, 7, 9])
        #expect(s.data.bytes == (try pageBytes("rgb8_stack", 0..<2, bytesPerSample: 1)))
    }

    @Test func testAppendedSeriesAreSeparateSignals() throws {
        let t = try open("series_two")
        #expect(t.series.count == 2)
        #expect(t.series[0].axes == "QYX" && t.series[0].shape == [2, 7, 9])
        #expect(t.series[1].axes == "YX" && t.series[1].shape == [7, 9] && t.series[1].dataType == .float32)
        let second = try t.signal(series: 1).load()
        #expect(second.data.bytes == (try pageBytes("series_two", 2..<3, bytesPerSample: 4)))
        // Big-endian, three series, the second of another type.
        let b = try open("series_three_be")
        #expect(b.series.map(\.shape) == [[2, 5, 6], [5, 5, 6], [1, 5, 6]])
        #expect(try b.signal(series: 1).load().data.bytes == (try pageBytes("series_three_be", 2..<7, bytesPerSample: 1)))
    }

    @Test func testReducedImageOneStepBelowAJoinsAsALevelAndIsNoSeries() throws {
        #expect(try open("series_pyramid").series.map(\.shape) == [[16, 16]])
        #expect(try open("series_reduced_not_pyramid").series.map(\.shape) == [[16, 16], [8, 10]])
    }

    @Test func testDescriptionTifffileCannotUseFallsToTheGenericRule() throws {
        for name in ["description_not_multiple", "description_bad_json", "old_description_bad"] {
            let t = try open(name)
            #expect(t.series.count == 1 && t.series[0].axes == "IYX" && t.series[0].shape == [5, 7, 9], "\(name)")
        }
        #expect(try open("old_description").series[0].axes == "QYX")
    }

    @Test func testDescriptionTifffileRaisesOnIsRefused() throws {
        #expect(throws: (any Error).self) { _ = try open("description_shape_text") }
        #expect(throws: (any Error).self) { _ = try open("axes_unknown_code").signal(series: 0) }
        // The data lies beyond the end of the file.
        #expect(throws: (any Error).self) { _ = try open("description_bigger_than_pages") }
        // Planar RGB (PlanarConfiguration 2) stays refused.
        #expect(throws: (any Error).self) { _ = try open("planar_rgb") }
    }

    @Test func testDateAndTimeOfAShapedFileComeFromItsFirstPage() throws {
        // DateTime is read from the first page of the series.
        let t = try open("date_resolution")
        let m = try t.signal(series: 0).load().metadata
        #expect(m["General.date"]?.value.text == "2026-10-22" && m["General.time"]?.value.text == "12:34:56")
    }

    @Test func testShapeIndexingPastThePageDimensionsIsRefusedByName() throws {
        // A 1x1 page described as {"shape": [1,1,1,1,1]}: tifffile's reshape_axes raises IndexError (not swallowed); this once trapped.
        do {
            _ = try open("description_reshape_underflow")
            Issue.record("expected a refusal")
        } catch let error as FormatoReadError {
            guard case .unsupported(let why) = error else { Issue.record("wrong error \(error)"); return }
            #expect(why.contains("description_reshape_underflow.tif") && why.contains("IndexError"))
        }
    }

    @Test func testShapeOfRankZeroReadsOneValueLikeTifffile() throws {
        // {"shape": []}: tifffile's series is a 0-d array of the page's one value; this once trapped in the flat reader.
        let t = try open("description_rank0")
        #expect(t.series[0].shape == [] && t.series[0].axes == "")
        let s = try t.signal(series: 0).load()
        #expect(s.data.shape == [] && s.axes.isEmpty)
        #expect(s.data.bytes == (try pageBytes("description_rank0", 0..<1, bytesPerSample: 2)))
    }
}
