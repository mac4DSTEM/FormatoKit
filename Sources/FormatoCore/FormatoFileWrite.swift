//
//  FormatoFileWrite.swift
//  The one safe way FormatoKit's consumers write a file: into a scratch file in the destination's item-replacement
//  directory first, then over the destination, so a failed or interrupted write leaves the old file as it was.
//

import Foundation

/// Why a file could not be written.
public nonisolated enum FormatoWriteError: Error, Equatable, LocalizedError {
    /// The system's reason the file could not be written.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return reason.isEmpty ? "The file could not be written." : "The file could not be written. \(reason)"
        }
    }
}

public nonisolated enum FormatoFileWrite {
    /// Writes `data` to `url`: into a scratch file in `url`'s item-replacement directory first, then over `url`
    /// (`replaceItemAt` when a file is there, `moveItem` otherwise); the scratch directory is removed after, on every
    /// path. Never an atomic write next to `url`. A folder at `url` is refused and left as it was.
    /// - Throws: ``FormatoWriteError/writeFailed(_:)`` with the system's reason.
    public static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw FormatoWriteError.writeFailed("\u{201C}\(url.lastPathComponent)\u{201D} is a folder.")
        }
        do {
            let directory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: url, create: true)
            defer { try? fileManager.removeItem(at: directory) }
            let name = url.lastPathComponent.isEmpty ? "export" : url.lastPathComponent
            let scratch = directory.appendingPathComponent(name)
            try data.write(to: scratch)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: scratch)
            } else {
                try fileManager.moveItem(at: scratch, to: url)
            }
        } catch {
            throw FormatoWriteError.writeFailed(error.localizedDescription)
        }
    }
}
