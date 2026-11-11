//
//  MerlinSetTests.swift
//  Merlin's own saves (FormatoKit, mac4DSTEM#120): a header with Frames per Trigger and no ScanX/ScanY, and "save to multiple
//  files" (`default1.mib` … `defaultN.mib` beside one `default.hdr`). The files are written here, 1x1 U08 frames with Merlin's
//  384-byte header and its .hdr text; each frame's pixels are a function of the frame number, so order and gaps show.
//

import Foundation
import Testing
import FormatoCore
import FormatoMIB

private func directory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
}

/// One 1x1 U08 frame as the Merlin software writes it (frame numbers from 1).
private func frame(_ number: Int) -> Data {
    var header = "MQ1,\(String(format: "%06d", number)),00384,01,0256,0256,U08,   1x1,01,2020-05-18 16:51:49.971626,0.000555,0,0,0,"
        + "1.200000E+2,5.110000E+2,0.000000E+0,0.000000E+0,0.000000E+0,0.000000E+0,0.000000E+0,0.000000E+0,3RX,175,511,"
        + "MQ1A,2020-05-18T14:51:49.971626178Z,555000ns,6,"
    header += String(repeating: " ", count: 384 - header.utf8.count)
    var data = Data(header.utf8)
    data.append(contentsOf: (0..<(256 * 256)).map { UInt8(truncatingIfNeeded: ($0 * 3 + number * 7) % 251) })
    return data
}

/// Merlin's .hdr: tab-separated pairs between `HDR,` and `End`, no ScanX/ScanY.
private func merlinHeader(frames: Int, perTrigger: Int) -> String {
    ["HDR,", "Time and Date Stamp (day, mnth, yr, hr, min, s):\t18/05/2020 16:51:48", "Chip ID:\tW529_F5,-,-,-",
     "Chip Type (Medipix 3.0, Medipix 3.1, Medipix 3RX):\tMedipix 3RX", "Assembly Size (NX1, 2X2):\t1x1",
     "Chip Mode  (SPM, CSM, CM, CSCM):\tSPM", "Counter Depth (number):\t6",
     "Frames in Acquisition (Number):\t\(frames)", "Frames per Trigger (Number):\t\(perTrigger)",
     "Readout System:\tMerlin Quad", "Software Version:\t0.67.0.9", "End\t"].joined(separator: "\r\n")
}

/// A 3 x 4 scan (12 frames, 4 per trigger) saved as `default1.mib` … `default3.mib` beside `default.hdr`.
private func writeSet(in dir: URL, parts: Int = 3, framesPerPart: Int = 4, header: String? = nil) throws {
    try (header ?? merlinHeader(frames: parts * framesPerPart, perTrigger: 4)).write(to: dir.appendingPathComponent("default.hdr"),
                                                                                       atomically: true, encoding: .utf8)
    for part in 0..<parts {
        var data = Data()
        for k in 0..<framesPerPart { data += frame(part * framesPerPart + k + 1) }
        try data.write(to: dir.appendingPathComponent("default\(part + 1).mib"))
    }
}

@Test func aSetIsFoundFromAnyPartOrItsHeaderAndNotFromASingleFile() throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeSet(in: dir)
    let expected = (1...3).map { dir.appendingPathComponent("default\($0).mib").path }
    for picked in ["default1.mib", "default2.mib", "default3.mib", "default.hdr", "default2.Mib"] where
        picked != "default2.Mib" || FileManager.default.fileExists(atPath: dir.appendingPathComponent(picked).path) {   // a case-insensitive volume
        let set = try #require(MerlinSet.containing(dir.appendingPathComponent(picked).path), "\(picked)")
        #expect(set.parts == expected)
        #expect(set.header == dir.appendingPathComponent("default.hdr").path)
    }
    // Not a set: a .mib with its own .hdr, a .mib with no shared .hdr, a zero-padded number, another extension.
    try Data().write(to: dir.appendingPathComponent("single.mib")); try Data().write(to: dir.appendingPathComponent("single.hdr"))
    try Data().write(to: dir.appendingPathComponent("other1.mib"))
    try Data().write(to: dir.appendingPathComponent("default01.mib"))
    for picked in ["single.mib", "single.hdr", "other1.mib", "default01.mib", "default.raw", "default4.mib"] {
        #expect(MerlinSet.containing(dir.appendingPathComponent(picked).path) == nil, "\(picked)")
    }
}

@Test func aSetReadsAsOneScanShapedByFramesPerTrigger() throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeSet(in: dir)
    let set = try #require(MerlinSet.containing(dir.appendingPathComponent("default2.mib").path))
    let reader = try MIBReader(set: set)
    #expect(reader.pixelCode == "U08")
    let signal = try reader.signal.load()
    #expect(signal.data.shape == [3, 4, 256, 256])
    #expect(signal.data.dataType == .float32)

    // The same frames in one file with ScanX/ScanY: the app convention's existing reading, byte for byte.
    let single = dir.appendingPathComponent("joined.mib")
    var joined = Data(); for n in 1...12 { joined += frame(n) }
    try joined.write(to: single)
    try "HDR,\r\nScanX:\t4\r\nScanY:\t3\r\nEnd\t".write(to: dir.appendingPathComponent("joined.hdr"), atomically: true, encoding: .utf8)
    let reference = try MIBReader(path: single.path, convention: .appScanXY).signal.load()
    #expect(signal.data == reference.data)

    // Lazy slabs across part boundaries (each part is one scan row of 4 frames).
    for (start, count) in [([0, 3, 10, 20], [2, 1, 3, 5]), ([1, 0, 0, 0], [1, 4, 2, 256]), ([0, 0, 255, 255], [3, 4, 1, 1])] {
        #expect(try reader.signal.array.read(start: start, count: count) == signal.data.slab(start: start, count: count))
    }

    // The same frames in one file whose own .hdr is Merlin's (Frames per Trigger, no ScanX/ScanY): the same scan.
    let merlinSingle = dir.appendingPathComponent("merlin.mib")
    try joined.write(to: merlinSingle)
    try merlinHeader(frames: 12, perTrigger: 4).write(to: dir.appendingPathComponent("merlin.hdr"), atomically: true, encoding: .utf8)
    #expect(try MIBReader(path: merlinSingle.path, convention: .appScanXY).signal.load().data == reference.data)
}

@Test func aSetWithAGapAMisorderedPartOrNoRowLengthIsRefused() throws {
    // A missing middle part: the run of names stops at default1, whose 4 frames are not the header's 12.
    do {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeSet(in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("default2.mib"))
        let set = try #require(MerlinSet.containing(dir.appendingPathComponent("default1.mib").path))
        #expect(set.parts.count == 1)
        #expect(throws: MIBError.self) { try MIBReader(set: set) }
        #expect(MerlinSet.containing(dir.appendingPathComponent("default3.mib").path) == nil)
    }
    // Two parts swapped on disk: the frame numbers do not run on.
    do {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeSet(in: dir)
        let two = dir.appendingPathComponent("default2.mib"), three = dir.appendingPathComponent("default3.mib")
        let swap = dir.appendingPathComponent("swap")
        try FileManager.default.moveItem(at: two, to: swap); try FileManager.default.moveItem(at: three, to: two)
        try FileManager.default.moveItem(at: swap, to: three)
        let set = try #require(MerlinSet.containing(two.path))
        #expect(throws: MIBError.self) { try MIBReader(set: set) }
    }
    // One frame per trigger, or one trigger for the whole scan, names no row length; a total that is not whole rows; a header
    // with no counts at all.
    for header in [merlinHeader(frames: 12, perTrigger: 1), merlinHeader(frames: 12, perTrigger: 12), merlinHeader(frames: 12, perTrigger: 5),
                   "HDR,\r\nChip ID:\tW529_F5\r\nEnd\t"] {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeSet(in: dir, header: header)
        let set = try #require(MerlinSet.containing(dir.appendingPathComponent("default.hdr").path))
        #expect(throws: MIBError.self) { try MIBReader(set: set) }
    }
    // A part of another frame layout (U16 frames in part 3).
    do {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeSet(in: dir)
        var odd = Data()
        for n in 9...10 {
            var f = frame(n)
            let header = String(decoding: f.prefix(384), as: UTF8.self).replacingOccurrences(of: ",U08,", with: ",U16,")
            f.replaceSubrange(0..<384, with: Data(header.utf8))
            odd += f + Data(count: 256 * 256)
        }
        try odd.write(to: dir.appendingPathComponent("default3.mib"))
        let set = try #require(MerlinSet.containing(dir.appendingPathComponent("default1.mib").path))
        #expect(throws: MIBError.self) { try MIBReader(set: set) }
    }
}
