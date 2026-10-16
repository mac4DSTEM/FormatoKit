//
//  VeloxImageSelection.swift
//  Which detector an image entry of a Velox `.emd` was acquired with.
//

import Foundation

extension VeloxImageInfo {
    /// The detector an entry was acquired with: the table entry its `BinaryResult.DetectorIndex` names, unless the entry's
    /// own `BinaryResult.Detector` names a different table entry, then that one (RosettaSciIO's `1854 Camera Ceta.emd`, a
    /// Velox 4 file, has index 0 = the BF detector while the image is the BM-Ceta camera's). nil when the index is absent
    /// or not in the table.
    public var resolvedDetector: VeloxDetectorInfo? {
        let table = metadata.detectors
        guard let index = metadata.binaryResultDetectorIndex,
              let byIndex = table.first(where: { $0.index == index }) else { return nil }
        if detectorName.isEmpty || byIndex.name == detectorName { return byIndex }
        return table.first(where: { $0.name == detectorName }) ?? byIndex
    }

    /// The type of the resolved detector ("ScanningDetector", "ImagingDetector", "AnalyticalDetector"), nil when unresolved.
    public var detectorType: String? { resolvedDetector?.type }
}

/// The first consumer's rule for which image of a Velox file to show, and its axes: the named option beside
/// `VeloxImageSignals` (which, as RosettaSciIO does, returns every image). Pinned to the consumer's source (macTEM
/// cb6e164 VeloxImageReader.swift, compiled unchanged by tools/acq-metadata/generate.py).
///
/// OBJECT RULE: a candidate is an entry of `VeloxEMDReader.images()` whose `BinaryResult.DetectorIndex` resolves in the
/// file's detector table (to the entry the image's own `BinaryResult.Detector` names when the indexed one is another,
/// `VeloxImageInfo.resolvedDetector`), to a detector whose type is not "AnalyticalDetector" (an EDX map), and whose stored
/// type a float read can take (not Velox's compound FFT and DPC images). The first candidate whose detector is named "HAADF"
/// is chosen, else the first in the file's key order; with none the choice is nil. A name test alone would open the EDX
/// maps of a file whose detectors carry no DetectorIndex.
///
/// AXES, as stored: x from `PixelSize.width` in `PixelUnitX`, y from `PixelSize.height` in `PixelUnitY`, the unit strings
/// unnormalised ("m"); origin = -Offset / PixelSize per axis (no Offset: 0); an absent, non-finite or non-positive size
/// leaves that axis nil. DIFFERENCE from RosettaSciIO (and `VeloxImageSignals`): the y unit comes from `PixelUnitY`
/// only, where RosettaSciIO uses `PixelUnitX` for both; and the axis is an origin in pixels, where RosettaSciIO's is an
/// offset in units (`offset = -origin * scale`).
public nonisolated enum VeloxImageSelection {
    /// The type a Velox detector table gives an EDX detector.
    public static let analyticalDetectorType = "AnalyticalDetector"

    /// An imaging detector's entry, of a type a float read takes.
    public static func isCandidate(_ entry: VeloxImageInfo) -> Bool {
        guard entry.elementType != nil, let detector = entry.resolvedDetector else { return false }
        return detector.type != analyticalDetectorType
    }

    /// The entry the consumer opens: the first "HAADF" candidate, else the first candidate; nil with none.
    public static func choose(_ entries: [VeloxImageInfo]) -> VeloxImageInfo? {
        let candidates = entries.filter(isCandidate)
        return candidates.first { $0.detectorName == "HAADF" } ?? candidates.first
    }

    /// One axis as the consumer reads it: the physical value at pixel index `i` is `(i - origin) * scale`.
    public struct Axis: Sendable, Equatable {
        public let origin: Double
        public let scale: Double
        /// As stored; empty when the file names none (uncalibrated).
        public let units: String

        public init(origin: Double, scale: Double, units: String) {
            self.origin = origin; self.scale = scale; self.units = units
        }
    }

    /// The consumer's x and y axes of `entry`.
    public static func axes(of entry: VeloxImageInfo) -> (x: Axis?, y: Axis?) {
        let m = entry.metadata
        let size = m.pixelSizeMeters
        return (axis(size: size?.width, unit: m.pixelUnit, offset: m.offset?.x),
                axis(size: size?.height, unit: m.pixelUnitY, offset: m.offset?.y))
    }

    static func axis(size: Double?, unit: String?, offset: Double?) -> Axis? {
        guard let size, size.isFinite, size > 0 else { return nil }
        // `+ 0` makes the origin of a zero or absent Offset +0, not -0.
        return Axis(origin: -(offset ?? 0) / size + 0, scale: size, units: unit ?? "")
    }
}
