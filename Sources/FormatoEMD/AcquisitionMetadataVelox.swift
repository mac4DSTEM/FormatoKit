//
//  AcquisitionMetadataVelox.swift
//  What a Velox `.emd` records about the acquisition of one image entry (`VeloxImageInfo`, read through
//  `VeloxEMDReader.images()`), as `AcquisitionMetadata`.
//
//  `.rosettaSciIO` (default) follows RosettaSciIO 049e7d70 `emd/_emd_velox.py` `_get_mapping` (:934-948) where it maps a
//  field: `Optics.AccelerationVoltage` / 1e3 (kV), `Optics.CameraLength` * 1e3 (mm, in every mode),
//  `CustomProperties.StemMagnification.value` as the magnification (Velox stores an unset bool as 0; it is returned as
//  stored); no positivity rule. RosettaSciIO maps no detector, dwell, exposure, mode or date for an image; those are read
//  by the consumer's rule with `unvalidatedNote`: the detector `BinaryResult.Detector`, the instrument
//  `Instrument.InstrumentModel` (`.app`; under `.rosettaSciIO` it is `instrumentModel`, and `instrument` is RosettaSciIO's `InstrumentClass`), the dwell `Scan.DwellTime` only for a
//  ScanningDetector, the exposure of the detector the image names (`VeloxMetadata.exposureTimeSeconds`), the magnification
//  `Optics.NominalMagnification` when no `StemMagnification` is stored, the mode `Optics.OperatingMode` as the stored
//  code (an `.emd` stores a code, not a name), the start `Acquisition.AcquisitionStartDatetime` (Unix seconds shown on
//  the given zone's clock, as RosettaSciIO shows its time zone).
//
//  `.app` is the consumer's reading of the same entry, pinned to its source: high tension, detector, instrument, start
//  date and dwell only; magnification, camera length, exposure and mode are `unread` (the consumer's reader predated the
//  fields the kit now exposes), and the rules of AcquisitionMetadata.swift apply (absent or non-positive is nil).
//
//  THE DATE (rule e, for this format): Velox stores the start as Unix seconds, an instant whose writer's zone is not
//  stored. It is shown on the given zone's clock and the note names the zone.
//

import Foundation
import FormatoCore

nonisolated extension AcquisitionMetadata {
    /// The fields an `.emd` entry records, from the opened entry `entry`.
    public static func velox(_ entry: VeloxImageInfo, timeZone: TimeZone = .current,
                             convention: AcquisitionMetadataConvention = .rosettaSciIO) -> AcquisitionMetadata {
        var out = veloxApp(entry, timeZone: timeZone)
        guard convention == .rosettaSciIO else { return out }
        let m = entry.metadata
        out.unread = []
        out.highTensionKV = m.accelerationVoltageVolts.map { MetadataReading($0 / 1e3) }
        out.cameraLengthMM = m.cameraLengthMeters.map { MetadataReading($0 * 1e3) }
        if let stem = m.stemMagnification {
            out.magnification = MetadataReading(stem)
        } else if let nominal = positive(m.nominalMagnification) {
            out.magnification = MetadataReading(nominal, note: unvalidatedNote)
        }
        // The microscope is `Instrument.InstrumentClass` (`_get_mapping`, :947-950), as stored; the stored model is kept beside it.
        out.instrument = text(m.instrumentClass).map { MetadataReading($0) }
        out.instrumentModel = text(m.instrumentModel).map { MetadataReading($0, note: veloxUnvalidated) }
        // Stage: tilts are radians in the file and degrees rounded to 3 decimals in the mapping (:951-960); the position
        // is metres as stored, rounded to 6 decimals (:961-972). The position needs all three coordinates (VeloxMetadata).
        let degreesNote = "degrees from the stored radians, rounded to 3 decimals, as RosettaSciIO"
        out.stageTiltAlphaDeg = m.stageAlphaRadians.map { MetadataReading(pythonRound(numpyDegrees($0), 3), note: degreesNote) }
        out.stageTiltBetaDeg = m.stageBetaRadians.map { MetadataReading(pythonRound(numpyDegrees($0), 3), note: degreesNote) }
        let metresNote = "metres as stored, rounded to 6 decimals, as RosettaSciIO"
        if let p = m.stagePositionMeters {
            out.stageX = MetadataReading(pythonRound(p.x, 6), note: metresNote)
            out.stageY = MetadataReading(pythonRound(p.y, 6), note: metresNote)
            out.stageZ = MetadataReading(pythonRound(p.z, 6), note: metresNote)
        }
        if let seconds = positive(m.exposureTimeSeconds) { out.exposureS = MetadataReading(seconds, note: unvalidatedNote) }
        if let mode = text(m.operatingMode) {
            out.mode = MetadataReading(mode, note: "the stored code, not decoded; " + unvalidatedNote)
        }
        return out
    }

    static func veloxApp(_ entry: VeloxImageInfo, timeZone: TimeZone) -> AcquisitionMetadata {
        let m = entry.metadata
        var out = AcquisitionMetadata()
        out.unread = [.magnification, .cameraLength, .exposure, .mode]
        if let kv = positive(m.accelerationVoltageVolts.map { $0 / 1e3 }) {
            out.highTensionKV = MetadataReading(kv)
        }
        if let detector = text(m.binaryResultDetector) {
            out.detector = MetadataReading(detector, note: veloxDetectorNote)
        }
        if let model = text(m.instrumentModel) {
            out.instrument = MetadataReading(model, note: veloxUnvalidated)
        }
        if let seconds = m.acquisitionStartUnixTime, let shown = veloxStamp(seconds, timeZone: timeZone) {
            out.acquired = MetadataReading(shown, note: veloxClockNote(seconds, timeZone: timeZone))
        }
        if entry.detectorType == "ScanningDetector",
           let us = positive(m.dwellTimeSeconds.map { $0 * 1e6 }) {
            out.dwellUS = MetadataReading(us, note: veloxUnvalidated)
        }
        return out
    }

    static let veloxUnvalidated = "unvalidated: no published reader reads it"
    /// The registered clause failed (2026-10-13, velox-image-parity): RosettaSciIO's title comes from the file's
    /// Operations, not `BinaryResult.Detector`, and differs on 7 of 33 public and owner files ("Ceta" for "BM-Ceta").
    static let veloxDetectorNote = "unvalidated: RosettaSciIO names some detectors from another field"

    /// Unix seconds as `YYYY-MM-DD HH:MM:SS` on `timeZone`'s clock (whole seconds, truncated as RosettaSciIO's
    /// `isoformat` is); nil when not finite or out of the four-digit years.
    static func veloxStamp(_ seconds: Double, timeZone: TimeZone) -> String? {
        guard seconds.isFinite, abs(seconds) < 2.5e11 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: seconds.rounded(.down))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, (1...9999).contains(y), let mo = c.month, let d = c.day, let h = c.hour,
              let mi = c.minute, let s = c.second else { return nil }
        func pad(_ n: Int, _ width: Int) -> String {
            let digits = String(n)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(y, 4))-\(pad(mo, 2))-\(pad(d, 2)) \(pad(h, 2)):\(pad(mi, 2)):\(pad(s, 2))"
    }

    /// "a UTC instant, shown on this Mac's clock (CEST)": the zone the stamp is shown in, at that date.
    static func veloxClockNote(_ seconds: Double, timeZone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        let zone = timeZone.abbreviation(for: date) ?? timeZone.identifier
        return "a UTC instant, shown on this Mac's clock (\(zone)); the writer's zone is not stored"
    }
}
