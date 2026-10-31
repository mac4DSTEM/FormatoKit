//
//  HDF5SlabWalkBraggTests.swift
//  The slab reader, the link walk and BraggVectors in a session (added in 0.8.0), all exact: the handle-holding slab reader returns the bytes `readDataset` returns, the link
//  walk agrees with `descendants` and adds link kind and object identity, and the BraggVectors object written into a
//  session reads back as written.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5

@Suite struct HDF5SlabWalkBraggTests {
    static let assorted = HDF5ReaderTests.fixture("assorted.h5")

    @Test func slabReaderMatchesReadDataset() throws {
        let reader = try HDF5Reader(url: Self.assorted)
        for path in ["/a/data/f32", "/a/data/chunked", "/a/data/be_i2", "/a/data/u8", "/a/data/scalar_f8", "/a/data/f16", "/a/data/empty"] {
            let held = try HDF5SlabReader(url: Self.assorted, path: path)
            let whole = try reader.readDataset(path)
            #expect(try held.read(start: [Int](repeating: 0, count: held.shape.count), count: held.shape) == whole, "\(path)")
            if held.shape.count >= 2, held.shape.allSatisfy({ $0 > 1 }) {
                let start = held.shape.map { $0 - 2 }, count = held.shape.map { _ in 2 }
                for _ in 0..<3 {   // repeated reads on the held handle
                    #expect(try held.read(start: start, count: count) == reader.readDataset(path, start: start, count: count), "\(path)")
                }
            }
        }
    }

    @Test func slabReaderIntoBufferAndRefusals() throws {
        let held = try HDF5SlabReader(url: Self.assorted, path: "/a/data/f32")
        var buffer = [Float](repeating: 0, count: 4)
        try buffer.withUnsafeMutableBytes { try held.read(start: [1, 1, 0], count: [1, 1, 4], into: $0) }
        let expected = try HDF5Reader(url: Self.assorted).readDataset("/a/data/f32", start: [1, 1, 0], count: [1, 1, 4])
        #expect(Data(bytes: buffer, count: 16) == expected.bytes)
        #expect(throws: HDF5FileError.self) { try held.read(start: [0, 0, 0], count: [3, 3, 4]) }
        #expect(throws: HDF5FileError.self) {
            var small = [UInt8](repeating: 0, count: 3)
            try small.withUnsafeMutableBytes { try held.read(start: [0, 0, 0], count: [1, 1, 4], into: $0) }
        }
        #expect(throws: HDF5FileError.self) { try HDF5SlabReader(url: Self.assorted, path: "/strings/fixed") }
        #expect(throws: HDF5FileError.self) { try HDF5SlabReader(url: Self.assorted, path: "/a") }
        #expect(throws: HDF5FileError.self) { try HDF5SlabReader(url: Self.assorted, path: "/nope") }
        held.close()
        held.close()
        #expect(throws: HDF5FileError.self) { try held.read(start: [0, 0, 0], count: [1, 1, 1]) }
    }

    @Test func walkAgreesWithDescendants() throws {
        let reader = try HDF5Reader(url: Self.assorted)
        let walked = try reader.walk()
        let listed = try reader.descendants()
        #expect(Set(listed.map(\.path)).isSuperset(of: Set(walked.map(\.path))))   // walk never enters a group twice; descendants may
        for entry in walked {
            #expect(entry.kind == (try reader.kind(of: entry.path)), "\(entry.path)")
            if entry.link == .hard, entry.kind != .other { #expect(entry.identity != nil, "\(entry.path)") }
            if entry.link != .hard { #expect(entry.identity == nil) }
        }
        // Order: a group before its members.
        for (i, entry) in walked.enumerated() where entry.kind == .group {
            let members = walked.indices.filter { walked[$0].path.hasPrefix(entry.path + "/") }
            #expect(members.allSatisfy { $0 > i })
        }
        #expect(throws: HDF5FileError.self) { try reader.walk(from: "/a/data/f32") }
        #expect(throws: HDF5FileError.limitExceeded("more than 2 objects below /")) { try reader.walk(maximumObjects: 2) }
    }

    @Test func braggVectorsInASession() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.h5")
        let peaks: [[BraggPeak]] = [[BraggPeak(qx: 1.5, qy: 2.5, intensity: 3)], [], [BraggPeak(qx: 4, qy: 5, intensity: 6), BraggPeak(qx: 7, qy: 8, intensity: 9)],
                                    [BraggPeak(qx: -1, qy: 0, intensity: 0.25)]]
        try HDF5NewFile.write(to: url) { session in
            try session.writeEMDFileHeader(EMDFileHeader(authoringProgram: "test"))
            try session.createEMDRoot("session_root")
            try session.writeBraggVectors(peaks: peaks, scan: BraggGridShape(rows: 2, columns: 2), detector: BraggGridShape(rows: 16, columns: 20),
                                          inRoot: "/session_root", convention: .appImageXY,
                                          groupAttributes: ["mac4dstem_detection_provenance": "{\"a\":1}"])
            #expect(throws: HDF5FileError.self) {
                try session.writeBraggVectors(peaks: peaks, scan: BraggGridShape(rows: 2, columns: 2), detector: BraggGridShape(rows: 16, columns: 20),
                                              inRoot: "/session_root")
            }
            #expect(throws: BraggVectorsEMDError.self) {
                try session.writeBraggVectors(peaks: peaks, scan: BraggGridShape(rows: 3, columns: 2), detector: BraggGridShape(rows: 1, columns: 1),
                                              inRoot: "/session_root", nodeName: "other")
            }
        }
        let read = try BraggVectorsEMD.read(path: url.path, groupPath: "/session_root/braggvectors", convention: .appImageXY,
                                            attributeNames: ["mac4dstem_detection_provenance"])
        #expect(read.peaks == peaks)
        #expect(read.scan == BraggGridShape(rows: 2, columns: 2))
        #expect(read.detector == BraggGridShape(rows: 16, columns: 20))
        #expect(read.attributes[.braggVectors]?["mac4dstem_detection_provenance"] == "{\"a\":1}")
        // Same bytes as the stand-alone writer's object.
        let alone = dir.appendingPathComponent("alone.h5")
        try BraggVectorsEMD.write(peaks: peaks, scan: BraggGridShape(rows: 2, columns: 2), detector: BraggGridShape(rows: 16, columns: 20),
                                  to: alone, convention: .appImageXY, rootName: "session_root")
        let a = try HDF5Reader(url: url), b = try HDF5Reader(url: alone)
        for path in ["/session_root/braggvectors/_v_uncal/data", "/session_root/braggvectors/metadatabundle/_braggvectors_shape/Rshape",
                     "/session_root/braggvectors/metadatabundle/_braggvectors_shape/Qshape"] {
            #expect(try a.datasetInfo(path) == b.datasetInfo(path), "\(path)")
        }
        #expect(try a.readDataset("/session_root/braggvectors/metadatabundle/_braggvectors_shape/Qshape")
                == b.readDataset("/session_root/braggvectors/metadatabundle/_braggvectors_shape/Qshape"))
    }

    @Test func sameFileIsPublic() throws {
        #expect(HDF5PendingFile.sameFile(Self.assorted.path, Self.assorted.path))
        #expect(!HDF5PendingFile.sameFile(Self.assorted.path, HDF5ReaderTests.fixture("latest.h5").path))
    }
}
