//
//  TIFFSeriesRefusalTests.swift
//  A multi-page TIFF whose pages the reader cannot make into one series is refused by name: the typed
//  `TIFFError.unsupportedSeries` carries the file's name and the kind of series. Files built byte by byte here.
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFSeriesRefusalTests {
    /// One uint8 page: its width, height, and NewSubfileType (nil: no tag).
    private struct Page { let width: Int; let height: Int; var subfile: Int? = nil; var description: String? = nil }

    /// A little-endian classic TIFF, one IFD per page, each page one strip of `width x height` bytes (values 0, 1, 2, ...).
    private func build(_ pages: [Page]) -> Data {
        var d = Data([0x49, 0x49, 42, 0, 0, 0, 0, 0])
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func put32(_ v: Int, at i: Int) { for k in 0..<4 { d[i + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        var linkAt = 4
        for page in pages {
            // Pixels, then the description text, then the IFD (word aligned).
            let pixelsAt = d.count
            d.append(contentsOf: (0..<(page.width * page.height)).map { UInt8($0 & 0xFF) })
            var textAt = 0, text: [UInt8] = []
            if let s = page.description { text = Array(s.utf8) + [0]; textAt = d.count; d.append(contentsOf: text) }
            if d.count % 2 == 1 { d.append(0) }
            put32(d.count, at: linkAt)
            enum Entry { case short(Int, Int), long(Int, Int), ascii(Int) }
            var entries: [Entry] = []
            if let s = page.subfile { entries.append(.long(254, s)) }
            entries += [.short(256, page.width), .short(257, page.height), .short(258, 8), .short(259, 1), .short(262, 1)]
            if page.description != nil { entries.append(.ascii(270)) }
            entries += [.long(273, pixelsAt), .short(277, 1), .short(278, page.height), .long(279, page.width * page.height)]
            u16(entries.count)
            for e in entries {
                switch e {
                case .short(let c, let v): u16(c); u16(3); u32(1); u16(v); u16(0)
                case .long(let c, let v): u16(c); u16(4); u32(1); u32(v)
                case .ascii(let c): u16(c); u16(2); u32(text.count); u32(textAt)
                }
            }
            linkAt = d.count
            u32(0)
        }
        return d
    }

    private func refusal(_ pages: [Page], _ name: String) throws -> TIFFError? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).tif")
        try build(pages).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try TIFFSignals(path: url.path); return nil } catch let e as TIFFError { return e } catch {
            Issue.record("\(name): \(error) is not a TIFFError"); return nil
        }
    }

    @Test func testAStackOfOneShapeStillReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID().uuidString).tif")
        try build([Page(width: 4, height: 3), Page(width: 4, height: 3)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tiff = try TIFFSignals(path: url.path)
        #expect(tiff.series.map(\.shape) == [[2, 3, 4]])
    }

    @Test func testPagesOfTwoShapesAreRefusedByName() throws {
        let error = try refusal([Page(width: 4, height: 3), Page(width: 2, height: 2), Page(width: 4, height: 3)], "two-shapes")
        guard case .unsupportedSeries(let file, let series)? = error else { Issue.record("\(String(describing: error))"); return }
        #expect(file.hasPrefix("two-shapes-"))
        #expect(series == "2 series of pages that differ in shape, type or layout")
        #expect(error?.errorDescription == "\(file) holds 2 series of pages that differ in shape, type or layout, which this reader does not read.")
    }

    @Test func testAPyramidIsRefusedByName() throws {
        let error = try refusal([Page(width: 8, height: 6), Page(width: 4, height: 3, subfile: 1)], "pyramid")
        guard case .unsupportedSeries(let file, let series)? = error else { Issue.record("\(String(describing: error))"); return }
        #expect(file.hasPrefix("pyramid-"))
        #expect(series == "a pyramid of reduced-resolution pages")
    }

    /// tifffile's generic rule pyramidizes without asking for the reduced bit: a page one sampling step smaller is a level.
    @Test func testAPageHalfTheSizeWithoutTheReducedBitIsAPyramid() throws {
        let error = try refusal([Page(width: 8, height: 6), Page(width: 4, height: 3)], "half")
        guard case .unsupportedSeries(_, let series)? = error else { Issue.record("\(String(describing: error))"); return }
        #expect(series == "a pyramid of reduced-resolution pages")
    }

    @Test func testAnOMETIFFIsRefusedByName() throws {
        let ome = "<?xml version=\"1.0\"?><OME xmlns=\"http://www.openmicroscopy.org/Schemas/OME/2016-06\"></OME>"
        let error = try refusal([Page(width: 4, height: 3, description: ome), Page(width: 4, height: 3)], "ome")
        guard case .unsupportedSeries(let file, let series)? = error else { Issue.record("\(String(describing: error))"); return }
        #expect(file.hasPrefix("ome-"))
        #expect(series == "an OME-TIFF series")
    }
}
