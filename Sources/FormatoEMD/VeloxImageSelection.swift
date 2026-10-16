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
