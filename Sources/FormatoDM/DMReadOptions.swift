//
//  DMReadOptions.swift
//  Role: the policies of the DM tag walk that FormatoKit chose, as parameters whose defaults are the 0.1.1 behaviour.
//

import Foundation

/// The options of the DM tag walk. The defaults give exactly the behaviour of the entry points without options.
public nonisolated struct DMReadOptions: Sendable, Equatable {
    /// How many bytes of a string the walk keeps: a type-18 string longer than this is cut there, a UTF-16 array at or
    /// past it is absent from the strings. `Int.max` keeps every string whole. Numeric arrays keep their fixed 4096-byte
    /// rule whatever this is. A negative value is read as 0.
    public var maximumStringBytes: Int

    public init(maximumStringBytes: Int = 4096) {
        self.maximumStringBytes = maximumStringBytes
    }
}
