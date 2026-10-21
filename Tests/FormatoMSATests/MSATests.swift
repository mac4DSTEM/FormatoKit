import Testing
import Foundation
import FormatoCore
import FormatoMSA

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private func pins() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("msa-pins.json"))) as? [String: Any])
}

private func bits(_ hex: String) -> UInt64 {
    var value: UInt64 = 0
    let bytes = stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
    for (i, b) in bytes.enumerated() { value |= UInt64(b) << (8 * UInt64(i)) }
    return value
}

private func double(_ enc: Any?) -> Double? {
    guard let e = enc as? [String: Any], let h = e["f"] as? String else { return nil }
    return Double(bitPattern: bits(h))
}

/// RosettaSciIO's `msa.file_reader` against `MSAReader`: data bits, the axis, the mapped metadata in order, the keywords in order.
@Test func readEqualsRosettaSciIO() throws {
    let all = try pins()
    let reads = try #require(all["read"] as? [String: [String: Any]])
    let texts = try #require(all["texts"] as? [String: String])
    #expect(reads.count == 77)
    for (name, want) in reads.sorted(by: { $0.key < $1.key }) {
        let bytes: Data
        let fileName: String
        if let b64 = texts[name] {
            bytes = try #require(Data(base64Encoded: b64)); fileName = name + ".msa"
        } else {
            bytes = try Data(contentsOf: fixtures.appendingPathComponent(name)); fileName = (name as NSString).lastPathComponent
        }
        let axisScale = ((want["axis"] as? [String: Any])?["scale"] as? [String: Any])
        let axisOffset = ((want["axis"] as? [String: Any])?["offset"] as? [String: Any])
        if want["raises"] != nil || axisScale?["f"] == nil || axisOffset?["f"] == nil {
            // RosettaSciIO raises, or returns a string scale or offset that HyperSpy cannot use: refused here.
            #expect(throws: FormatoReadError.self, Comment(rawValue: name)) { _ = try MSAReader.parse(bytes: bytes, fileName: fileName) }
            continue
        }
        let got = try MSAReader.parse(bytes: bytes, fileName: fileName)
        let data = try #require(want["data"] as? [String])
        #expect(got.signal.data.shape == [data.count], Comment(rawValue: name))
        #expect(got.signal.data.dataType == .float64)
        #expect(got.signal.data.doubles().map(\.bitPattern) == data.map(bits), Comment(rawValue: name))
        let axis = got.signal.axes[0]
        let wantAxis = try #require(want["axis"] as? [String: Any])
        #expect(axis.size == wantAxis["size"] as? Int && axis.name == wantAxis["name"] as? String && axis.units == wantAxis["units"] as? String, Comment(rawValue: name))
        #expect(axis.scale.bitPattern == double(wantAxis["scale"])?.bitPattern && axis.offset.bitPattern == double(wantAxis["offset"])?.bitPattern, Comment(rawValue: name))
        #expect(!axis.navigate)
        // metadata, in order
        let md = try #require(want["metadata"] as? [[Any]])
        #expect(got.signal.metadata.keys == md.map { $0[0] as! String }, Comment(rawValue: "\(name): metadata keys"))
        for pair in md {
            let key = pair[0] as! String
            let entry = try #require(got.signal.metadata[key])
            if let s = (pair[1] as? [String: Any])?["s"] as? String { #expect(entry.value == .text(s), Comment(rawValue: "\(name) \(key)")) }
            else if let d = double(pair[1]) { #expect(entry.value.number?.bitPattern == d.bitPattern, Comment(rawValue: "\(name) \(key)")) }
        }
        #expect(got.signal.signalType == (md.first { ($0[0] as! String) == "Signal.signal_type" }.flatMap { ($0[1] as? [String: Any])?["s"] as? String }))
        // keywords, in order
        let original = try #require(want["original"] as? [[Any]])
        #expect(got.parameters.map(\.key) == original.map { $0[0] as! String }, Comment(rawValue: "\(name): keywords"))
        for (p, pair) in zip(got.parameters, original) {
            if pair[1] is NSNull { #expect(p.value == nil, Comment(rawValue: "\(name) \(p.key)")) }
            else if let s = (pair[1] as? [String: Any])?["s"] as? String { #expect(p.value == .text(s), Comment(rawValue: "\(name) \(p.key)")) }
            else if let d = double(pair[1]) { #expect({ if case .number(let v) = p.value { return v.bitPattern == d.bitPattern }; return false }(), Comment(rawValue: "\(name) \(p.key)")) }
        }
    }
}

private let creator = "RosettaSciIO version 0.14.1.dev96+g049e7d707"

/// RosettaSciIO's `file_writer` bytes against `MSAWriter.encode` for spectra RosettaSciIO read (keywords kept) and for synthetic signals.
@Test func writeEqualsRosettaSciIO() throws {
    let all = try pins()
    #expect(all["rsciio"] as? String == "0.14.1.dev96+g049e7d707")
    let writes = try #require(all["write"] as? [String: [String: String]])
    let texts = try #require(all["texts"] as? [String: String])
    #expect(writes.count > 100)
    for (key, want) in writes.sorted(by: { $0.key < $1.key }) {
        let parts = key.split(separator: "|").map(String.init)
        let name = parts[0], label = parts[1]
        let bytes: Data
        if let b64 = texts[name] { bytes = try #require(Data(base64Encoded: b64)) } else { bytes = try Data(contentsOf: fixtures.appendingPathComponent(name)) }
        let spectrum = try MSAReader.parse(bytes: bytes, fileName: (name as NSString).lastPathComponent)
        let format: MSADataFormat? = label == "None" ? nil : (label.hasSuffix("XY") ? .xy : .y)
        let keepKeywords = !label.hasPrefix("noorig")
        if want["raises"] != nil {
            #expect(throws: FormatoReadError.self, Comment(rawValue: key)) {
                _ = try MSAWriter.encode(spectrum.signal, parameters: keepKeywords ? spectrum.parameters : nil, format: format, separator: ", ", creator: creator)
            }
            continue
        }
        let got = try MSAWriter.encode(spectrum.signal, parameters: keepKeywords ? spectrum.parameters : nil, format: format,
                                       separator: label == "sep" ? "; " : ", ", creator: creator)
        let b64 = try #require(want["b64"])
        let expected = try #require(Data(base64Encoded: b64), Comment(rawValue: key))
        if got != expected {
            let a = String(decoding: got, as: UTF8.self).components(separatedBy: "\r\n"), b = String(decoding: expected, as: UTF8.self).components(separatedBy: "\r\n")
            let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }
            Issue.record("\(key): first difference at line \(first?.offset ?? -1): got \(first?.element.0 ?? "<end>") / want \(first?.element.1 ?? "<end>"); \(a.count) vs \(b.count) lines")
        }
    }
    let synthetic = try #require(all["synthetic"] as? [String: [String: Any]])
    for (name, s) in synthetic.sorted(by: { $0.key < $1.key }) {
        let dtype = try #require(s["dtype"] as? String)
        let values = (s["data"] as! [String]).map { Double(bitPattern: bits($0)) }
        let array: FormatoArray
        var raw = Data()
        if dtype == "float32" { for v in values { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { raw.append(contentsOf: $0) } }; array = try FormatoArray(dataType: .float32, shape: [values.count], bytes: raw) }
        else if dtype == "int32" { for v in values { withUnsafeBytes(of: Int32(v).littleEndian) { raw.append(contentsOf: $0) } }; array = try FormatoArray(dataType: .int32, shape: [values.count], bytes: raw) }
        else { for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { raw.append(contentsOf: $0) } }; array = try FormatoArray(dataType: .float64, shape: [values.count], bytes: raw) }
        let a = s["axis"] as! [String: Any]
        let axis = FormatoAxis(name: a["name"] as? String, size: a["size"] as! Int, scale: double(a["scale"])!, offset: double(a["offset"])!, units: a["units"] as! String, navigate: false)
        var md = FormatoMetadata()
        for pair in s["metadata"] as! [[Any]] {
            let key = pair[0] as! String
            if let t = (pair[1] as? [String: Any])?["s"] as? String { md.set(FormatoMetadataEntry(key: key, value: .text(t), units: nil, provenance: FormatoProvenance(file: "t", source: "t", rule: "t"))) }
            else if let d = double(pair[1]) { md.set(FormatoMetadataEntry(key: key, value: .number(d), units: nil, provenance: FormatoProvenance(file: "t", source: "t", rule: "t"))) }
        }
        let signal = FormatoSignal(title: md["General.title"]?.value.text ?? "", signalType: s["signal_type"] as! String, axes: [axis], metadata: md, data: array)
        let outs = try #require(s["write"] as? [String: [String: String]])
        for (label, want) in outs.sorted(by: { $0.key < $1.key }) {
            let format: MSADataFormat? = label == "None" ? nil : (label == "XY" ? .xy : (label == "bad" ? nil : .y))
            if label == "bad" { #expect(want["raises"] == "ValueError"); continue }
            if want["raises"] != nil {
                #expect(throws: FormatoReadError.self, Comment(rawValue: "\(name) \(label)")) { _ = try MSAWriter.encode(signal, format: format, creator: creator) }
                continue
            }
            let got = try MSAWriter.encode(signal, format: format, encoding: label == "utf8" ? .utf8 : .latin1, creator: creator)
            let b64 = try #require(want["b64"])
            let expected = try #require(Data(base64Encoded: b64), Comment(rawValue: "\(name) \(label)"))
            #expect(got == expected, Comment(rawValue: "\(name) \(label): \(String(decoding: got, as: UTF8.self).prefix(400))"))
        }
    }
}

/// Typed by hand from the standard's rules, not from the pins.
@Test func plantedLiterals() throws {
    let text = "#FORMAT      : EMSA/MAS Spectral Data File\r\n#VERSION     : 1.0\r\n#TITLE       : Cu\r\n#DATE        : 21-MAR-2017\r\n#TIME        : 10:57\r\n"
        + "#SIGNALTYPE  : EDS\r\n#BEAMKV -kV   : 200.\r\n#XPERCHAN    : 10\r\n#OFFSET      : -5\r\n#XUNITS      : eV\r\n#DATATYPE    : XY\r\n#SPECTRUM    : Spectral Data Starts Here\r\n-5, 7\r\n5, 8, 15, 9\r\n#ENDOFDATA   : End Of Data and File"
    let s = try MSAReader.parse(bytes: Data(text.utf8), fileName: "/tmp/cu.msa").signal
    #expect(s.title == "Cu" && s.signalType == "EDS_TEM")
    #expect(s.data.doubles() == [7, 8, 9])
    #expect(s.axes == [FormatoAxis(name: "", size: 3, scale: 10, offset: -5, units: "eV", navigate: false)])
    #expect(s.metadata["General.date"]?.value.text == "2017-03-21" && s.metadata["General.time"]?.value.text == "10:57:00")
    #expect(s.metadata["Acquisition_instrument.TEM.beam_energy"]?.value.number == 200)
    #expect(s.metadata["Acquisition_instrument.TEM.beam_energy_units"]?.value.text == "kV")
    #expect(s.metadata["Signal.quantity"]?.value.text == "X-rays (Counts)")
    #expect(s.metadata["General.original_filename"]?.value.text == "cu.msa")
    // The header names the creator and wraps the title at 64 characters.
    let out = try MSAWriter.encode(s, format: .y, creator: "test")
    let lines = String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n")
    #expect(lines.first == "#FORMAT      : EMSA/MAS Spectral Data File" && lines.last == "#ENDOFDATA   : End Of Data and File")
    #expect(lines.contains("7.000000, "))
}
