//
//  TIFFReadOptions.swift
//  Role: the policies of the TIFF reader that FormatoKit chose, as parameters whose defaults are the 0.1.1 behaviour.
//

import Foundation

/// What to do with a TIFF that carries the tags of a vendor branch the reader does not port.
public nonisolated enum TIFFVendorBranches: Sendable, Equatable {
    /// Refuse the file by naming the branch (Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu streak). The default.
    case refuse
    /// Read the file through the generic page path, as a TIFF without the vendor's tags is read: the axes come from the
    /// standard tags only, and the signal carries the metadata entry `FormatoKit.policy.vendor_branch` naming the branch.
    /// Layout refusals (compression, tiles, unsupported sample layouts) still refuse.
    case readAsGeneric
}

/// The options of `TIFFSignals.init(path:options:)`. The defaults give exactly the behaviour of `TIFFSignals.init(path:)`.
public nonisolated struct TIFFReadOptions: Sendable, Equatable {
    public var vendorBranches: TIFFVendorBranches
    /// Read the pixel size of a Velox TIFF from its XML (tag 34683, ``TIFFVeloxCalibration``), as the first consumer does.
    /// RosettaSciIO reads no such calibration, so the default (false) leaves the axes uncalibrated, as it does. A refused
    /// or disagreeing calibration leaves the default axes and adds the metadata entry `FormatoKit.policy.velox_calibration`.
    public var veloxCalibration: Bool

    public init(vendorBranches: TIFFVendorBranches = .refuse, veloxCalibration: Bool = false) {
        self.vendorBranches = vendorBranches
        self.veloxCalibration = veloxCalibration
    }
}
