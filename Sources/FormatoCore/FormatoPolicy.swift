//
//  FormatoPolicy.swift
//  Role: What the readers share of FormatoKit's own policies: a choice FormatoKit makes where
//        RosettaSciIO raises, or where an inherited reader has a contract, is a parameter whose default is the 0.1.1 behaviour.
//        A non-default path that changes what is returned adds one metadata entry under `FormatoMetadata.policyKeyPrefix`
//        whose provenance rule begins "FormatoKit policy, not RosettaSciIO's", and only when that branch fired.
//

import Foundation

/// What a reader does with a pixel unit FormatoUnits does not handle (anything outside m and s with an SI prefix, to the
/// power +1 or -1, and dimensionless).
public nonisolated enum FormatoUnconvertedUnits: Sendable, Equatable {
    /// Refuse the signal (the default; what 0.1.1 does).
    case refuse
    /// Keep the file's numbers (after Python's `float()` only: no compacting, no factor) and the unit string as written. Applies
    /// only where every unit involved is that one unhandled string. Where Pint itself would raise (an overflow or underflow, two
    /// units of another base or power) the signal is still refused.
    case keepAsWritten
}

extension FormatoMetadata {
    /// The reserved prefix of the metadata entries a non-default policy adds (`FormatoKit.policy.units`, `.grid`, ...). The
    /// default output of every reader carries no key under it.
    public static let policyKeyPrefix = "FormatoKit.policy."

    /// The provenance rule a policy entry's rule begins with.
    package static let policyRulePrefix = "FormatoKit policy, not RosettaSciIO's"
}
