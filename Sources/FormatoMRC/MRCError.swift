//
//  MRCError.swift
//  What FormatoMRC refuses, by name. Messages never contain a whole path.
//

import Foundation

public nonisolated enum MRCError: Error, Equatable, LocalizedError {
    /// The bytes are not an MRC header (too short, no "MAP " id, a zero side).
    case notMRC(String)
    /// The machine stamp names no byte order (`MRCAppImage` only; RosettaSciIO ignores the stamp).
    case byteOrder(stamp: [UInt8])
    /// A stack (`MRCAppImage` only; RosettaSciIO reads stacks).
    case stack(frames: Int)
    /// A pixel mode this reader does not read.
    case mode(Int)
    /// Axes stored in an order other than 1, 2, 3 (`MRCAppImage` only).
    case axisOrder(mapc: Int, mapr: Int, maps: Int)
    /// The extended header or the data run past the end of the file.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notMRC(let what): "It is not an MRC image (\(what))."
        case .byteOrder(let stamp):
            "Its machine stamp (\(stamp.map { String(format: "%02X", $0) }.joined(separator: " "))) names no byte order."
        case .stack(let frames): "It is a stack of \(frames) images; this reading does not read stacks."
        case .mode(let mode): "Its pixel mode \(mode) is not read."
        case .axisOrder(let c, let r, let s): "Its axes are stored in the order \(c), \(r), \(s); only 1, 2, 3 is read."
        case .truncated: "The file ends before its image does."
        }
    }
}
