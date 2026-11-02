//
//  AcquisitionMetadataVelox.swift
//  What a Velox `.emd` records about the acquisition of one image entry (`VeloxImageInfo`, read through
//  `VeloxEMDReader.images()`), as `AcquisitionMetadata`.
//
//  `.rosettaSciIO` (default) follows RosettaSciIO 049e7d70 `emd/_emd_velox.py` `_get_mapping` (:934-948) where it maps a
//  field: `Optics.AccelerationVoltage` / 1e3 (kV), `Optics.CameraLength` * 1e3 (mm, in every mode),
//  `CustomProperties.StemMagnification.value` as the magnification (Velox stores an unset bool as 0; it is returned as
//  stored); no positivity rule. RosettaSciIO maps no detector, dwell, exposure, mode or date for an image; those are read
//  by the consumer's rule with `veloxUnvalidated` (no published reader; read as stored): the detector `BinaryResult.Detector`, the instrument
//  `Instrument.InstrumentModel` (`.app`; under `.rosettaSciIO` it is `instrumentModel`, and `instrument` is RosettaSciIO's `InstrumentClass`), the dwell `Scan.DwellTime` only for a
//  ScanningDetector, the exposure of the detector the image names (`VeloxMetadata.exposureTimeSeconds`), the magnification
//  `Optics.NominalMagnification` when no `StemMagnification` is stored, the mode `Optics.OperatingMode` as the stored
//  code (an `.emd` stores a code, not a name), the start `Acquisition.AcquisitionStartDatetime` (Unix seconds shown on
//  the given zone's clock, as RosettaSciIO shows its time zone).
//
//  FormatoKit 0.11.0 adds `pixelSize` (`BinaryResult.PixelSize` in its stated unit; RosettaSciIO uses it as the axis scale, so
//  the note says it is not a metadata mapping) under `.rosettaSciIO`, and `velox(spectrumImage:)`, the same fields for the metadata
//  of a spectrum image (`VeloxEMDReader.spectrumImageMetadata()`). `velox(eelsSpectrumImage:)` reads the same fields from one EELS
//  spectrum image's metadata (`VeloxEMDReader.eelsSpectrumImageMetadata()`) plus the collection and convergence semi-angles, where
//  RosettaSciIO maps nothing (the collection angle as pyEELSMODEL reads it; the convergence angle noted as read by no published reader).
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
            out.magnification = MetadataReading(nominal, note: veloxUnvalidated)
        }
        // The microscope is `Instrument.InstrumentClass` (`_get_mapping`, :947-950), as stored; the stored model is kept beside it.
        out.instrument = m.instrumentClass.map { MetadataReading($0) }   // as stored, as RosettaSciIO passes it
        out.instrumentModel = text(m.instrumentModel).map { MetadataReading($0, note: veloxUnvalidated) }
        // Stage: tilts are radians in the file and degrees rounded to 3 decimals in the mapping (:951-960); the position
        // is metres as stored, rounded to 6 decimals (:961-972). Each position coordinate is read alone, as the mapping reads it.
        let degreesNote = "degrees from the stored radians, rounded to 3 decimals, as RosettaSciIO"
        out.stageTiltAlphaDeg = m.stageAlphaRadians.map { MetadataReading(roundLikePython(degreesLikeNumPy($0), 3), note: degreesNote) }
        out.stageTiltBetaDeg = m.stageBetaRadians.map { MetadataReading(roundLikePython(degreesLikeNumPy($0), 3), note: degreesNote) }
        let metresNote = "metres as stored, rounded to 6 decimals, as RosettaSciIO"
        out.stageX = m.stageXMeters.map { MetadataReading(roundLikePython($0, 6), note: metresNote) }
        out.stageY = m.stageYMeters.map { MetadataReading(roundLikePython($0, 6), note: metresNote) }
        out.stageZ = m.stageZMeters.map { MetadataReading(roundLikePython($0, 6), note: metresNote) }
        // The pixel size at the specimen: RosettaSciIO's axis scale, `PixelUnitX` for both axes as it reads them (rows from the
        // height, columns from the width). A pixel size that is not a finite positive number is no calibration (nil).
        if let size = m.pixelSizeMeters, size.width.isFinite, size.width > 0, size.height.isFinite, size.height > 0,
           case let unit = text(m.pixelUnit) ?? "" {   // a missing PixelUnitX is "" in RosettaSciIO (`.get("PixelUnitX", "")`): scale kept
            var note = "BinaryResult.PixelSize, as stored; RosettaSciIO reads it as the axis scale, not as metadata"
            if let unitY = text(m.pixelUnitY), unitY != unit { note += "; PixelUnitY is '\(unitY)', RosettaSciIO uses PixelUnitX for both" }
            out.pixelSize = MetadataReading(PixelSize(rows: size.height, columns: size.width, units: unit), note: note)
        }
        if let seconds = positive(m.exposureTimeSeconds) { out.exposureS = MetadataReading(seconds, note: veloxUnvalidated) }
        if let mode = text(m.operatingMode) {
            out.mode = MetadataReading(mode, note: "the stored code, not decoded; " + veloxUnvalidated)
        }
        return out
    }

    /// The fields a spectrum image's own metadata records (`VeloxEMDReader.spectrumImageMetadata()`, or the first stream's), under
    /// the same rules as an image entry's: high tension, magnification, camera length, instrument, stage, pixel size, start date.
    /// The detector is the one `BinaryResult.Detector` names; a dwell is read only where the detector table says the detector is a
    /// ScanningDetector, so an EDS spectrum image gives none.
    public static func velox(spectrumImage metadata: VeloxMetadata, timeZone: TimeZone = .current,
                             convention: AcquisitionMetadataConvention = .rosettaSciIO) -> AcquisitionMetadata {
        velox(VeloxImageInfo(id: "", detectorName: metadata.binaryResultDetector ?? "", height: 0, width: 0, frameCount: 0,
                             elementType: nil, metadata: metadata), timeZone: timeZone, convention: convention)
    }

    /// The fields one EELS spectrum image's metadata records (`VeloxEMDReader.eelsSpectrumImageMetadata()`): those of
    /// `velox(spectrumImage:)`, among them the beam energy `Optics.AccelerationVoltage` / 1e3 (kV, RosettaSciIO's mapping for
    /// the EDS signal of the same file; pyEELSMODEL's `emd_reader` reads the same volts as E0), and the two angles in mrad:
    /// the collection semi-angle `EnergyFilter.CollectionAngleRange.End` × 1e3 (pyEELSMODEL's beta, radians as stored) and
    /// the convergence semi-angle `Optics.BeamConvergence` × 1e3 (no published reader reads it; noted so). An angle that is
    /// not a finite positive number is nil (pyEELSMODEL passes a stored 0 through as beta; here 0 is no collection angle). The
    /// angles are read under `.rosettaSciIO` only; `.app` gives what `velox(spectrumImage:)` gives.
    public static func velox(eelsSpectrumImage metadata: VeloxMetadata, timeZone: TimeZone = .current,
                             convention: AcquisitionMetadataConvention = .rosettaSciIO) -> AcquisitionMetadata {
        var out = velox(spectrumImage: metadata, timeZone: timeZone, convention: convention)
        guard convention == .rosettaSciIO else { return out }
        if let beta = positive(metadata.collectionAngleEndRadians) {
            out.collectionAngleMrad = MetadataReading(beta * 1e3, note: "EnergyFilter.CollectionAngleRange.End in radians × 1e3, the beta pyEELSMODEL's emd_reader reads")
        }
        if let alpha = positive(metadata.beamConvergenceRadians) {
            out.convergenceAngleMrad = MetadataReading(alpha * 1e3, note: "Optics.BeamConvergence in radians × 1e3; " + veloxUnvalidated)
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

    /// This format's wording of `noPublishedReaderNote`: the value is read as the Velox metadata stores it.
    static let veloxUnvalidated = "no published reader reads this field; read as stored in the Velox metadata"
    /// RosettaSciIO's title comes from the file's Operations, not `BinaryResult.Detector`, and differs on 7 of 33 public
    /// and owner files ("Ceta" for "BM-Ceta").
    static let veloxDetectorNote = "read from BinaryResult.Detector; RosettaSciIO names some detectors from another field"

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
