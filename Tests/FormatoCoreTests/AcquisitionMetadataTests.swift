//
//  AcquisitionMetadataTests.swift
//  The rules (a), (b), (f) of AcquisitionMetadata, GuardedXML's bounds and FormatoFileWrite.
//

import Foundation
import Testing
import FormatoCore

@Suite struct AcquisitionMetadataTests {
    @Test func testRuleAAbsentEmptyOrUnparseableIsNil() {
        #expect(AcquisitionMetadata.number(nil) == nil)
        #expect(AcquisitionMetadata.number("  ") == nil)
        #expect(AcquisitionMetadata.number("notafloat") == nil)
        #expect(AcquisitionMetadata.number("0x10") == nil)
        #expect(AcquisitionMetadata.number("nan") == nil)
        #expect(AcquisitionMetadata.number(" 1.5e3 ") == 1500)
        #expect(AcquisitionMetadata.text("\n ") == nil)
        #expect(AcquisitionMetadata.text(" HAADF ") == "HAADF")
    }

    @Test func testRuleBPositiveOnly() {
        #expect(AcquisitionMetadata.positive(0) == nil)
        #expect(AcquisitionMetadata.positive(-1) == nil)
        #expect(AcquisitionMetadata.positive(.infinity) == nil)
        #expect(AcquisitionMetadata.positive(.nan) == nil)
        #expect(AcquisitionMetadata.positive(200) == 200)
    }

    @Test func testRuleFDifferingCopy() {
        #expect(AcquisitionMetadata.differingCopy(100, 100.00001) == nil)
        #expect(AcquisitionMetadata.differingCopy(100, 100.001) == 100.001)
        #expect(AcquisitionMetadata.differingCopy(100, nil) == nil)
        #expect(AcquisitionMetadata.differingCopy(0, 0) == nil)
    }

    @Test func testEmptyAndFieldOrder() {
        var m = AcquisitionMetadata()
        #expect(m.isEmpty)
        m.highTensionKV = MetadataReading(300, note: nil)
        #expect(!m.isEmpty)
        #expect(AcquisitionMetadata.Field.allCases.count == 9)
    }

    @Test func testGuardedXMLBounds() {
        #expect(GuardedXML.document("<a><b>1</b></a>") != nil)
        #expect(GuardedXML.refusal("<a>") == .malformed)
        let deep = String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65)
        #expect(GuardedXML.refusal(deep) == .depth)
        let entity = "<!DOCTYPE a [<!ENTITY e \"x\">]><a>&e;</a>"
        #expect(GuardedXML.refusal(entity) == .entity)
        #expect(GuardedXML.document(entity) == nil)
        let long = "<a>" + String(repeating: "x", count: GuardedXML.maxCharacters + 1) + "</a>"
        #expect(GuardedXML.refusal(long) == .characters)
        #expect(GuardedXML.bounded(String(repeating: "x", count: 257)) == nil)
        #expect(GuardedXML.bounded("ok") == "ok")
    }

    @Test func testSafeWriteCreatesReplacesAndRefusesAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("formato-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.bin")
        try FormatoFileWrite.write(Data([1, 2, 3]), to: file)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        try FormatoFileWrite.write(Data([9]), to: file)
        #expect(try Data(contentsOf: file) == Data([9]))
        let folder = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: FormatoWriteError.self) { try FormatoFileWrite.write(Data([1]), to: folder) }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["out.bin", "sub"])
    }

    @Test func testDisplayFileNameEqualsTheAppsCopy() {
        // The app's DisplayFileName.swift body (macTEM cb6e164): lastPathComponent, or the path when that is empty.
        #expect(formatoDisplayFileName("/Users/x/data/a.dm4") == "a.dm4")
        #expect(formatoDisplayFileName("a.dm4") == "a.dm4")
        #expect(formatoDisplayFileName("") == "")
        #expect(formatoDisplayFileName("/") == "/")
    }

    @Test func theNoReferenceNoteStatesTheFactAndKeepsItsOldName() {
        // Apps show the note verbatim: it says what is known (no published reader, read as stored), never "unvalidated".
        #expect(AcquisitionMetadata.noPublishedReaderNote == "no published reader reads this field; read as the file stores it")
        #expect(AcquisitionMetadata.unvalidatedNote == AcquisitionMetadata.noPublishedReaderNote)
        #expect(!AcquisitionMetadata.noPublishedReaderNote.lowercased().contains("unvalidated"))
    }
}
