//
//  TIFFCraftedHeaderTests.swift
//  Crafted header values in a TIFF are refused, never an overflow trap (macEMSuite/FormatoKit#103).
//  Red before: an FEI date of digits longer than Int trapped on `Int(...)!`; an ImageJ description whose plane counts multiply
//  past Int trapped on `*`.
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFCraftedHeaderTests {

    @Test func anFEIDateOfDigitsLongerThanIntIsNoDate() {
        #expect(TIFFSignals.feiDate("99999999999999999999/01/2026") == nil)
        #expect(TIFFSignals.feiDate("2026-99999999999999999999-01") == nil)
        #expect(TIFFSignals.feiDate("10/14/2026") == "2026-10-14")
    }

    /// A little-endian, one-directory, 1 x 1 uint8 TIFF whose ImageDescription is `description`.
    private func tiff(description: String) -> Data {
        var text = Array(description.utf8) + [0]
        if text.count % 2 == 1 { text.append(0) }
        let entries: [(UInt16, UInt16, UInt32, UInt32)] = [
            (256, 3, 1, 1), (257, 3, 1, 1), (258, 3, 1, 8), (259, 3, 1, 1), (262, 3, 1, 1),
            (270, 2, UInt32(text.count - 1), 0),   // offset patched below
            (273, 4, 1, 0), (277, 3, 1, 1), (278, 3, 1, 1), (279, 4, 1, 1),
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        let textOffset = UInt32(8 + ifdSize), pixelOffset = textOffset + UInt32(text.count)
        var b: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        func u16(_ v: UInt16) { b += [UInt8(v & 0xff), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { b += (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        u16(UInt16(entries.count))
        for (tag, type, count, value) in entries {
            u16(tag); u16(type); u32(count)
            u32(tag == 270 ? textOffset : tag == 273 ? pixelOffset : value)
        }
        u32(0)
        b += text
        b += [7]
        return Data(b)
    }

    @Test func imageJPlaneCountsThatMultiplyPastIntAreAStackNotATrap() throws {
        let crafted = tiff(description: "ImageJ=1.53t\nimages=4294967296\nslices=4294967296\nframes=4294967296\n")
        #expect(throws: TIFFAppImage.Refusal.multiPage) { try TIFFAppImage.read(data: crafted, fileName: "crafted.tif") }
        let plain = tiff(description: "ImageJ=1.53t\n")
        let image = try TIFFAppImage.read(data: plain, fileName: "plain.tif")
        #expect(image.width == 1 && image.height == 1)
    }
}
