//
//  dump.swift
//  Move parity: one reader dump of one file, the same source on both sides.
//  tools/step-1/move-parity/run.sh builds it twice, as the `reader-dump` executable of a copy of SpectroKit 0.3.0
//  (with `import SpectroCore` prepended) and of a copy of FormatoKit's HEAD (with `import FormatoDM`, `FormatoEMD`,
//  `FormatoCore` prepended); those import lines are the only difference. It sits inside the copied package, so the
//  `package` declarations of the moved readers are reachable on both sides.
//
//  Usage: reader-dump FILE      (a .dm3/.dm4 or .emd; the dump goes to stdout, deterministic, one line per scalar)
//
//  Every thrown error is printed (`<call>: error <localizedDescription>` and its type), never fatal. The names that
//  differ by design (SpectroCancelled/FormatoCancelled, the module prefixes) are mapped to neutral tokens in `emit`.
//  `GoldenDump` is SpectroKit 0.3.0's walk, copied verbatim through FormatoGoldenTests.swift.
//

import Foundation

// MARK: - The dump (SpectroKit 0.3.0, verbatim)

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

// MARK: - Output

nonisolated(unsafe) private var stdoutLines = 0

/// The names that differ by design between the two sides, mapped to neutral tokens (README.md "What is normalised").
func normalise(_ s: String) -> String {
    var t = s
    for (a, b) in [("SpectroCancellation", "<Cancellation>"), ("FormatoCancellation", "<Cancellation>"),
                   ("SpectroCancelled", "<Cancelled>"), ("FormatoCancelled", "<Cancelled>"),
                   ("SpectroCore.", ""), ("FormatoCore.", ""), ("FormatoDM.", ""), ("FormatoEMD.", ""), ("FormatoHDF5.", "")] {
        t = t.replacingOccurrences(of: a, with: b)
    }
    return t
}

func emit(_ line: String) {
    print(normalise(line))
    stdoutLines += 1
}

func dumped(_ path: String, _ value: Any) {
    var lines: [String] = []
    GoldenDump.dump(path, value, into: &lines)
    for l in lines { emit(l) }
}

/// Runs `body`; a thrown error is printed as `<call>: error <localizedDescription>` plus its type, and nil is returned.
func attempt<T>(_ call: String, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
        emit("\(call): error \(error.localizedDescription)")
        emit("\(call): error-type \(String(reflecting: type(of: error)))")
        return nil
    }
}

// MARK: - DM3 / DM4

func dumpDM(path: String, size: Int) {
    guard let objects = attempt("DM4Experiment.list(path:)", { try DM4Experiment.list(path: path) }) else { return }
    dumped("list", objects)
    for o in objects {
        let tag = "object\(o.index)"
        // Every 2D object; the others only when small, so that the refusal of readImage is compared too, never a huge decode.
        if o.dimensions.count == 2 || o.dataByteCount < 64_000_000 {
            if let image = attempt("\(tag).readImage(path:index:)", { try DM4Experiment.readImage(path: path, index: o.index) }) {
                dumped("\(tag).image", image)
            }
        }
        if o.role == .eels {
            if let si = attempt("\(tag).readEELSSpectrumImage(path:index:)", { try DM4Experiment.readEELSSpectrumImage(path: path, index: o.index) }) {
                dumped("\(tag).eelsSpectrumImage", si)
            }
        }
        if o.role == .eds {
            if let si = attempt("\(tag).readEDSSpectrumImage(path:index:)", { try DM4Experiment.readEDSSpectrumImage(path: path, index: o.index) }) {
                dumped("\(tag).edsSpectrumImage", si)
            }
        }
    }
    if size < 64 * 1024 * 1024 {
        if let data = attempt("Data(contentsOf:)", { try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }),
           let tree = attempt("DM4Experiment.tagTree(data:)", { try DM4Experiment.tagTree(data: data) }) {
            dumped("tagTree.numbers", tree.numbers)
            dumped("tagTree.strings", tree.strings)
        }
    } else {
        emit("tagTree: skipped (file is \(size) bytes, 64 MiB or more)")
    }
}

// MARK: - Velox EMD

func dumpVelox(path: String, size: Int) {
    let isFile = VeloxEMDReader.isVeloxFile(path: path)
    let isEMD = VeloxEMDReader.isVeloxEMD(path: path)
    emit("isVeloxFile = \(isFile)")
    emit("isVeloxEMD = \(isEMD)")
    let reader = VeloxEMDReader(path: path)

    if let images = attempt("images()", { try reader.images() }) {
        dumped("images", images)
        for image in images {
            let frames = image.frameCount > 0 ? Array(Set([0, image.frameCount - 1])).sorted() : [0]
            for f in frames {
                let call = "readImageFrame(id: \(image.id), frame: \(f))"
                if let pixels = attempt(call, { try reader.readImageFrame(id: image.id, frame: f) }) {
                    dumped(call, pixels)
                }
            }
        }
    }

    if isEMD {
        if let v = attempt("readSpectrumImage()", { try reader.readSpectrumImage() }) {
            dumped("readSpectrumImage", v)
            let s = v.eventStore
            emit("store: totalCounts \(s.totalCounts) completeFrames \(s.completeFrames) partialFramePixels \(s.partialFramePixels) outOfRange \(s.outOfRangeValues)")
            dumped("store.summedSpectrum", s.summedSpectrum())
            let denseValues = s.geometry.pixelsPerFrame * s.geometry.channels
            if denseValues < 50_000_000 && size <= 1_000_000_000 {
                dumped("store.denseCounts", s.denseCounts())
            } else {
                emit("store.denseCounts: skipped (\(denseValues) dense values, file \(size) bytes)")
            }
        }
        if let m = attempt("markersPerFrame()", { try reader.markersPerFrame() }) { dumped("markersPerFrame", m) }
        if let m = attempt("streamLengthAndMarkers()", { try reader.streamLengthAndMarkers() }) { dumped("streamLengthAndMarkers", m) }
        if let t = attempt("readFrameTransformations()", { try reader.readFrameTransformations() }) { dumped("readFrameTransformations", t) }
        if let t = attempt("readFrameDetectorTimes()", { try reader.readFrameDetectorTimes() }) { dumped("readFrameDetectorTimes", t) }
    }
    // Also for a Velox file without a spectrum stream (it has image groups and settings), so its refusals are compared.
    if isFile || isEMD {
        if let e = attempt("storedElementSelection()", { try reader.storedElementSelection() }) { dumped("storedElementSelection", e) }
    }
}

// MARK: - Main

func runDump() {
    setvbuf(stdout, nil, _IOFBF, 1 << 20)
    guard CommandLine.arguments.count == 2 else {
        FileHandle.standardError.write(Data("usage: reader-dump FILE\n".utf8))
        exit(2)
    }
    let path = CommandLine.arguments[1]
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    emit("# reader-dump \((path as NSString).lastPathComponent) \(size) bytes")
    switch (path as NSString).pathExtension.lowercased() {
    case "dm3", "dm4": dumpDM(path: path, size: size)
    case "emd": dumpVelox(path: path, size: size)
    default: emit("not a .dm3/.dm4/.emd file")
    }
    emit("# end \(stdoutLines + 1) lines")
    fflush(stdout)
}

runDump()
