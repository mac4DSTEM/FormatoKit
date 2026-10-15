//
//  DMPolicyTests.swift
//  Registration 0.2.0, P6 `DMReadOptions.maximumStringBytes` (tier 2): bare tag streams built byte by byte here. A type-18
//  string is cut at the limit, a UTF-16 array at or past it is absent, and numeric arrays keep their own fixed 4096-byte rule.
//

import Foundation
import Testing
@testable import FormatoDM

@Suite struct DMPolicyTests {
    private enum Node {
        case string18(String, [UInt8])
        case utf16(String, String)
        case doubles(String, [Double])
        case int(String, Int32)
        case group(String, [Node])
        case blob(String, bytes: [UInt8])
    }

    private static func u16be(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u64be(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }
    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] { [tag] + u16be(label.utf8.count) + Array(label.utf8) + u64be(0) }
    private static let delim: [UInt8] = [37, 37, 37, 37]

    private static func encode(_ node: Node) -> [UInt8] {
        switch node {
        case .string18(let l, let bytes):
            return head(21, l) + delim + u64be(2) + u64be(18) + u64be(UInt64(bytes.count)) + bytes
        case .utf16(let l, let s):
            let units = Array(s.utf16)
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(4) + u64be(UInt64(units.count))
                + units.flatMap { le(UInt64($0), 2) }
        case .doubles(let l, let a):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(7) + u64be(UInt64(a.count))
                + a.flatMap { le($0.bitPattern, 8) }
        case .int(let l, let v):
            return head(21, l) + delim + u64be(1) + u64be(3) + le(UInt64(UInt32(bitPattern: v)), 4)
        case .group(let l, let kids):
            return head(20, l) + [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        case .blob(let l, let bytes):
            return head(21, l) + delim + u64be(3) + u64be(20) + u64be(10) + u64be(UInt64(bytes.count)) + bytes
        }
    }

    /// A complete version-4 stream whose root group holds `kids`.
    private static func stream(_ kids: [Node]) -> Data {
        let body: [UInt8] = [1, 0] + u64be(UInt64(kids.count)) + kids.flatMap(encode)
        return Data([0, 0, 0, 4] + u64be(0) + [0, 0, 0, 1] + body)
    }

    /// Text whose character at index i is a letter by i, so a cut at n bytes is the first n of it.
    private static func text(_ n: Int) -> String { String((0..<n).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) }) }

    private func tree(_ nodes: [Node], _ options: DMReadOptions?) throws -> (numbers: [String: Double], strings: [String: String]) {
        let data = Self.stream(nodes)
        guard let options else { return try DM4Experiment.tagTree(data: data) }
        return try DM4Experiment.tagTree(data: data, options: options)
    }

    @Test func testTheDefaultIs4096() {
        let options = DMReadOptions()
        #expect(options.maximumStringBytes == 4096)
    }

    @Test func testAType18StringIsCutAtTheLimit() throws {
        let long = Self.text(5000)
        let nodes: [Node] = [.string18("S", Array(long.utf8))]
        let byDefault = try tree(nodes, nil)
        let explicitDefault = try tree(nodes, DMReadOptions())
        #expect(byDefault.strings["S"] == String(long.prefix(4096)))
        #expect(explicitDefault.strings["S"] == String(long.prefix(4096)))
        let whole = try tree(nodes, DMReadOptions(maximumStringBytes: Int.max))
        #expect(whole.strings["S"] == long)
        let cut = try tree(nodes, DMReadOptions(maximumStringBytes: 100))
        #expect(cut.strings["S"] == String(long.prefix(100)))
        // Walking on past a cut string: the tag after it is still read.
        let after = try tree([.string18("S", Array(long.utf8)), .int("N", 7)], DMReadOptions(maximumStringBytes: 100))
        #expect(after.numbers["N"] == 7)
    }

    @Test func testAUTF16StringAtOrPastTheLimitIsAbsent() throws {
        let long = Self.text(2500)                       // 5000 bytes
        let nodes: [Node] = [.utf16("U", long)]
        let byDefault = try tree(nodes, nil)
        #expect(byDefault.strings["U"] == nil)
        let whole = try tree(nodes, DMReadOptions(maximumStringBytes: Int.max))
        #expect(whole.strings["U"] == long)
        // The boundary: 50 characters are 100 bytes, kept only when the limit is above 100.
        let fifty = Self.text(50)
        let atLimit = try tree([.utf16("U", fifty)], DMReadOptions(maximumStringBytes: 100))
        #expect(atLimit.strings["U"] == nil)
        let above = try tree([.utf16("U", fifty)], DMReadOptions(maximumStringBytes: 101))
        #expect(above.strings["U"] == fifty)
        // A short string is kept by the default.
        let short = try tree([.utf16("U", fifty)], nil)
        #expect(short.strings["U"] == fifty)
    }

    @Test func testANumericArrayKeepsItsFixedLimitWhateverTheStringLimit() throws {
        // 600 Doubles are 4800 bytes: over the array rule, so absent from both maps under every string limit.
        let nodes: [Node] = [.doubles("D", [Double](repeating: 1.5, count: 600))]
        for limit in [4096, 100, Int.max] {
            let t = try tree(nodes, DMReadOptions(maximumStringBytes: limit))
            #expect(t.numbers["D"] == nil, "limit \(limit)")
            #expect(t.strings["D"] == nil, "limit \(limit)")
        }
    }

    /// The array is not in either map, so its presence is seen through the one place the walk uses a numeric array: the
    /// survey image's spectrum image rect (four or more Doubles). Over 4096 bytes it must be dropped, under a huge string limit too.
    @Test func testTheArrayRuleIsObservedThroughTheSpectrumImageRect() throws {
        func object(rect: [Double]) -> Data {
            let tags: [Node] = [.group("SI", [.group("Acquisition", [.group("Survey Image", [.doubles("Spectrum Image Rect", rect)])])])]
            let dims: [Node] = [.int("", 2), .int("", 2)]
            let image: [Node] = [.group("ImageData", [.blob("Data", bytes: [1, 2, 3, 4]), .int("DataType", 6), .group("Dimensions", dims)]),
                                 .group("ImageTags", tags)]
            return Self.stream([.group("ImageList", [.group("", image)])])
        }
        let small = object(rect: [1, 2, 3, 4])
        let big = object(rect: [Double](repeating: 2, count: 600))
        for options in [DMReadOptions(), DMReadOptions(maximumStringBytes: Int.max)] {
            let withSmall = try DM4Experiment.list(data: small, options: options)
            #expect(withSmall.count == 1)
            let rect = try #require(withSmall.first?.spectrumImageRect, "a 4-element rect is kept")
            #expect(rect.top == 1)
            #expect(rect.right == 4)
            let withBig = try DM4Experiment.list(data: big, options: options)
            #expect(withBig.count == 1)
            #expect(withBig.first?.spectrumImageRect == nil, "a 600-element array stays dropped: \(options.maximumStringBytes)")
        }
    }
}
