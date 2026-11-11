//
//  PublicMerlinSetTests.swift
//  A real-data check of `MerlinSet` and `MIBReader(set:)` on a public Merlin save: SrTiO3 [100], Zenodo 10.5281/zenodo.5113449
//  (CC BY 4.0), 64 files `default1.mib` … `default64.mib` beside `default.hdr`, 128 x 128 scan, 1x1 U08, Frames per Trigger 128.
//  It reads a local data file that a fresh clone does not have, and shows as skipped without it. The data folder is $MACEM_DATA,
//  else ../data beside the repository.
//

import Foundation
import Testing
import FormatoCore
import FormatoKitTestSupport
import FormatoMIB

@Suite struct PublicMerlinSetTests {
    private static let header: URL = {
        let dataRoot = ProcessInfo.processInfo.environment["MACEM_DATA"]
            ?? FixtureDirs.repository.deletingLastPathComponent().appendingPathComponent("data").path
        return URL(fileURLWithPath: dataRoot)
            .appendingPathComponent("4dstem/public/zenodo-5113449-srtio3-merlin/20200518 165148/default.hdr")
    }()

    @Test(.enabled(if: FileManager.default.fileExists(atPath: header.path), "the public SrTiO3 Merlin set is not in the data folder"))
    func theSixtyFourPartSaveReadsAsOneScan() throws {
        let set = try #require(MerlinSet.containing(Self.header.deletingLastPathComponent().appendingPathComponent("default17.mib").path))
        #expect(set.parts.count == 64)
        #expect(set.header == Self.header.path)
        let reader = try MIBReader(set: set)
        #expect(reader.pixelCode == "U08")
        #expect(reader.signal.array.shape == [128, 128, 256, 256])
        // Each part holds 256 frames (two scan rows): the last frame of part 1 (row 1, column 127) and the first of part 2 (row 2, column 0).
        let rows = try reader.signal.array.read(start: [1, 127, 0, 0], count: [1, 1, 256, 256])
        #expect(rows.shape == [1, 1, 256, 256])
        _ = try reader.signal.array.read(start: [2, 0, 0, 0], count: [1, 1, 256, 256])
    }
}
