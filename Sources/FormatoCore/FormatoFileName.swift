//
//  FormatoFileName.swift
//  The file name an error or a metadata line shows, never the whole path. The inherited `spectroDisplayFileName`,
//  renamed (docs/registration-step-1.md §1.1); public because the readers in the other modules use it.
//

import Foundation

public nonisolated func formatoDisplayFileName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
}
