//
//  TIFFVendorAxesTests.swift
//  `TIFFVendorBranches.readWithVendorAxes`: the pixel size RosettaSciIO 049e7d70 reads for Zeiss SEM, TVIPS and JEOL
//  SightX TIFFs. RosettaSciIO's public test files (unpacked by tools/test.sh, skipped when absent) are compared with the
//  axes pinned in step-2-pins.json, bit for bit; planted files built byte by byte here cover each branch where the public
//  files are absent.
//

import Foundation
import Testing
import FormatoCore
import FormatoKitTestSupport
@testable import FormatoTIFF

@Suite struct TIFFVendorAxesTests {
    private let option = TIFFReadOptions(vendorBranches: .readWithVendorAxes)
    private let flagKey = "FormatoKit.policy.vendor_branch"

    // MARK: Planted files

    private enum Extra {
        case short(Int, Int)
        case ascii(Int, String)
        case undefined(Int, [UInt8])
        case rational(Int, UInt32, UInt32)
        /// A LONG of count 1 whose value is the offset of `bytes`, as TVIPS cameras write tag 37706.
        case pointer(Int, [UInt8])
    }

    /// A 3 x 4 uint8 little-endian TIFF, values 10 r + c in one strip, plus `extra` tags (their data after the pixels).
    private func build(_ extra: [Extra]) -> Data {
        enum Entry { case short(Int, Int), long(Int, Int), blob(Int, Int, Int, [UInt8]) }   // blob: code, type, count, bytes
        var entries: [Entry] = [.short(256, 4), .short(257, 3), .short(258, 8), .short(259, 1), .short(262, 1),
                                .long(273, 0), .short(277, 1), .long(279, 12)]
        for e in extra {
            switch e {
            case .short(let c, let v): entries.append(.short(c, v))
            case .ascii(let c, let s): let b = Array(s.utf8) + [0]; entries.append(.blob(c, 2, b.count, b))
            case .undefined(let c, let b): entries.append(.blob(c, 7, b.count, b))
            case .rational(let c, let n, let d):
                let b = [n, d].flatMap { v in (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
                entries.append(.blob(c, 5, 1, b))
            case .pointer(let c, let b): entries.append(.blob(c, 4, 1, b))
            }
        }
        func code(_ e: Entry) -> Int { switch e { case .short(let c, _), .long(let c, _), .blob(let c, _, _, _): return c } }
        entries.sort { code($0) < code($1) }
        let pixelsAt = 8 + 2 + entries.count * 12 + 4
        var blobs = Data()
        var d = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        u16(entries.count)
        for e in entries {
            switch e {
            case .short(let c, let v): u16(c); u16(3); u32(1); u16(v); u16(0)
            case .long(let c, let v): u16(c); u16(4); u32(1); u32(c == 273 ? pixelsAt : v)
            case .blob(let c, let type, let count, let bytes):
                u16(c); u16(type); u32(count)
                if bytes.count <= 4 && type != 4 { d.append(contentsOf: bytes + [UInt8](repeating: 0, count: 4 - bytes.count)) }
                else {
                    if blobs.count % 2 == 1 { blobs.append(0) }
                    u32(pixelsAt + 12 + blobs.count); blobs.append(contentsOf: bytes)
                }
            }
        }
        u32(0)
        d.append(contentsOf: (0..<3).flatMap { (r: Int) -> [UInt8] in (0..<4).map { (c: Int) -> UInt8 in UInt8(10 * r + c) } })
        d.append(blobs)
        return d
    }

    private func read(_ extra: [Extra], options: TIFFReadOptions? = nil) throws -> FormatoSignal {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("formato-vendor-\(UUID().uuidString).tif")
        try build(extra).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try TIFFSignals(path: url.path, options: options ?? option).signal(series: 0).load()
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    /// A TVIPS v1 record and, for version 2, a v2 record with the magic number (or not) and the pixel sizes.
    private func tvips(version: Int32, magic: UInt32 = 0xAAAA_AAAA, x: Float = 0, y: Float = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 244)
        b.replaceSubrange(0..<4, with: le32(UInt32(bitPattern: version)))
        guard version == 2 else { return b }
        var v2 = [UInt8](repeating: 0, count: 6068)
        v2.replaceSubrange(2724..<2728, with: le32(x.bitPattern))
        v2.replaceSubrange(2728..<2732, with: le32(y.bitPattern))
        v2.replaceSubrange(6064..<6068, with: le32(magic))
        return b + v2
    }

    @Test func testTheDefaultStillRefusesAndGenericStaysUncalibrated() throws {
        let extra: [Extra] = [.undefined(37706, tvips(version: 2, x: 1.5, y: 2.5))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("formato-vendor-\(UUID().uuidString).tif")
        try build(extra).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { _ = try TIFFSignals(path: url.path) }
        let generic = try read(extra, options: TIFFReadOptions(vendorBranches: .readAsGeneric))
        #expect(generic.axes.map(\.scale) == [1, 1])
    }

    @Test func testTVIPSVersionTwoGivesItsPixelSizeInNanometres() throws {
        let s = try read([.undefined(37706, tvips(version: 2, x: 1.5, y: 2.25))])
        // `_order_axes_by_name`: "height" takes x, "width" takes y.
        #expect(s.axes.map(\.name) == ["height", "width"])
        #expect(s.axes.map(\.scale) == [1.5, 2.25])
        #expect(s.axes.map(\.units) == ["nm", "nm"])
        #expect(s.data.doubles() == [0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22, 23])
        let flag = try #require(s.metadata[flagKey])
        #expect(flag.value == .text("TVIPS"))
        #expect(flag.provenance.rule.contains("axes are read, its metadata mapping is not ported"))
    }

    @Test func testTVIPSAsALongPointerIsReadAtItsOffset() throws {
        let s = try read([.pointer(37706, tvips(version: 2, x: 0.75, y: 0.5))])
        #expect(s.axes.map(\.scale) == [0.75, 0.5])
        #expect(s.axes.map(\.units) == ["nm", "nm"])
    }

    @Test func testTVIPSWithoutAVersionTwoRecordUsesTheResolutionTags() throws {
        // XResolution 4/1, YResolution 5/2: x = 2/5 * 1e-2, y = 1/4 * 1e-2, in metres.
        let res: [Extra] = [.rational(282, 4, 1), .rational(283, 5, 2)]
        for record in [tvips(version: 1), tvips(version: 2, magic: 0, x: 9, y: 9)] {
            let s = try read([.undefined(37706, record)] + res)
            #expect(s.axes.map(\.scale) == [2.0 / 5.0 * 1e-2, 1.0 / 4.0 * 1e-2])
            #expect(s.axes.map(\.units) == ["m", "m"])
        }
        // A record cut short by the end of the file: tifffile keeps the raw LONG, which holds no PixelSizeX.
        let cut = try read(res + [.pointer(37706, [2, 0, 0, 0])])
        #expect(cut.axes.map(\.scale) == [2.0 / 5.0 * 1e-2, 1.0 / 4.0 * 1e-2])
        #expect(cut.axes.map(\.units) == ["m", "m"])
        // No resolution tags: RosettaSciIO raises inside the branch and keeps the default axes.
        let bare = try read([.undefined(37706, tvips(version: 1))])
        #expect(bare.axes.map(\.scale) == [1, 1])
        #expect(bare.axes.map(\.units) == ["", ""])
    }

    @Test func testZeissSEMScalesTheFourthUnnamedValueByThePageWidth() throws {
        let text = "0\r\n0\r\n0\r\n2.614514e-006\r\n1.045845e+002\r\nAP_MAG\r\nMag = 1.00 K X\r\n7\r\n"
        let s = try read([.ascii(34118, text)])
        let want = 2.614514e-006 * 1024 / 4
        #expect(s.axes.map(\.scale) == [want, want])
        #expect(s.axes.map(\.units) == ["m", "m"])
        // Fewer than four unnamed values: an IndexError in RosettaSciIO, the default axes here.
        let short = try read([.ascii(34118, "0\r\n0\r\nAP_MAG\r\nMag = 1.00 K X\r\n")])
        #expect(short.axes.map(\.scale) == [1, 1])
    }

    @Test func testTheCZSEMParserFollowsTifffile() {
        let raw = Data("1\nAP_X\nno separator\nX = 3 mm\n2\n 3 \nfoo\nBAR\n".utf8)
        // "no separator" is skipped with the key kept; "X = 3 mm" ends it; "foo" stays text.
        #expect(TIFFSignals.czSEMUnnamed(raw) == [.int(1), .int(2), .int(3), .string("foo")])
        #expect(TIFFSignals.pythonIsUpper("AP_X1") && !TIFFSignals.pythonIsUpper("123") && !TIFFSignals.pythonIsUpper("Ab"))
    }

    private func jeol(mode: String, value: String, unit: String = "mm", eos: String = "eosTEM") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <TemReporter>
          <Eos><EosMode>\(eos)</EosMode></Eos>
          <ElectronGun><AccelerationVoltage>200000</AccelerationVoltage></ElectronGun>
          <IlluminationSystem><ImageField>imgBright</ImageField></IlluminationSystem>
          <ImageFormingSystem>
            <ImageFormingMode>imgSA</ImageFormingMode>
            <ScanningImageFormingMode>imgBF</ScanningImageFormingMode>
            <SelectorString>x4000</SelectorString>
            <ModeString>\(mode)</ModeString>
            <SelectorValue>\(value)</SelectorValue>
            <SelectorUnitString>\(unit)</SelectorUnitString>
          </ImageFormingSystem>
        </TemReporter>
        """
    }

    @Test func testJEOLSightXMagnificationAndDiffraction() throws {
        let tags: [Extra] = [.short(296, 3), .rational(282, 400, 1), .rational(283, 500, 1), .ascii(271, "JEOL Ltd.")]
        let mag = try read(tags + [.ascii(270, jeol(mode: "MAG", value: "4000"))])
        let factor = 0.01 / 4000.0 * 1e9
        #expect(mag.axes.map(\.scale) == [1.0 / 500.0 * factor, 1.0 / 400.0 * factor])
        #expect(mag.axes.map(\.units) == ["nm", "nm"])
        let diff = try read(tags + [.ascii(270, jeol(mode: "DIFF", value: "250", unit: "mm"))])
        let scale = 0.01 / (0.25 * TIFFSignals.jeolWavelength(200000) * 1e9)
        #expect(diff.axes.map(\.scale) == [1.0 / 500.0 * scale, 1.0 / 400.0 * scale])
        #expect(diff.axes.map(\.units) == ["1 / nm", "1 / nm"])
        // A camera length of 0: NumPy divides to inf rather than raising, and the scales stay infinite.
        let zero = try read(tags + [.ascii(270, jeol(mode: "DIFF", value: "0"))])
        #expect(zero.axes.map(\.scale) == [Double.infinity, Double.infinity])
        // A quoted value is evaluated twice by XmlToDict: '4000' is the number 4000. True is no text for [4:].
        let quoted = try read(tags + [.ascii(270, jeol(mode: "MAG", value: "'4000'"))])
        #expect(quoted.axes.map(\.scale) == mag.axes.map(\.scale))
        #expect(XMLNode.literal("True") == .int(1) && XMLNode.literal("0x10") == .int(16) && XMLNode.literal("[1]") == .dictionary)
        // STEM: no calibration, the default axes.
        let stem = try read(tags + [.ascii(270, jeol(mode: "MAG", value: "4000", eos: "modeASID"))])
        #expect(stem.axes.map(\.scale) == [1, 1])
        // Inches: 0.0254 m per unit.
        let inch = try read([.short(296, 2), .rational(282, 400, 1), .rational(283, 500, 1), .ascii(271, "JEOL Ltd."),
                             .ascii(270, jeol(mode: "MAG", value: "4000"))])
        #expect(inch.axes[0].scale == 1.0 / 500.0 * (0.0254 / 4000.0 * 1e9))
    }

    @Test func testJEOLWavelengthAt200kV() {
        // h / sqrt(2 m e V (1 + e V / (2 m c^2))): 2.5079 pm at 200 kV.
        #expect(abs(TIFFSignals.jeolWavelength(200000) - 2.5079e-12) < 1e-15)
    }

    // MARK: RosettaSciIO's public files

    @Test func testThePublicVendorFilesGiveRosettaSciIOsAxes() throws {
        let pins = FixtureDirs.fixtures(of: "FormatoTIFFTests").appendingPathComponent("step-2-pins.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: pins)) as! [String: Any]
        let names = ["tiff/TVIPS_bin4.zip/TVIPS_bin4.tif", "tiff/tiff_Zeiss_SEM.zip/ZEISS_SEM_multipage.tif",
                     "tiff/tiff_Zeiss_SEM.zip/test_tiff_Zeiss_SEM_1k.tif", "tiff/tiff_Zeiss_SEM.zip/test_tiff_Zeiss_SEM_512pix.tif",
                     "tiff/JEOL-SightX-Ronchigram-dummy.tif.gz", "tiff/JEOL-SightX-SAED-dummy.tif.gz", "tiff/JEOL-SightX-TEM-mag-dummy.tif.gz"]
        var compared = 0
        defer {
            // With the pinned clone present tools/test.sh unpacks all seven; without it none is compared.
            let clone = FixtureDirs.repository.appendingPathComponent("References/rosettasciio-049e7d70/rsciio/tests/data/tiff")
            if FileManager.default.fileExists(atPath: clone.path) { #expect(compared == names.count) }
        }
        for record in object["files"] as! [[String: Any]] {
            let path = record["path"] as! String
            guard names.contains(path) else { continue }
            let url = FixtureDirs.unpackedTIFF.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let pinned = (record["series"] as! [[String: Any]])[0]["axes"] as! [[String: Any]]
            let s = try TIFFSignals(path: url.path, options: option).signal(series: 0).load()
            compared += 1
            #expect(s.axes.count == pinned.count, "\(path)")
            for (a, q) in zip(s.axes, pinned) {
                #expect(a.name == q["name"] as? String, "\(path)")
                #expect(String(format: "%016llx", a.scale.bitPattern) == q["scale_bits"] as? String, "\(path): \(a.scale) vs \(q["scale"]!)")
                #expect(String(format: "%016llx", a.offset.bitPattern) == q["offset_bits"] as? String, "\(path)")
                #expect(a.units == ((q["units"] as? String) ?? ""), "\(path): \(a.units)")
                #expect(a.navigate == q["navigate"] as? Bool, "\(path)")
            }
        }
    }
}
