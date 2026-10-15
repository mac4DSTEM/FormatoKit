//
//  TIFFPolicyTests.swift
//  Registration 0.2.0, P5 `TIFFReadOptions.vendorBranches` (tier 2): files built byte by byte here, their values typed as
//  literals. A vendor tag is refused by name by default; `.readAsGeneric` reads the pixels as a plain TIFF and flags it;
//  a layout refusal (Compression 5) holds under every option.
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFPolicyTests {
    private enum Extra {
        case long(code: Int, value: Int)
        case ascii(code: Int, text: String)
    }

    /// A 3 x 4 uint8 TIFF (values 10 r + c, little-endian, one strip), plus `extra` tags and the given Compression.
    private func build(extra: [Extra], compression: Int = 1) -> Data {
        // Fixed entries, sorted by code with the extras.
        enum Entry { case short(Int, Int), long(Int, Int), ascii(Int, [UInt8]) }
        var entries: [Entry] = [.short(256, 4), .short(257, 3), .short(258, 8), .short(259, compression), .short(262, 1),
                                .long(273, 0), .short(277, 1), .long(279, 12)]
        for e in extra {
            switch e {
            case .long(let code, let value): entries.append(.long(code, value))
            case .ascii(let code, let text): entries.append(.ascii(code, Array(text.utf8) + [0]))
            }
        }
        func code(_ e: Entry) -> Int { switch e { case .short(let c, _), .long(let c, _), .ascii(let c, _): return c } }
        entries.sort { code($0) < code($1) }
        let pixelsAt = 8 + 2 + entries.count * 12 + 4
        var strings = Data()
        var d = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        u16(entries.count)
        for e in entries {
            switch e {
            case .short(let c, let v): u16(c); u16(3); u32(1); u16(v); u16(0)
            case .long(let c, let v): u16(c); u16(4); u32(1); u32(c == 273 ? pixelsAt : v)
            case .ascii(let c, let bytes):
                u16(c); u16(2); u32(bytes.count)
                if bytes.count <= 4 { d.append(contentsOf: bytes + [UInt8](repeating: 0, count: 4 - bytes.count)) }
                else { u32(pixelsAt + 12 + strings.count); strings.append(contentsOf: bytes) }
            }
        }
        u32(0)
        let rows: [UInt8] = (0..<3).flatMap { (r: Int) -> [UInt8] in (0..<4).map { (c: Int) -> UInt8 in UInt8(10 * r + c) } }
        d.append(contentsOf: rows)
        d.append(strings)
        return d
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("formato-policy-\(UUID().uuidString).tif")
        try data.write(to: url)
        return url
    }

    private let generic = TIFFReadOptions(vendorBranches: .readAsGeneric)
    private let wantPixels: [Double] = [0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22, 23]
    private let flagKey = "FormatoKit.policy.vendor_branch"

    @Test func testTheOptionsDefaultToRefuse() {
        let defaults = TIFFReadOptions()
        #expect(defaults.vendorBranches == .refuse)
    }

    @Test func testTVIPSIsRefusedByNameByDefaultAndReadAsGenericOnRequest() throws {
        let url = try write(build(extra: [.long(code: 37706, value: 0)]))
        defer { try? FileManager.default.removeItem(at: url) }

        let plain = #expect(throws: (any Error).self) { _ = try TIFFSignals(path: url.path) }
        #expect(plain.map { "\($0)".contains("TVIPS") } == true, "\(String(describing: plain))")
        let refused = #expect(throws: (any Error).self) { _ = try TIFFSignals(path: url.path, options: TIFFReadOptions()) }
        #expect(refused.map { "\($0)".contains("TVIPS") } == true, "\(String(describing: refused))")

        let tiff = try TIFFSignals(path: url.path, options: generic)
        #expect(tiff.vendorBranch == "TVIPS")
        let s = try tiff.signal(series: 0).load()
        #expect(s.data.shape == [3, 4])
        #expect(s.data.dataType == .uint8)
        #expect(s.data.doubles() == wantPixels)
        let axisNames: [String?] = s.axes.map(\.name)
        let wantNames: [String?] = ["height", "width"]
        #expect(axisNames == wantNames)
        let flag = try #require(s.metadata[flagKey])
        #expect(flag.value == .text("TVIPS"))
        let rule = flag.provenance.rule
        #expect(rule.hasPrefix("FormatoKit policy, not RosettaSciIO's: read as a plain TIFF"), "\(rule)")
        // The ordinary entries are still there beside the flag.
        #expect(s.metadata["General.original_filename"] != nil)
    }

    @Test func testEveryVendorBranchIsNamedAndFlagged() throws {
        let cases: [([Extra], String)] = [
            ([.long(code: 34118, value: 0)], "Zeiss SEM"),
            ([.long(code: 37706, value: 0)], "TVIPS"),
            ([.long(code: 33560, value: 0)], "Olympus SIS"),
            ([.long(code: 33471, value: 0)], "Olympus SIS"),
            ([.ascii(code: 271, text: "JEOL Ltd.")], "JEOL SightX"),
            ([.ascii(code: 315, text: "Copyright Hamamatsu Photonics"), .ascii(code: 305, text: "HPD-TA 9.5")], "Hamamatsu streak"),
        ]
        for (extra, branch) in cases {
            let url = try write(build(extra: extra))
            defer { try? FileManager.default.removeItem(at: url) }
            let error = #expect(throws: (any Error).self, "\(branch)") { _ = try TIFFSignals(path: url.path) }
            #expect(error.map { "\($0)".contains(branch) } == true, "\(branch): \(String(describing: error))")
            let tiff = try TIFFSignals(path: url.path, options: generic)
            #expect(tiff.vendorBranch == branch)
            let s = try tiff.signal(series: 0).load()
            #expect(s.data.doubles() == wantPixels, "\(branch)")
            #expect(s.metadata[flagKey]?.value == .text(branch), "\(branch)")
        }
    }

    @Test func testAPlainTIFFCarriesNoPolicyKeyUnderAnyOption() throws {
        let url = try write(build(extra: []))
        defer { try? FileManager.default.removeItem(at: url) }
        for options in [TIFFReadOptions(), generic] {
            let tiff = try TIFFSignals(path: url.path, options: options)
            #expect(tiff.vendorBranch == nil)
            let s = try tiff.signal(series: 0).load()
            #expect(s.data.doubles() == wantPixels)
            #expect(s.metadata[flagKey] == nil)
            let policyKeys = s.metadata.keys.filter { $0.hasPrefix("FormatoKit.policy.") }
            #expect(policyKeys.isEmpty)
        }
    }

    @Test func testALayoutRefusalHoldsUnderReadAsGeneric() throws {
        let url = try write(build(extra: [.long(code: 37706, value: 0)], compression: 5))
        defer { try? FileManager.default.removeItem(at: url) }
        // By default the vendor branch is named first.
        let named = #expect(throws: (any Error).self) { _ = try TIFFSignals(path: url.path) }
        #expect(named.map { "\($0)".contains("TVIPS") } == true, "\(String(describing: named))")
        // Read as generic, the compression still refuses.
        let error = #expect(throws: (any Error).self) { _ = try TIFFSignals(path: url.path, options: generic) }
        #expect(error.map { "\($0)".lowercased().contains("compressed") } == true, "\(String(describing: error))")
    }

    /// RosettaSciIO's public TVIPS test file, when `tools/test.sh` has unpacked it: skipped when absent. It is read as generic
    /// if its layout is one this reader reads, and then it carries the flag; a layout refusal is also acceptable.
    @Test func testThePublicTVIPSFileReadsAsGenericWhenItsLayoutIsRead() throws {
        let url = FormatoTIFFPinsTests.unpacked.appendingPathComponent("tiff/TVIPS_bin4.zip/TVIPS_bin4.tif")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let named = #expect(throws: (any Error).self) { _ = try TIFFSignals(path: url.path) }
        #expect(named.map { "\($0)".contains("TVIPS") } == true, "\(String(describing: named))")
        do {
            let s = try TIFFSignals(path: url.path, options: generic).signal(series: 0).load()
            #expect(s.metadata[flagKey]?.value == .text("TVIPS"))
        } catch {
            #expect("\(error)".contains("TVIPS") == false)
        }
    }
}
