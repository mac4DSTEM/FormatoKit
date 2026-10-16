//
//  AcquisitionPins.swift
//  Test support (not a product): reads tools/acq-metadata/generate.py's pins.json and compares an `AcquisitionMetadata` with
//  the pinned app output (every field, note and second copy) or with the pinned RosettaSciIO mapping.
//

import Foundation
import FormatoCore

public struct AcquisitionPinCase: @unchecked Sendable {
    public let name: String
    public let raw: [String: Any]
    public var reference: [String: Any] { raw["reference"] as? [String: Any] ?? [:] }
    public var app: [String: Any] { raw["app"] as! [String: Any] }
    public var numbers: [String: Double] { (raw["numbers"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:] }
    public var strings: [String: String] { raw["strings"] as? [String: String] ?? [:] }
}

public func loadAcquisitionPins(_ url: URL) throws -> [AcquisitionPinCase] {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return (root["cases"] as! [[String: Any]]).map { AcquisitionPinCase(name: $0["name"] as! String, raw: $0) }
}

private func pinReading(_ any: Any?) -> (value: Any, note: String?, otherCopy: Any?)? {
    guard let d = any as? [String: Any] else { return nil }
    return (d["value"]!, d["note"] as? String, d["otherCopy"] is NSNull ? nil : d["otherCopy"])
}

private func same(_ a: Any, _ b: Any?) -> Bool {
    guard let b else { return false }
    if let x = a as? Double { return (b as? NSNumber)?.doubleValue == x }
    if let x = a as? String { return b as? String == x }
    return false
}

private func compare<V: Sendable & Equatable>(_ r: MetadataReading<V>?, _ pin: Any?, _ field: String) -> String? {
    guard let p = pinReading(pin) else { return r == nil ? nil : "\(field): got \(r!), pinned nil" }
    guard let r else { return "\(field): got nil, pinned \(p)" }
    guard same(r.value, p.value) else { return "\(field): value \(r.value) vs \(p.value)" }
    guard r.note == p.note else { return "\(field): note \(String(describing: r.note)) vs \(String(describing: p.note))" }
    if let other = p.otherCopy { return same(r.otherCopy as Any, other) ? nil : "\(field): otherCopy" }
    return r.otherCopy == nil ? nil : "\(field): unexpected otherCopy"
}

/// Differences between `m` and the app's pinned output (empty when equal).
public func appDifferences(_ m: AcquisitionMetadata, _ pin: [String: Any]) -> [String] {
    var out: [String?] = [
        compare(m.highTensionKV, pin["highTensionKV"], "highTensionKV"), compare(m.magnification, pin["magnification"], "magnification"),
        compare(m.cameraLengthMM, pin["cameraLengthMM"], "cameraLengthMM"), compare(m.detector, pin["detector"], "detector"),
        compare(m.dwellUS, pin["dwellUS"], "dwellUS"), compare(m.exposureS, pin["exposureS"], "exposureS"),
        compare(m.acquired, pin["acquired"], "acquired"), compare(m.instrument, pin["instrument"], "instrument"),
        compare(m.mode, pin["mode"], "mode"),
    ]
    let unread = (pin["unread"] as? [String] ?? []).sorted()
    if m.unread.map(\.rawValue).sorted() != unread { out.append("unread: \(m.unread) vs \(unread)") }
    return out.compactMap { $0 }
}

/// The RosettaSciIO pins as the numbers they pin: nil where RosettaSciIO maps nothing.
public func referenceNumber(_ ref: [String: Any], _ key: String) -> Double? { (ref[key] as? NSNumber)?.doubleValue }
public func referenceText(_ ref: [String: Any], _ key: String) -> String? { ref[key] as? String }

/// Differences between `m` and RosettaSciIO's pinned mapping (`ref`, keys as `tools/acq-metadata/generate.py` writes them).
/// A key in `strict` must agree in presence too; any other key is compared only when RosettaSciIO maps it. The dwell
/// compares `dwellUS / 1e6` (RosettaSciIO divides the stored microseconds by 1e6); the stamp compares date + " " + time.
public func referenceDifferences(_ m: AcquisitionMetadata, _ ref: [String: Any], strict: Set<String>) -> [String] {
    var out: [String] = []
    func number(_ key: String, _ got: Double?) {
        let want = referenceNumber(ref, key)
        if want == nil, !strict.contains(key) { return }
        if got != want { out.append("\(key): got \(String(describing: got)), RosettaSciIO \(String(describing: want))") }
    }
    func text(_ key: String, _ got: String?) {
        let want = referenceText(ref, key)
        if want == nil, !strict.contains(key) { return }
        if got != want { out.append("\(key): got \(String(describing: got)), RosettaSciIO \(String(describing: want))") }
    }
    number("beam_energy", m.highTensionKV?.value)
    number("camera_length", m.cameraLengthMM?.value)
    number("magnification", m.magnification?.value)
    number("dwell_time", m.dwellUS.map { $0.value / 1e6 })
    number("exposure", m.exposureS?.value)
    text("acquisition_mode", m.mode?.value)
    text("microscope", m.instrument?.value)
    let want: String? = if let date = referenceText(ref, "General.date"), let time = referenceText(ref, "General.time") { date + " " + time } else { nil }
    if want != nil || strict.contains("stamp"), m.acquired?.value != want {
        out.append("stamp: got \(String(describing: m.acquired?.value)), RosettaSciIO \(String(describing: want))")
    }
    return out
}
