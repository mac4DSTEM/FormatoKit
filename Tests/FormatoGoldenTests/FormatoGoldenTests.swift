//
//  FormatoGoldenTests.swift
//  Gate M2 of docs/registration-step-1.md: the Velox reader's part of the inherited golden baseline, byte for byte.
//  The inherited 0.3.0 golden file `velox-tiny.txt` (baseline 71929a01, re-recorded
//  on purpose at the inherited reader's 0.2.0) holds the reader's outputs in its lines 1-175 and `SpectrumImageOpener`'s and the EDX
//  windows' after them; `Fixtures/velox-tiny-reader.txt` is those 175 lines verbatim. The dump below is the inherited
//  `GoldenDump` (copied verbatim from the inherited golden test at 0.3.0) and the calls are the
//  scenario's first part, verbatim; no tolerance anywhere.
//

import Testing
import Foundation
import FormatoEMD

// MARK: - The dump (inherited, 0.3.0, verbatim)

/// Reflection walk that writes one line per scalar: `path = value`. Deterministic: dictionaries and sets are sorted, absolute
/// paths keep their last component, numeric arrays above 8 elements are summarised by count, exact sum and bit hash.
enum GoldenDump {
    static func fnv(_ words: some Sequence<UInt64>) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for w in words {
            for i in 0..<8 { h ^= (w >> (8 * UInt64(i))) & 0xff; h = h &* 0x100000001b3 }
        }
        return h
    }

    static func hex(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) + String(format: " %.17g", d) }
    static func hex(_ f: Float) -> String { String(format: "%08x", f.bitPattern) + String(format: " %.9g", f) }

    private static func normalised(_ s: String) -> String {
        s.hasPrefix("/") ? "<abs>/" + (s as NSString).lastPathComponent : s
    }

    static func dump(_ path: String, _ value: Any, into out: inout [String], depth: Int = 0) {
        if depth > 16 { out.append("\(path) = <depth>"); return }
        switch value {
        case let d as Double: out.append("\(path) = \(hex(d))"); return
        case let f as Float: out.append("\(path) = \(hex(f))"); return
        case let b as Bool: out.append("\(path) = \(b)"); return
        case let i as Int: out.append("\(path) = \(i)"); return
        case let i as Int32: out.append("\(path) = \(i)"); return
        case let i as Int64: out.append("\(path) = \(i)"); return
        case let i as UInt8: out.append("\(path) = \(i)"); return
        case let i as UInt16: out.append("\(path) = \(i)"); return
        case let i as UInt32: out.append("\(path) = \(i)"); return
        case let i as UInt64: out.append("\(path) = \(i)"); return
        case let s as String: out.append("\(path) = \"\(normalised(s))\""); return
        case let data as Data: out.append("\(path) = Data(\(data.count), fnv \(String(fnv(data.map { UInt64($0) }), radix: 16)))"); return
        case let a as [Double]: numeric(path, a.map { $0.bitPattern }, sumBits: a.reduce(0, +).bitPattern, &out) { hex($0) }; return
        case let a as [Float]: numeric(path, a.map { UInt64($0.bitPattern) }, sumBits: UInt64(a.reduce(0, +).bitPattern), &out) { hex($0) }; return
        case let a as [Int]: numeric(path, a.map { UInt64(bitPattern: Int64($0)) }, sumBits: UInt64(bitPattern: Int64(a.reduce(0, +))), &out); return
        case let a as [Int32]: numeric(path, a.map { UInt64(bitPattern: Int64($0)) }, sumBits: UInt64(bitPattern: a.reduce(0) { $0 + Int64($1) }), &out); return
        case let a as [UInt8]: numeric(path, a.map { UInt64($0) }, sumBits: a.reduce(0) { $0 + UInt64($1) }, &out); return
        case let a as [UInt16]: numeric(path, a.map { UInt64($0) }, sumBits: a.reduce(0) { $0 + UInt64($1) }, &out); return
        case let a as [UInt32]: numeric(path, a.map { UInt64($0) }, sumBits: a.reduce(0) { $0 + UInt64($1) }, &out); return
        case let a as [UInt64]: numeric(path, a, sumBits: a.reduce(0, &+), &out); return
        case let a as [Bool]: numeric(path, a.map { $0 ? 1 : 0 }, sumBits: UInt64(a.filter { $0 }.count), &out); return
        case let n as NSNumber where type(of: value) is AnyClass: out.append("\(path) = NSNumber(\(n))"); return
        case let d as NSDictionary where type(of: value) is AnyClass:   // a Swift dictionary also bridges: only real NS objects
            out.append("\(path): dict \(d.count)")
            for k in d.allKeys.map({ "\($0)" }).sorted() { dump("\(path).\(k)", d["\(k)"] ?? d.object(forKey: k) as Any, into: &out, depth: depth + 1) }
            return
        case let a as NSArray where type(of: value) is AnyClass:
            out.append("\(path): array \(a.count)")
            for (i, e) in a.enumerated() { dump("\(path)[\(i)]", e, into: &out, depth: depth + 1) }
            return
        default: break
        }
        let m = Mirror(reflecting: value)
        switch m.displayStyle {
        case .optional:
            if let c = m.children.first { dump(path, c.value, into: &out, depth: depth) } else { out.append("\(path) = nil") }
        case .collection:
            let items = m.children.map { $0.value }
            if items.count > 400 {
                var sub: [String] = []
                for (i, e) in items.enumerated() { dump("[\(i)]", e, into: &sub, depth: depth + 1) }
                out.append("\(path): array \(items.count) fnv \(String(fnv(sub.joined(separator: "\n").utf8.map { UInt64($0) }), radix: 16))")
            } else {
                out.append("\(path): array \(items.count)")
                for (i, e) in items.enumerated() { dump("\(path)[\(i)]", e, into: &out, depth: depth + 1) }
            }
        case .set:
            let items = m.children.map { $0.value }.sorted { "\($0)" < "\($1)" }
            out.append("\(path): set \(items.count)")
            for (i, e) in items.enumerated() { dump("\(path){\(i)}", e, into: &out, depth: depth + 1) }
        case .dictionary:
            let entries = m.children.map { c -> (String, Any) in
                let kv = Array(Mirror(reflecting: c.value).children)
                return ("\(kv[0].value)", kv[1].value)
            }.sorted { $0.0 < $1.0 }
            out.append("\(path): dict \(entries.count)")
            for (k, v) in entries { dump("\(path).\(k)", v, into: &out, depth: depth + 1) }
        case .struct, .class, .tuple:
            if m.children.isEmpty { out.append("\(path) = \(normalised("\(value)"))"); return }
            for (i, c) in m.children.enumerated() {
                let label = c.label ?? ".\(i)"
                if label == "filePath" { out.append("\(path).\(label) = <omitted: machine path>"); continue }
                dump("\(path).\(label)", c.value, into: &out, depth: depth + 1)
            }
        case .enum:
            if m.children.isEmpty { out.append("\(path) = .\(value)"); return }
            for (i, c) in m.children.enumerated() { dump("\(path).\(c.label ?? "\(i)")", c.value, into: &out, depth: depth + 1) }
        default:
            out.append("\(path) = \(normalised("\(value)"))")
        }
    }

    private static func numeric(_ path: String, _ words: [UInt64], sumBits: UInt64, _ out: inout [String]) {
        out.append("\(path): n \(words.count) sum-bits \(String(sumBits, radix: 16)) fnv \(String(fnv(words), radix: 16))")
    }
    private static func numeric(_ path: String, _ words: [UInt64], sumBits: UInt64, _ out: inout [String], _ show: (Double) -> String) {
        let sum = Double(bitPattern: sumBits)
        out.append("\(path): n \(words.count) sum \(show(sum)) fnv \(String(fnv(words), radix: 16))")
        if words.count <= 8 { for (i, w) in words.enumerated() { out.append("\(path)[\(i)] = \(show(Double(bitPattern: w)))") } }
    }
}

// MARK: - Scenarios

// MARK: - The scenario: the reader part of the inherited "velox-tiny"

enum FormatoGolden {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// The inherited 0.3.0 `add("velox-tiny")` up to (not including) `SpectrumImageOpener.openVelox`, verbatim.
    static func veloxTinyReader() throws -> String {
        var out: [String] = ["# SpectroGolden velox-tiny"]
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FormatoEMDTests/Fixtures/velox-tiny.emd").path
        let v = try VeloxEMDReader(path: path).readSpectrumImage()
        GoldenDump.dump("readSpectrumImage", v, into: &out)
        let s = v.eventStore
        out.append("store: totalCounts \(s.totalCounts) completeFrames \(s.completeFrames) partialFramePixels \(s.partialFramePixels) outOfRange \(s.outOfRangeValues)")
        GoldenDump.dump("store.summedSpectrum", s.summedSpectrum(), into: &out)
        GoldenDump.dump("store.denseCounts", s.denseCounts(), into: &out)
        for p in 0..<s.geometry.pixelsPerFrame {
            out.append("pixel \(p): framesCovering \(s.framesCovering(pixel: p)) spectrum \(s.spectrum(pixel: p))")
        }
        let part = try VeloxEMDReader(path: path).readSpectrumImage(frames: .range(1..<2))
        out.append("frames 1..<2: totalCounts \(part.eventStore.totalCounts) complete \(part.eventStore.completeFrames) summed \(part.eventStore.summedSpectrum())")
        return out.joined(separator: "\n") + "\n"
    }
}

@Suite(.serialized) struct FormatoGoldenTests {
    /// Recomputes the reader's part of "velox-tiny" and compares it with the inherited 175 lines, byte for byte, reporting
    /// the first differing line. Mutation: one count of the event store changed - red at its line.
    @Test func testVeloxReaderOutputsAreByteIdenticalToTheInheritedBaseline() throws {
        let text = try FormatoGolden.veloxTinyReader()
        let recorded = try String(contentsOf: FormatoGolden.fixtures.appendingPathComponent("velox-tiny-reader.txt"), encoding: .utf8)
        #expect(recorded.split(separator: "\n").count == 176, "the fixture is the inherited 175 reader lines plus the 0.3.1 instrumentClass line")
        if text == recorded { return }
        let a = text.split(separator: "\n", omittingEmptySubsequences: false), b = recorded.split(separator: "\n", omittingEmptySubsequences: false)
        let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        Issue.record("velox-tiny moved at line \(i + 1): now \(i < a.count ? String(a[i]) : "<end>") | baseline \(i < b.count ? String(b[i]) : "<end>")")
    }
}
