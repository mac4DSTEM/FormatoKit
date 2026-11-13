//
//  CraftedShapeTests.swift
//  A lazy file array whose shape or offset comes from a crafted header is refused with a typed error, never an overflow trap,
//  and a truncated file is refused before the slab is allocated (macEMSuite/FormatoKit#103).
//  Red before: `offset + element * size + done` and the stride products overflowed on an extreme shape or offset; a declared
//  shape far past the file allocated the whole slab before the first read failed.
//

import Foundation
import Testing
import FormatoCore

@Suite struct CraftedShapeTests {

    private func file(_ bytes: [UInt8]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crafted-\(UUID().uuidString).raw")
        try Data(bytes).write(to: url)
        return url.path
    }

    @Test func aShapeWhoseElementCountOverflowsIsRefused() throws {
        let path = try file([UInt8](repeating: 1, count: 16))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let array = FormatoFileArray(path: path, offset: 0, dataType: .uint8, shape: [Int.max, 4])
        #expect(throws: FormatoArrayError.invalidShape([Int.max, 4])) { try array.read(start: [0, 0], count: [1, 1]) }
    }

    @Test func anOffsetThatOverflowsWithTheArrayIsRefused() throws {
        let path = try file([UInt8](repeating: 1, count: 16))
        defer { try? FileManager.default.removeItem(atPath: path) }
        for offset in [Int.max - 2, -1] {
            let array = FormatoFileArray(path: path, offset: offset, dataType: .float32, shape: [4])
            #expect(throws: FormatoArrayError.invalidShape([4]), "offset \(offset)") { try array.read(start: [0], count: [4]) }
        }
    }

    @Test func aTruncatedFileIsRefusedBeforeTheSlabAndAPartIsStillRead() throws {
        let path = try file((0..<16).map { UInt8($0) })
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A header that says 100 000 x 100 000 float32 (40 GB) over 16 bytes.
        let huge = FormatoFileArray(path: path, offset: 0, dataType: .float32, shape: [100_000, 100_000])
        #expect(throws: FormatoReadError.self) { try huge.read(start: [0, 0], count: [100_000, 100_000]) }
        // The bytes that are there still read.
        let small = FormatoFileArray(path: path, offset: 0, dataType: .uint8, shape: [1000, 1000])
        let row = try small.read(start: [0, 0], count: [1, 4])
        #expect([UInt8](row.bytes) == [0, 1, 2, 3])
        #expect(throws: FormatoReadError.self) { try small.read(start: [0, 0], count: [2, 4]) }
    }
}
