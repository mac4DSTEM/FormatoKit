//
//  FormatoMSA.swift
//  Role: The EMSA/MAS spectral data format (`.msa`, `.ems`, `.mas`, `.emsa`) as RosettaSciIO's `msa` plugin reads and writes it
//        (`rsciio/msa/_api.py`, identical at 0.14.0 and at the pin 049e7d70): `MSAReader` is `parse_msa_string` / `file_reader`
//        (keywords, XY and Y data, the keyword-to-metadata mapping, the date and time, the signal type and the quantity),
//        `MSAWriter` is `file_writer` (the header, `Y` or `XY` data, the 64-character title and comment lines, CR LF; the header comment
//        names `creator`, not RosettaSciIO's version).
//        Python's rules are ported where they decide a result: `str.split(": ")`, `strip`, `float()`, `datetime.strptime`.
//        Where RosettaSciIO raises, the read throws `FormatoReadError.unsupported` naming the rule. Registered deviations
//        (docs/parity.md): a numeric keyword whose value does not convert stays a string in RosettaSciIO and breaks later; here
//        the read is refused when the axis keywords are such; the writer validates `format` before it opens the file (RosettaSciIO
//        truncates the file first); the writer does not rewrite the keyword table for an SEM signal (RosettaSciIO's module-level
//        `keywords` is changed by the first SEM write in a process, which changes every later read and write).
//

import Foundation
import FormatoCore

/// A keyword's value as RosettaSciIO leaves it: a string, or a float where its type conversion succeeded.
public nonisolated enum MSAValue: Sendable, Equatable {
    case text(String)
    case number(Double)
}

/// One `#KEY: value` line of the header, in file order; `value` is nil where the line had no `": "` (Python `None`).
public nonisolated struct MSAParameter: Sendable, Equatable {
    public let key: String
    public let value: MSAValue?
    public init(key: String, value: MSAValue?) {
        self.key = key
        self.value = value
    }
}

/// The text encoding of the file (RosettaSciIO's `encoding`, default `latin-1`).
public nonisolated enum MSAEncoding: Sendable, Equatable {
    case latin1
    case utf8
}

/// `DATATYPE` as the writer takes it: the signal axis written beside the counts (`xy`) or not (`y`).
public nonisolated enum MSADataFormat: String, Sendable, Equatable {
    case y = "Y"
    case xy = "XY"
}

public nonisolated struct MSASpectrum: Sendable, Equatable {
    /// RosettaSciIO's dictionary: float64 counts, one axis, the mapped metadata, the signal type.
    public let signal: FormatoSignal
    /// RosettaSciIO's `original_metadata`: every keyword, in file order (with `FORMAT` rewritten to the standard's text).
    public let parameters: [MSAParameter]
}

private nonisolated struct MSAKeyword {
    let name: String
    let isNumber: Bool
    let mappedTo: String?
}

/// `rsciio.msa._api.keywords`, in its order.
private nonisolated let msaKeywords: [MSAKeyword] = {
    func k(_ n: String, _ number: Bool, _ m: String? = nil) -> MSAKeyword { MSAKeyword(name: n, isNumber: number, mappedTo: m) }
    return [
        k("FORMAT", false), k("VERSION", false), k("TITLE", false, "General.title"), k("DATE", false), k("TIME", false),
        k("OWNER", false), k("NPOINTS", true), k("NCOLUMNS", true), k("DATATYPE", false), k("XPERCHAN", true), k("OFFSET", true),
        k("SIGNALTYPE", false), k("XLABEL", false), k("YLABEL", false), k("XUNITS", false), k("YUNITS", false),
        k("CHOFFSET", true), k("COMMENT", false),
        k("BEAMKV", true, "Acquisition_instrument.TEM.beam_energy"), k("EMISSION", true),
        k("PROBECUR", true, "Acquisition_instrument.TEM.beam_current"), k("BEAMDIAM", true), k("MAGCAM", true), k("OPERMODE", false),
        k("CONVANGLE", true, "Acquisition_instrument.TEM.convergence_angle"),
        k("THICKNESS", true, "Sample.thickness"), k("XTILTSTGE", true, "Acquisition_instrument.TEM.Stage.tilt_alpha"),
        k("YTILTSTGE", true), k("XPOSITION", true), k("YPOSITION", true), k("ZPOSITION", true),
        k("INTEGTIME", true, "Acquisition_instrument.TEM.Detector.EELS.exposure"),
        k("DWELLTIME", true, "Acquisition_instrument.TEM.Detector.EELS.dwell_time"),
        k("COLLANGLE", true, "Acquisition_instrument.TEM.Detector.EELS.collection_angle"), k("ELSDET", false),
        k("ELEVANGLE", true, "Acquisition_instrument.TEM.Detector.EDS.elevation_angle"),
        k("AZIMANGLE", true, "Acquisition_instrument.TEM.Detector.EDS.azimuth_angle"),
        k("SOLIDANGLE", true, "Acquisition_instrument.TEM.Detector.EDS.solid_angle"),
        k("LIVETIME", true, "Acquisition_instrument.TEM.Detector.EDS.live_time"),
        k("REALTIME", true, "Acquisition_instrument.TEM.Detector.EDS.real_time"),
        k("FWHMMNKA", true, "Acquisition_instrument.TEM.Detector.EDS.energy_resolution_MnKa"),
        k("TBEWIND", true), k("TAUWIND", true), k("TDEADLYR", true), k("TACTLYR", true), k("TALWIND", true), k("TPYWIND", true),
        k("TBNWIND", true), k("TDIWIND", true), k("THCWIND", true),
        k("EDSDET", false, "Acquisition_instrument.TEM.Detector.EDS.EDS_det"),
    ]
}()

private nonisolated let msaMonths = ["01": "JAN", "02": "FEB", "03": "MAR", "04": "APR", "05": "MAY", "06": "JUN", "07": "JUL",
                                     "08": "AUG", "09": "SEP", "10": "OCT", "11": "NOV", "12": "DEC"]
private nonisolated let msaFormatText = "EMSA/MAS Spectral Data File"

// MARK: Python string rules

/// Python's `str` as scalars: `strip`, `split` and friends on code points (not Characters: "\r\n" is two).
private typealias PyText = [Unicode.Scalar]

private nonisolated func pyIsSpace(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 9...13, 28...32, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

private nonisolated func pyString(_ t: PyText) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: t)
    return String(v)
}

private nonisolated func pyText(_ s: String) -> PyText { Array(s.unicodeScalars) }

private nonisolated func pyStrip(_ t: PyText) -> PyText {
    var a = 0, b = t.count
    while a < b, pyIsSpace(t[a]) { a += 1 }
    while b > a, pyIsSpace(t[b - 1]) { b -= 1 }
    return Array(t[a..<b])
}

private nonisolated func pyRstrip(_ t: PyText) -> PyText {
    var b = t.count
    while b > 0, pyIsSpace(t[b - 1]) { b -= 1 }
    return Array(t[0..<b])
}

/// `s.strip("#")`.
private nonisolated func pyStripHash(_ t: PyText) -> PyText {
    var a = 0, b = t.count
    while a < b, t[a] == "#" { a += 1 }
    while b > a, t[b - 1] == "#" { b -= 1 }
    return Array(t[a..<b])
}

/// `s.split(sep)` for a non-empty separator.
private nonisolated func pySplit(_ t: PyText, _ sep: PyText) -> [PyText] {
    var out: [PyText] = []
    var start = 0, i = 0
    while i + sep.count <= t.count {
        if Array(t[i..<(i + sep.count)]) == sep {
            out.append(Array(t[start..<i]))
            i += sep.count
            start = i
        } else {
            i += 1
        }
    }
    out.append(Array(t[start...]))
    return out
}

/// `s.split()`: runs of whitespace separate, none at the ends.
private nonisolated func pySplitWhitespace(_ t: PyText) -> [PyText] {
    var out: [PyText] = []
    var current: PyText = []
    for s in t {
        if pyIsSpace(s) {
            if !current.isEmpty { out.append(current); current = [] }
        } else {
            current.append(s)
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}

// MARK: strptime (the three formats RosettaSciIO uses)

private nonisolated func regexMatch(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$"),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
}

/// `datetime.strptime(text, "%H:%M")` or `"%H:%M:%S"`; nil is ValueError.
private nonisolated func strptimeTime(_ text: String, seconds: Bool) -> String? {
    let h = "(2[0-3]|[0-1]\\d|\\d)", m = "([0-5]\\d|\\d)", s = "(6[0-1]|[0-5]\\d|\\d)"
    guard let g = regexMatch(seconds ? "\(h):\(m):\(s)" : "\(h):\(m)", text), let hour = Int(g[0]), let minute = Int(g[1]) else { return nil }
    let second = seconds ? Int(g[2]) ?? 0 : 0
    guard second <= 59 else { return nil }   // datetime(second=60 or 61) raises
    return String(format: "%02d:%02d:%02d", hour, minute, second)
}

/// `datetime.strptime(text, "%d-%m-%Y").date().isoformat()`; nil is ValueError.
private nonisolated func strptimeDate(_ text: String) -> String? {
    guard let g = regexMatch("(3[0-1]|[1-2]\\d|0[1-9]|[1-9]| [1-9])-(1[0-2]|0[1-9]|[1-9])-(\\d\\d\\d\\d)", text),
          let day = Int(g[0].trimmingCharacters(in: .whitespaces)), let month = Int(g[1]), let year = Int(g[2]), year >= 1 else { return nil }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard day <= days[month - 1] else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
}

// MARK: reader

public nonisolated enum MSAReader {
    /// RosettaSciIO's `file_reader(filename, encoding=...)`.
    public static func read(path: String, encoding: MSAEncoding = .latin1) throws -> MSASpectrum {
        guard let bytes = FileManager.default.contents(atPath: path) else {
            throw FormatoReadError.cannotOpen(formatoDisplayFileName(path), "the file cannot be read")
        }
        return try parse(bytes: bytes, fileName: path, encoding: encoding)
    }

    /// RosettaSciIO's `parse_msa_string` on the decoded text of `bytes`; `fileName` gives `General.original_filename`.
    public static func parse(bytes: Data, fileName: String?, encoding: MSAEncoding = .latin1) throws -> MSASpectrum {
        let name = fileName.map(formatoDisplayFileName) ?? "(memory)"
        func raises(_ why: String) -> FormatoReadError { .unsupported("MSA file \(name): \(why) (RosettaSciIO raises).") }

        var scalars: PyText
        switch encoding {
        case .latin1: scalars = bytes.map { Unicode.Scalar($0) }
        case .utf8: scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        }
        // Universal newlines, as Python's text-mode iteration; each line keeps its "\n".
        var lines: [PyText] = []
        var line: PyText = []
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r" {
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                line.append("\n"); lines.append(line); line = []
            } else if s == "\n" {
                line.append("\n"); lines.append(line); line = []
            } else {
                line.append(s)
            }
            i += 1
        }
        if !line.isEmpty { lines.append(line) }

        var keys: [String] = []
        var values: [String: MSAValue?] = [:]
        func store(_ key: String, _ value: MSAValue?) {
            if values[key] == nil { keys.append(key) }
            values[key] = .some(value)
        }
        var y: [Double] = []
        var dataSection = false
        for line in lines {
            if !dataSection {
                guard line[0] == "#" else { continue }
                let parts = pySplit(line, pyText(": "))
                var key: PyText
                var value: PyText?
                if parts.count == 2 {
                    key = parts[0]
                    value = pyRstrip(parts[1])
                } else {
                    key = line
                    value = nil
                }
                let keyName = pyString(pyStrip(pyStripHash(key)))
                if keyName == "TITLE" || keyName == "COMMENT", values[keyName] != nil {
                    guard case .some(.text(let old)) = values[keyName], let value else { throw raises("a repeated \(keyName) line whose value is missing (TypeError)") }
                    store(keyName, .text(old + pyString(value)))
                } else if keyName != "SPECTRUM" {
                    store(keyName, value.map { .text(pyString($0)) })
                } else {
                    dataSection = true
                }
            } else if line[0] != "#" {
                // `line.replace(",", " ").strip().split()`: token ranges, converted one by one (a plain decimal through strtod,
                // anything else through the Python float rules).
                var tokens: [Range<Int>] = []
                var startOfToken: Int?
                for (k, scalar) in line.enumerated() {
                    if scalar == "," || pyIsSpace(scalar) {
                        if let st = startOfToken { tokens.append(st..<k); startOfToken = nil }
                    } else if startOfToken == nil {
                        startOfToken = k
                    }
                }
                if let st = startOfToken { tokens.append(st..<line.count) }
                if pyStrip(line).isEmpty { continue }   // `line.strip()` empty; a line of only separators still has no columns
                guard values["DATATYPE"] != nil else { throw raises("a data line before a DATATYPE keyword (KeyError)") }
                let datatype: String
                if case .some(.some(.text(let t))) = values["DATATYPE"] { datatype = t } else { continue }   // DATATYPE None: neither XY nor Y, nothing read
                func number(_ index: Int) throws -> Double {
                    guard index < tokens.count else { throw raises("a data line with too few columns (IndexError)") }
                    let token = tokens[index]
                    var plain = true
                    var buffer = [CChar](repeating: 0, count: token.count + 1)
                    for (k, scalar) in line[token].enumerated() {
                        switch scalar {
                        case "0"..."9", "+", "-", ".", "e", "E": buffer[k] = CChar(scalar.value)
                        default: plain = false
                        }
                        if !plain { break }
                    }
                    if plain {
                        var end: UnsafeMutablePointer<CChar>?
                        let v = buffer.withUnsafeMutableBufferPointer { p -> Double in
                            let r = strtod(p.baseAddress!, &end)
                            return end == p.baseAddress! + token.count ? r : .nan
                        }
                        // strtod reads a leading "e" or a bare "." as nothing (end short): those fall to the Python rules below.
                        if !(v.isNaN) { return v }
                    }
                    guard let v = formatoPythonFloat(pyString(Array(line[token]))) else { throw raises("the data value '\(pyString(Array(line[token])))' is not a float (ValueError)") }
                    return v
                }
                if datatype == "XY" {
                    y.append(try number(1))
                    if tokens.count > 2 { y.append(try number(3)) }
                } else if datatype == "Y" {
                    for index in tokens.indices { y.append(try number(index)) }
                }
            }
        }
        store("FORMAT", .text(msaFormatText))

        // Types and the mapping, in file order.
        var mapped: [(path: String, value: MSAValue, source: String)] = []
        for key in keys {
            var parameterValue = values[key]!
            var cleanName = key
            var units: String?
            if key.contains("-") {
                let pieces = pySplit(pyText(key), ["-"])
                guard pieces.count == 2 else { throw raises("the keyword '\(key)' holds more than one '-' (ValueError)") }
                cleanName = pyString(pyStrip(pieces[0]))
                units = pyString(pyStrip(pieces[1]))
            }
            guard case .some(.text(let text)) = parameterValue, !text.isEmpty, let keyword = msaKeywords.first(where: { $0.name == cleanName }) else { continue }
            if keyword.isNumber {
                if let v = formatoPythonFloat(text) {
                    parameterValue = .number(v)
                } else if text.lowercased().contains("e") {
                    if let v = formatoPythonFloat(text.replacingOccurrences(of: " ", with: "")) { parameterValue = .number(v) }
                } else if let v = formatoPythonFloat(String(text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)[0])) {
                    parameterValue = .number(v)
                }
                values[key] = .some(parameterValue)
            }
            if let path = keyword.mappedTo {
                mapped.append((path, parameterValue!, "#" + key))
                if let units { mapped.append((path + "_units", .text(units), "#" + key)) }
            }
        }

        func text(_ key: String) -> String? {
            if case .some(.some(.text(let t))) = values[key] { return t }
            return nil
        }
        var metadata = FormatoMetadata()
        func put(_ path: String, _ value: MSAValue, source: String, rule: String) {
            let v: FormatoValue
            switch value {
            case .text(let t): v = .text(t)
            case .number(let d): v = .number(d)
            }
            metadata.set(FormatoMetadataEntry(key: path, value: v, units: nil,
                                              provenance: FormatoProvenance(file: name, source: source, rule: rule)))
        }
        for m in mapped { put(m.path, m.value, source: m.source, rule: "rsciio msa keywords: mapped_to") }

        if let t = text("TIME"), !t.isEmpty {
            let pieces = t.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2 || pieces.count == 3 else { throw raises("TIME '\(t)' does not split into two or three parts (UnboundLocalError)") }
            if let iso = strptimeTime(t, seconds: pieces.count == 3) { put("General.time", .text(iso), source: "#TIME", rule: "rsciio msa: strptime %H:%M[:%S].isoformat()") }
        }
        if let d = text("DATE"), !d.isEmpty {
            let pieces = d.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if pieces.count == 3, let month = msaMonths.first(where: { $0.value == pieces[1].uppercased() })?.key,
               let iso = strptimeDate([pieces[0], month, pieces[2]].joined(separator: "-")) {
                put("General.date", .text(iso), source: "#DATE", rule: "rsciio msa: strptime %d-%b-%Y.isoformat()")
            }
        }
        func axisNumber(_ key: String, default fallback: Double) throws -> Double {
            guard values[key] != nil else { return fallback }
            guard case .some(.some(.number(let v))) = values[key] else { throw raises("\(key) is not a number the axis can carry (RosettaSciIO returns a string scale)") }
            return v
        }
        func axisText(_ key: String) -> String {
            if case .some(.some(.text(let t))) = values[key] { return t }
            return values[key] == nil ? "" : "None"
        }
        func axisName(_ key: String) -> String { values[key] == .some(nil) ? "" : axisText(key) }   // a keyword with no value: no name
        let axis = FormatoAxis(name: axisName("XLABEL"), size: y.count, scale: try axisNumber("XPERCHAN", default: 1),
                               offset: try axisNumber("OFFSET", default: 0), units: axisName("XUNITS"), navigate: false)
        if let fileName { put("General.original_filename", .text(formatoDisplayFileName(fileName)), source: "(the file name)", rule: "rsciio msa: os.path.split(filename)[1]") }

        // The signal type; EDS decides TEM or SEM from the first BEAMKV keyword.
        var signalType = ""
        if let st = text("SIGNALTYPE"), !st.isEmpty {
            if st == "ELS" { signalType = "EELS" } else if st == "CLS" { signalType = "CL" }
            if st == "EDS" {
                var beam: Double?
                if let key = keys.first(where: { $0.hasPrefix("BEAMKV") }) {
                    switch values[key]! {
                    case .some(.number(let v)): beam = v
                    case .some(.text(let t)):
                        guard let v = formatoPythonFloat(t) else { throw raises("\(key) is not a float (ValueError)") }
                        beam = v
                    case .none: throw raises("\(key) has no value (TypeError)")
                    }
                }
                signalType = "EDS" + ((beam ?? 0) > 30 && beam != nil ? "_TEM" : "_SEM")
            }
        }
        put("Signal.signal_type", .text(signalType), source: "#SIGNALTYPE", rule: "rsciio msa: ELS -> EELS, CLS -> CL, EDS -> EDS_TEM above 30 kV else EDS_SEM")
        var yunits = values["YUNITS"] != nil ? "(\(axisText("YUNITS")))" : ""
        let quantity: String
        if values["YLABEL"] != nil {
            quantity = axisText("YLABEL")
        } else if signalType == "EELS" {
            quantity = "Electrons"
            if yunits.isEmpty { yunits = "(Counts)" }
        } else if signalType.contains("EDS") {
            quantity = "X-rays"
            if yunits.isEmpty { yunits = "(Counts)" }
        } else {
            quantity = ""
        }
        if !quantity.isEmpty || !yunits.isEmpty {
            let q = pyString(pyStrip(pyText("\(quantity) \(yunits)")))
            put("Signal.quantity", .text(q), source: "#YLABEL/#YUNITS", rule: "rsciio msa: '{YLABEL} ({YUNITS})', Counts for EELS and EDS")
        }

        // DTBox's `to_dict` is a tree: a path's siblings follow its first appearance (General.original_filename joins General.title).
        func treeOrder(_ entries: [FormatoMetadataEntry], depth: Int) -> [FormatoMetadataEntry] {
            var heads: [String] = []
            for e in entries { let h = String(e.key.split(separator: ".", omittingEmptySubsequences: false)[depth]); if !heads.contains(h) { heads.append(h) } }
            return heads.flatMap { head -> [FormatoMetadataEntry] in
                let group = entries.filter { $0.key.split(separator: ".", omittingEmptySubsequences: false).count > depth
                    && String($0.key.split(separator: ".", omittingEmptySubsequences: false)[depth]) == head }
                let leaves = group.filter { $0.key.split(separator: ".", omittingEmptySubsequences: false).count == depth + 1 }
                return leaves + treeOrder(group.filter { $0.key.split(separator: ".", omittingEmptySubsequences: false).count > depth + 1 }, depth: depth + 1)
            }
        }
        metadata = FormatoMetadata(treeOrder(metadata.entries, depth: 0))
        var bytesOut = Data(capacity: y.count * 8)
        for v in y { withUnsafeBytes(of: v.bitPattern.littleEndian) { bytesOut.append(contentsOf: $0) } }
        let title = metadata["General.title"]?.value.text ?? ""
        let signal = FormatoSignal(title: title, signalType: signalType, axes: [axis], metadata: metadata,
                                   data: try FormatoArray(dataType: .float64, shape: [y.count], bytes: bytesOut))
        return MSASpectrum(signal: signal, parameters: keys.map { MSAParameter(key: $0, value: values[$0]!) })
    }
}

// MARK: writer

public nonisolated enum MSAWriter {
    /// RosettaSciIO's `file_writer(filename, signal, format, separator, encoding)` for a 1-D signal: the bytes it writes.
    /// `parameters` is the `original_metadata` of a spectrum read from an MSA file (its keywords are kept, in order); with
    /// nil the header is built from the signal's axis and metadata. `format` nil takes the file's own `DATATYPE`.
    public static func encode(_ signal: FormatoSignal, parameters: [MSAParameter]? = nil, format: MSADataFormat? = .y,
                              separator: String = ", ", encoding: MSAEncoding = .latin1, creator: String = "FormatoKit") throws -> Data {
        guard signal.axes.count == 1, signal.data.shape.count == 1 else {
            throw FormatoReadError.unsupported("The MSA writer takes a signal with one axis (RosettaSciIO uses axes[0] and iterates the data).")
        }
        var keys: [String] = []
        var loc: [String: MSAValue?] = [:]
        func set(_ key: String, _ value: MSAValue?) {
            if loc[key] == nil { keys.append(key) }
            loc[key] = .some(value)
        }
        var chosen = format
        let md = signal.metadata
        let kept = parameters.flatMap { p in p.contains { $0.key == "FORMAT" && $0.value == .text(msaFormatText) } ? p : nil }
        if let kept {
            for p in kept { set(p.key, p.value) }
            if let format { set("DATATYPE", .text(format.rawValue)) } else if case .some(.some(.text(let t))) = loc["DATATYPE"] {
                guard let f = MSADataFormat(rawValue: t) else { throw FormatoReadError.unsupported("format must be one of: None, 'XY' or 'Y' (RosettaSciIO raises).") }
                chosen = f
            }
        } else {
            chosen = format ?? .y
            if let date = md["General.date"]?.value.text {
                // `dt.strptime(date, "%Y-%m-%d").strftime("%d-%m-%Y")`, then the month's US abbreviation.
                guard let g = regexMatch("(\\d\\d\\d\\d)-(1[0-2]|0[1-9]|[1-9])-(3[0-1]|[1-2]\\d|0[1-9]|[1-9]| [1-9])", date),
                      let iso = strptimeDate("\(g[2].trimmingCharacters(in: .whitespaces))-\(g[1])-\(g[0])"),
                      let month = msaMonths[String(iso.dropFirst(5).prefix(2))] else {
                    throw FormatoReadError.unsupported("General.date '\(date)' is not %Y-%m-%d (RosettaSciIO raises).")
                }
                set("DATE", .text("\(iso.suffix(2))-\(month)-\(iso.prefix(4))"))
            }
            // RosettaSciIO tests `"General.item" in md` (a typo for `General.time`), so TIME is never written.
        }
        switch signal.signalType {
        case "EDS_SEM", "EDS_TEM": set("SIGNALTYPE", .text("EDS"))
        case "EELS": set("SIGNALTYPE", .text("ELS"))
        case "CL", "CL_SEM", "CL_STEM": set("SIGNALTYPE", .text("CLS"))
        case "EDS", "WDS", "ELS", "AES", "PES", "XRF", "CLS", "GAM": set("SIGNALTYPE", .text(signal.signalType))
        default: set("SIGNALTYPE", .text(""))
        }
        let axis = signal.axes[0]
        if loc["COMMENT"] == nil { set("COMMENT", .text("File created by \(creator)")) }
        // RosettaSciIO's reader gives an axis the Python ints 1 and 0 where the file has no XPERCHAN or OFFSET, and the writer then
        // prints "1" and "0"; a signal that did not come from a file has floats. A spectrum read here and not edited reproduces that.
        let hasKeyword = { (name: String) in kept?.contains { $0.key == name } ?? true }
        let scale: MSAValue = !hasKeyword("XPERCHAN") && axis.scale == 1 ? .text("1") : .number(axis.scale)
        let offset: MSAValue = !hasKeyword("OFFSET") && axis.offset == 0 && axis.offset.sign == .plus ? .text("0") : .number(axis.offset)
        let fromSignal: [(String, MSAValue)] = [
            ("FORMAT", .text(msaFormatText)), ("VERSION", .text("1.0")), ("TITLE", .text(md["General.title"]?.value.text ?? "")),
            ("DATE", .text("")), ("TIME", .text("")), ("OWNER", .text("")), ("NPOINTS", .text(String(axis.size))), ("NCOLUMNS", .text("1")),
            ("DATATYPE", .text((chosen ?? .y).rawValue)), ("SIGNALTYPE", .text("")), ("XPERCHAN", scale), ("OFFSET", offset), ("XLABEL", .text(axis.name ?? "")), ("XUNITS", .text(axis.units)),
        ]
        for (key, value) in fromSignal where loc[key] == nil || value != .text("") { set(key, value) }
        let sem = signal.signalType.contains("SEM")
        for keyword in msaKeywords {
            guard var path = keyword.mappedTo else { continue }
            if sem { path = path.replacingOccurrences(of: "TEM", with: "SEM") }
            if let entry = md[path] {
                switch entry.value {
                case .text(let t): set(keyword.name, .text(t))
                case .number(let d): set(keyword.name, .number(d))
                case .flag(let b): set(keyword.name, .text(b ? "True" : "False"))
                }
            }
        }
        guard let chosen else { throw FormatoReadError.unsupported("format must be one of: None, 'XY' or 'Y' (RosettaSciIO raises).") }

        var out = ""
        func line(_ key: String, _ value: String) {
            let padded = key.count < 12 ? key + String(repeating: " ", count: 12 - key.count) : key
            out += "#\(padded): \(value)\r\n"
        }
        func shown(_ v: MSAValue?) -> String {
            switch v {
            case .none: return "None"
            case .some(.text(let t)): return t
            case .some(.number(let d)): return pythonFloatString(d)
            }
        }
        keys.removeAll { $0 == "SPECTRUM" || $0 == "ENDOFDATA" }
        line("FORMAT", shown(loc["FORMAT"]!))
        line("VERSION", shown(loc["VERSION"]!))
        for key in keys where key != "FORMAT" && key != "VERSION" {
            let value = loc[key]!
            if case .some(.text(let t)) = value, key == "TITLE" || key == "COMMENT", !t.isEmpty {
                let scalars = Array(t.unicodeScalars)
                var start = 0
                while start < scalars.count {
                    var v = String.UnicodeScalarView()
                    v.append(contentsOf: scalars[start..<min(start + 64, scalars.count)])
                    line(key, String(v))
                    start += 64
                }
            } else {
                line(key, shown(value))
            }
        }
        line("SPECTRUM", "Spectral Data Starts Here")
        let counts = signal.data.doubles()
        switch chosen {
        case .xy:
            for (i, v) in counts.enumerated() { out += "\(cFormat("%g", axis.value(at: i)))\(separator)\(cFormat("%g", v))\r\n" }
        case .y:
            for v in counts { out += "\(cFormat("%f", v))\(separator)\r\n" }
        }
        out += "#ENDOFDATA   : End Of Data and File"
        switch encoding {
        case .utf8: return Data(out.utf8)
        case .latin1: return Data(out.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil })
        }
    }

    /// `encode`, then the file, replaced atomically.
    public static func write(_ signal: FormatoSignal, to url: URL, parameters: [MSAParameter]? = nil, format: MSADataFormat? = .y,
                             separator: String = ", ", encoding: MSAEncoding = .latin1) throws {
        try FormatoFileWrite.write(try encode(signal, parameters: parameters, format: format, separator: separator, encoding: encoding), to: url)
    }
}

/// Python's `'%f' % x` and `'%g' % x`: C's, with Python's spelling of nan and inf.
private nonisolated func cFormat(_ spec: String, _ x: Double) -> String {
    if x.isNaN { return "nan" }
    if x.isInfinite { return x < 0 ? "-inf" : "inf" }
    return String(format: spec, x)
}

/// Python's `str(float)`: the shortest representation that reads back, in Python's layout.
private nonisolated func pythonFloatString(_ x: Double) -> String {
    if x.isNaN { return "nan" }
    if x.isInfinite { return x < 0 ? "-inf" : "inf" }
    // Swift's description is the shortest round-trip digits; Python switches to an exponent below 1e-4 and from 1e16.
    let d = "\(x)"
    return d
}
