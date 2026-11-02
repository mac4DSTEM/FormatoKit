//
//  TIFFVendorAxes.swift
//  Role: the axes RosettaSciIO 049e7d70's tiff reader gives three vendor branches (`_axes_zeiss`, `_axes_tvips`,
//        `_axes_jeol_sightx`), over the parts of tifffile 2026.9.20 they read: `read_cz_sem` (the unnamed values of tag
//        34118), `read_tvips_header` (the TVIPS v1 and v2 records of tag 37706) and the JEOL SightX XML description
//        (through RosettaSciIO's `XmlToDict`). Used under `TIFFVendorBranches.readWithVendorAxes` only: the branches'
//        metadata mappings are not ported, so the default still refuses these files by name. Where RosettaSciIO's code
//        raises, the caller falls back to the default dictionaries, as `_read_tiff` does.
//

import Foundation
import FormatoCore

extension TIFFSignals {
    /// The axes of `branch` as RosettaSciIO's branch reader gives them; nil for a branch whose axes are not ported
    /// (Olympus SIS, Hamamatsu streak: then the generic axes apply). Throws where RosettaSciIO's branch raises.
    static func vendorAxes(_ branch: String, page: TIFFDirectory, file: TIFFFile, shape: [Int], names: [String]) throws -> [FormatoAxis]? {
        var s: Triple = (1, 1, 1), u: Units = (nil, nil, nil)
        let o: Triple = (0, 0, 0)
        switch branch {
        case "Zeiss SEM":
            // `op["CZ_SEM"][""][3] * 1024 / tiff.pages[0].shape[1]`, in metres.
            guard let tag = page[34118] else { throw TIFFError.unsupportedLayout("KeyError") }
            let at = try readerOffset(tag, file: file), data = file.data
            let unnamed = czSEMUnnamed(data[(data.startIndex + at)..<(data.startIndex + at + tag.count)])
            guard unnamed.count > 3 else { throw TIFFError.unsupportedLayout("IndexError") }
            guard let width = file.directories[0][256]?.integer, width != 0 else { throw TIFFError.unsupportedLayout("no width") }
            let scale: Double
            switch unnamed[3] {
            case .int(let i):
                let (product, overflow) = i.multipliedReportingOverflow(by: 1024)
                // Python divides the exact integers, correctly rounded: equal to Double / Double while both are exact.
                guard !overflow, let p = Double(exactly: product), let w = Double(exactly: width) else {
                    throw TIFFError.unsupportedLayout("an integer scale too large to port")
                }
                scale = p / w
            case .float(let d): scale = d * 1024 / Double(width)
            default: throw TIFFError.unsupportedLayout("TypeError")
            }
            s.x = scale; s.y = scale; u.x = "m"; u.y = "m"
        case "TVIPS":
            // PixelSizeX/Y of a v2 record, in nm; otherwise the resolution tags times 1e-2, in metres.
            guard let tag = page[37706] else { throw TIFFError.unsupportedLayout("KeyError") }
            if let (x, y) = try tvipsPixelSize(file: file, at: try readerOffset(tag, file: file)) {
                s.x = x; s.y = y; u.x = "nm"; u.y = "nm"
            } else {
                (s.x, s.y) = try resolutionScales(page, factor: 1e-2)
                u.x = "m"; u.y = "m"
            }
        case "JEOL SightX":
            try jeolSightX(page, &s, &u)
        default:
            return nil
        }
        let (scales, offsets, units) = ordered(names, s, o, u)
        return dictionaries(shape: shape, names: names, scales: scales, offsets: offsets, units: units)
    }

    /// `_get_scales_from_x_y_resolution(op, factor)`: (YResolution den/num * factor, XResolution den/num * factor).
    static func resolutionScales(_ page: TIFFDirectory, factor: Double) throws -> (Double, Double) {
        let (y, x) = try resolutionScales(page)
        return (y * factor, x * factor)
    }

    // MARK: Zeiss SEM

    /// tifffile's `read_cz_sem`, the unnamed tuple `result[""]` only: every line before the first upper-case key line,
    /// or after a key's value, through `astype(line, (int, float))` (a line neither parses as stays text).
    static func czSEMUnnamed(_ raw: Data) -> [FormatoPythonValue] {
        var unnamed: [FormatoPythonValue] = []
        var key = false
        for line in pythonSplitLines(TIFFFile.bytes2str(raw)) {
            if pythonIsUpper(line) {
                key = true
            } else if key {
                // A `name=value` or `name: value` line ends the key; any other line is skipped with the key kept.
                if line.contains("=") || line.contains(":") { key = false }
            } else {
                let text = String(line)
                if let i = formatoPythonInt(text) { unnamed.append(.int(i)) }
                else if let d = formatoPythonFloat(text) { unnamed.append(.float(d)) }
                else { unnamed.append(.string(text)) }
            }
        }
        return unnamed
    }

    /// Python's `str.splitlines()`: no empty piece after a final line break.
    static func pythonSplitLines(_ s: String) -> [Substring] {
        var lines = TIFFFile.splitLines(s)
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    /// Python's `str.isupper()`: at least one cased character and no lower-case one.
    static func pythonIsUpper(_ s: Substring) -> Bool {
        var cased = false
        for c in s {
            if c.isLowercase { return false }
            if c.isUppercase { cased = true }
        }
        return cased
    }

    // MARK: TVIPS

    /// Where tifffile reads a tag that has a reader (`TiffTag.fromfile`: `code in TIFF.TAG_READERS`): the entry's value
    /// field is always an offset, even when the value would fit inline (a TVIPS LONG of count 1 points at its record).
    /// Throws where tifffile finds the offset invalid (below 8, or the value past the end) and keeps no value.
    static func readerOffset(_ tag: TIFFTag, file: TIFFFile) throws -> Int {
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8, 17: 8, 18: 8]
        guard let size = sizes[tag.type] else { throw TIFFError.unsupportedLayout("a reader tag of an unknown type") }
        let field = file.bigTIFF ? 8 : 4
        let (valueSize, overflow) = tag.count.multipliedReportingOverflow(by: size)
        guard !overflow else { throw TIFFError.unsupportedLayout("invalid value offset") }
        var offset = tag.valueOffset
        if valueSize <= field {
            let data = file.data
            guard tag.valueOffset >= 0, tag.valueOffset <= data.count - field else { throw TIFFError.truncated("The tag lies past the file.") }
            let b = [UInt8](data[(data.startIndex + tag.valueOffset)..<(data.startIndex + tag.valueOffset + field)])
            let v = file.bigEndian ? b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } : b.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard v <= UInt64(Int.max) else { throw TIFFError.unsupportedLayout("invalid value offset") }
            offset = Int(v)
        }
        guard offset >= 8, offset <= file.data.count - valueSize else { throw TIFFError.unsupportedLayout("invalid value offset") }
        return offset
    }

    /// The PixelSizeX and PixelSizeY of a TVIPS v2 record at `offset` (float32, as tifffile's `tolist()` widens them), or
    /// nil where `read_tvips_header` gives no such keys (a v1 record; a v2 record without the magic number; an unknown
    /// version). Throws where the record does not fit in the file (tifffile then has no dictionary to look in).
    static func tvipsPixelSize(file: TIFFFile, at offset: Int) throws -> (Double, Double)? {
        let data = file.data
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at <= data.count - 4 else { throw TIFFError.truncated("The TVIPS record ends past the file.") }
            let b = [UInt8](data[(data.startIndex + at)..<(data.startIndex + at + 4)])
            return file.bigEndian
                ? b.reduce(0) { $0 << 8 | UInt32($1) }
                : b.reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        let v1Size = 244, v2Size = 6068
        // A short read makes tifffile keep the raw value (a tuple without "PixelSizeX"): the resolution path follows.
        guard offset >= 0, offset <= data.count - v1Size else { return nil }
        let version = Int32(bitPattern: try u32(offset))
        guard version == 2 else { return nil }
        let v2 = offset + v1Size
        guard v2 <= data.count - v2Size else { return nil }
        guard try u32(v2 + 6064) == 0xAAAA_AAAA else { return nil }
        let x = Float(bitPattern: try u32(v2 + 2724)), y = Float(bitPattern: try u32(v2 + 2728))
        return (Double(x), Double(y))
    }

    // MARK: JEOL SightX

    /// `_axes_jeol_sightx`: the description's XML (lines stripped of " \r\n\t\x01\x00" and joined), then TEM MAG or TEM
    /// DIFF calibrate the resolution tags; any other mode leaves the default scales.
    static func jeolSightX(_ page: TIFFDirectory, _ s: inout Triple, _ u: inout Units) throws {
        guard let description = page[270]?.text else { throw TIFFError.unsupportedLayout("KeyError") }
        let strip = CharacterSet(charactersIn: " \r\n\t\u{01}\u{00}")
        // Split by scalar: Swift keeps "\r\n" as one Character, Python splits it at the "\n".
        let xml = description.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: strip) }.joined()
        let root = try XMLNode.parse(xml)
        guard root.name == "TemReporter" else { throw TIFFError.unsupportedLayout("KeyError") }
        let eos = try root.value("Eos", "EosMode")
        // `mode_strs`: each piece must be text ([4:] and ", ".join raise otherwise).
        guard case .string = try root.value("IlluminationSystem", "ImageField") else { throw TIFFError.unsupportedLayout("TypeError") }
        let forming = eos == .string("modeASID") ? "ScanningImageFormingMode" : "ImageFormingMode"
        guard case .string = try root.value("ImageFormingSystem", forming),
              case .string = try root.value("ImageFormingSystem", "SelectorString") else { throw TIFFError.unsupportedLayout("TypeError") }
        guard let unit = page[296]?.integer else { throw TIFFError.unsupportedLayout("KeyError") }
        var scale = unit == 2 ? 0.0254 : 0.01
        guard eos == .string("eosTEM") else { return }
        let mode = try root.value("ImageFormingSystem", "ModeString")
        func float(_ v: XMLNode.Value) throws -> Double {
            switch v {
            case .int(let i): return Double(i)
            case .float(let d): return d
            case .string(let t): guard let d = formatoPythonFloat(t) else { throw TIFFError.unsupportedLayout("ValueError") }; return d
            case .none, .dictionary: throw TIFFError.unsupportedLayout("TypeError")
            }
        }
        if mode == .string("MAG") {
            let mag = try float(try root.value("ImageFormingSystem", "SelectorValue"))
            guard mag != 0 else { throw TIFFError.unsupportedLayout("ZeroDivisionError") }
            (s.x, s.y) = try resolutionScales(page, factor: scale / mag * 1e9)
            u = ("nm", "nm", "nm")
        } else if mode == .string("DIFF") {
            var cameraLength = try float(try root.value("ImageFormingSystem", "SelectorValue"))
            let ht = try float(try root.value("ElectronGun", "AccelerationVoltage"))
            let selectorUnit = try root.value("ImageFormingSystem", "SelectorUnitString")
            if selectorUnit == .string("mm") { cameraLength /= 1000 } else if selectorUnit == .string("cm") { cameraLength /= 100 }
            // `wave_len` returns a NumPy float64, so a zero divisor gives inf (a RuntimeWarning), not ZeroDivisionError.
            scale /= cameraLength * jeolWavelength(ht) * 1e9
            (s.x, s.y) = try resolutionScales(page, factor: scale)
            u = ("1 / nm", "1 / nm", nil)
        }
    }

    /// RosettaSciIO's `wave_len(ht)` in `_axes_jeol_sightx`, operation for operation.
    static func jeolWavelength(_ ht: Double) -> Double {
        let mE = 9.1093837015e-31, eC = 1.602176634e-19, c = 299792458.0, h = 6.62607015e-34
        let momentum = 2 * mE * eC * ht * (1 + eC * ht / (2 * mE * (c * c)))
        return h / momentum.squareRoot()
    }
}

/// A parsed XML element, as much as `XmlToDict.dictionarize` needs for the JEOL SightX paths: a leaf's text through
/// `literal_eval`, an element with attributes or children as a dictionary.
nonisolated final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    enum Value: Equatable {
        case none, int(Int64), float(Double), string(String), dictionary
    }

    /// `dictionarize` of this node, as the parent sees it: None for an empty leaf without attributes, a dictionary for an
    /// element with attributes or children, else `literal_eval` of the text, applied again by the parent when the first
    /// pass gave text (so `'1.5'` is the number 1.5). Literals beyond numbers: True and False are ints for `float()` and
    /// not text; None; a hexadecimal, octal or binary int; a list, tuple, dict or set literal is no text and no number.
    var value: Value {
        guard attributes.isEmpty, children.isEmpty else { return .dictionary }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .none }
        let first = Self.literal(t)
        if case .string(let s) = first, s != t { return Self.literal(s) }
        return first
    }

    /// One `literal_eval` (or the text itself where it raises), for the literals a JEOL value can take.
    static func literal(_ t: String) -> Value {
        if let i = formatoPythonInt(t) { return .int(i) }
        if t == "True" { return .int(1) }
        if t == "False" { return .int(0) }
        if t == "None" { return .none }
        let body = t.hasPrefix("-") || t.hasPrefix("+") ? String(t.dropFirst()) : t
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where body.lowercased().hasPrefix(prefix) {
            if let v = Int64(body.dropFirst(2).replacingOccurrences(of: "_", with: ""), radix: radix) { return .int(t.hasPrefix("-") ? -v : v) }
        }
        let lower = t.lowercased()
        if let d = formatoPythonFloat(t), !lower.contains("inf"), !lower.contains("nan") { return .float(d) }
        if let q = t.first, q == "'" || q == "\"", t.count >= 2, t.last == q {
            let inner = t.dropFirst().dropLast()
            if !inner.contains(q) && !inner.contains("\\") { return .string(String(inner)) }
        }
        if let b = t.first, "([{".contains(b) { return .dictionary }
        return .string(t)
    }

    /// The value at `path` below this node; throws where Box raises (a missing key, or a repeated one: a list).
    func value(_ path: String...) throws -> Value {
        var node = self
        for key in path {
            let matches = node.children.filter { $0.name == key }
            guard matches.count == 1 else { throw TIFFError.unsupportedLayout("KeyError") }
            node = matches[0]
        }
        return node.value
    }

    /// `ET.fromstring`: the root element, or a throw where the text is not well-formed XML.
    static func parse(_ xml: String) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw TIFFError.unsupportedLayout("ParseError") }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let node = XMLNode(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // ElementTree's `text` is the text before the first child; later runs are tails and do not count.
            if let node = stack.last, node.children.isEmpty { node.text += string }
        }
    }
}
