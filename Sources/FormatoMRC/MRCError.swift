//
//  MRCError.swift
//  What FormatoMRC refuses, by name. Messages never contain a whole path.
//

import Foundation

public nonisolated enum MRCError: Error, Equatable, LocalizedError {
    /// The bytes are not an MRC header (too short, no "MAP " id).
    case notMRC(String)
    /// The machine stamp names no byte order.
    case byteOrder(stamp: [UInt8])
    /// The extended header or the data run past the end of the file.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notMRC(let what): "It is not an MRC image (\(what))."
        case .byteOrder(let stamp):
            "Its machine stamp (\(stamp.map { String(format: "%02X", $0) }.joined(separator: " "))) names no byte order."
        case .truncated: "The file ends before its image does."
        }
    }
}
