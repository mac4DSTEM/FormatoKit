//
//  DM4Error.swift
//  Role: The error type of the GMS `.dm4` readers (`DM4Reader`, `DM4Experiment`).
//        Split out of DM4Reader.swift so it can move with
//        `DM4Experiment`; declaration unchanged.
//

import Foundation

public enum DM4Error: LocalizedError {
    case cannotOpen(String)
    case notLittleEndian
    case noDatacube
    case unsupportedDataType(Int)
    case truncated
    /// The disk a memory-mapped file came from is gone (file name only, never
    /// the folders above it). Raised by every read after the first one that
    /// finds it gone — see `DM4Reader.requireDiskAlive()`.
    case volumeGone(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let detail): return "Could not open DM file: \(detail)"
        case .notLittleEndian: return "This DM file is big-endian (Mac-authored); only little-endian DM files are supported."
        case .noDatacube: return "No 4D (or scan-shaped 3D) datacube was found in this DM file."
        case .unsupportedDataType(let t): return "Unsupported DM image data type \(t)."
        case .truncated: return "The DM file ended unexpectedly while parsing."
        case .volumeGone(let name):
            return "\(name) is no longer reachable: its disk was disconnected. Reconnect it and reopen."
        }
    }
}
