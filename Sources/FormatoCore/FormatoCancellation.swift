//
//  FormatoCancellation.swift
//  The one cancellation contract of FormatoKit's long reads: a `cancelled` closure with the default
//  `FormatoCancellation.task`, an optional `progress` closure (fraction 0…1), and `FormatoCancelled` thrown when the closure
//  answers true; nothing partial is kept. Moved from SpectroKit 0.3.0's `SpectroCancellation.swift` with the names changed
//  (docs/registration-step-1.md §1.1); the bodies are SpectroKit's. `check` is public because SpectroKit's own long calls,
//  in another package, use it too.
//

import Foundation

/// Thrown by a long call whose `cancelled` closure returned true. Nothing it was building is returned or kept.
public nonisolated struct FormatoCancelled: Error, Equatable {
    public init() {}
}

public nonisolated enum FormatoCancellation {
    /// The default `cancelled` closure: Swift task cancellation, so a caller inside a Task needs to pass nothing.
    public static let task: @Sendable () -> Bool = { Task.isCancelled }

    /// Throws `FormatoCancelled` when `cancelled()` is true. Call at block or step boundaries, never per value.
    public static func check(_ cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw FormatoCancelled() }
    }
}
