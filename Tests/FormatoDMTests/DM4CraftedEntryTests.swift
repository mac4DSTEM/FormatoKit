//
//  DM4CraftedEntryTests.swift
//  A DM4 entry whose size is near Int.max is refused as truncated, never an overflow trap (macEMSuite/FormatoKit#103).
//  Red before: `entryStart + size` overflowed.
//

import Foundation
import Testing
import FormatoDM

@Suite struct DM4CraftedEntryTests {

    private func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    @Test func anEntrySizeNearIntMaxIsRefused() {
        var b: [UInt8] = be(4, 4) + be(0, 8) + be(1, 4)                // DM4, file size, little-endian data
        b += [0, 0] + be(1, 8)                                          // root group: sorted, open, one entry
        b += [21] + be(1, 2) + Array("a".utf8) + be(UInt64(Int.max), 8) // a data entry of size Int.max
        b += [37, 37, 37, 37] + [UInt8](repeating: 0, count: 32)
        #expect(throws: (any Error).self) { try DM4Experiment.tagTree(data: Data(b)) }
    }
}
