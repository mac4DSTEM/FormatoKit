//
//  VeloxReadPolicy.swift
//  Role: FormatoKit's own policies for the Velox readers (docs/registration-0.2.0.md §1): each is a choice FormatoKit makes where
//        RosettaSciIO raises or where a memory limit applies, as a parameter whose default is the 0.1.1 behaviour. A non-default
//        path that changes the result adds one metadata entry under `FormatoMetadata.policyKeyPrefix`, whose rule begins
//        "FormatoKit policy, not RosettaSciIO's", only when that branch fired (§2).
//

import Foundation
import FormatoCore

/// Which grid a spectrum image is decoded onto (registration 0.2.0 P2).
public nonisolated enum VeloxGridChoice: Sendable, Equatable {
    /// The first image's grid, refused where the stream's ScanSize x ScanArea gives another (registration step 4 §3.3): the default.
    case firstImageChecked
    /// The first image's grid with no check: RosettaSciIO's own reading. A stream whose ScanSize x ScanArea gives another grid
    /// is then decoded with the first image's, and the result says so.
    case firstImage
    /// The grid the stream's ScanSize x ScanArea gives, where it gives one, else the first image's: not RosettaSciIO's number.
    case scanSizeTimesArea
}

/// FormatoKit's policies for reading a Velox file (registration 0.2.0 §1). `VeloxReadPolicy()` is the 0.1.1 behaviour.
public nonisolated struct VeloxReadPolicy: Sendable, Equatable {
    /// P1: a pixel unit FormatoUnits does not handle (default: refuse the image).
    public var unconvertedUnits: FormatoUnconvertedUnits
    /// P2: the grid a spectrum image is decoded onto (default: the first image's, checked).
    public var spectrumImageGrid: VeloxGridChoice
    /// P3: the largest spectrum-image array one read allocates, in bytes; nil is this machine's physical memory.
    public var maximumArrayBytes: Int?
    /// P8: values per block of the stream read. No result depends on it.
    public var streamBlockValues: Int

    public init(unconvertedUnits: FormatoUnconvertedUnits = .refuse, spectrumImageGrid: VeloxGridChoice = .firstImageChecked,
                maximumArrayBytes: Int? = nil, streamBlockValues: Int = 32 << 20) {
        self.unconvertedUnits = unconvertedUnits
        self.spectrumImageGrid = spectrumImageGrid
        self.maximumArrayBytes = maximumArrayBytes
        self.streamBlockValues = streamBlockValues
    }

    /// The array limit in bytes: `maximumArrayBytes`, or the machine's memory (RosettaSciIO's `np.zeros` raises beyond what it
    /// can map), never beyond `Int.max` and never negative.
    var arrayByteLimit: Int {
        max(0, min(maximumArrayBytes ?? Int(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int.max))), Int.max))
    }

    /// Values per block, at least 1.
    var blockValues: Int { max(1, streamBlockValues) }
}

/// A policy metadata entry: `FormatoKit.policy.<name>`, a text value, its provenance rule beginning with the policy prefix.
nonisolated func veloxPolicyEntry(_ name: String, value: String, file: String, source: String, rule: String) -> FormatoMetadataEntry {
    FormatoMetadataEntry(key: FormatoMetadata.policyKeyPrefix + name, value: .text(value), units: nil,
                         provenance: FormatoProvenance(file: file, source: source, rule: FormatoMetadata.policyRulePrefix + ": " + rule))
}

/// The pixel calibration of a Velox image or stream: RosettaSciIO's `_convert_scale_units` on the width, the same unit for the
/// height and both offsets (the arithmetic of 0.1.1), or, under `FormatoUnconvertedUnits.keepAsWritten`, the file's numbers.
nonisolated struct VeloxPixelCalibration {
    let scaleX: Double, offsetX: Double, scaleY: Double, offsetY: Double
    let units: String
    /// True when the unit is not one FormatoUnits handles and the numbers are the file's, with the unit as written.
    let keptAsWritten: Bool

    /// nil where the calibration is refused: a unit not handled (under `.refuse`), or one Pint raises on (under every policy).
    static func make(width: Double, height: Double, offsetX: Double, offsetY: Double, unit: String, factor: Int,
                     policy: VeloxReadPolicy) -> VeloxPixelCalibration? {
        switch FormatoUnits.scaleOutcome(width, units: unit, factor: factor) {
        case .converted(let value, let units):
            guard let scaleY = FormatoUnits.convertUnits(height, from: unit, to: units),
                  let ox = FormatoUnits.convertUnits(offsetX, from: unit, to: units),
                  let oy = FormatoUnits.convertUnits(offsetY, from: unit, to: units) else { return nil }
            return VeloxPixelCalibration(scaleX: value, offsetX: ox, scaleY: scaleY, offsetY: oy, units: units, keptAsWritten: false)
        case .unhandledUnit where policy.unconvertedUnits == .keepAsWritten:
            return VeloxPixelCalibration(scaleX: width, offsetX: offsetX, scaleY: height, offsetY: offsetY, units: unit, keptAsWritten: true)
        case .unhandledUnit, .pintRaises:
            return nil
        }
    }

    /// The flag entry for a kept unit (registration 0.2.0 §2): the unit as written.
    static func entry(unit: String, file: String, source: String) -> FormatoMetadataEntry {
        veloxPolicyEntry("units", value: unit, file: file, source: source,
                         rule: "unconvertedUnits = keepAsWritten: the pixel unit '\(unit)' is not one FormatoUnits converts; the axes carry the file's numbers (float() only, no compacting) and the unit as written")
    }
}
