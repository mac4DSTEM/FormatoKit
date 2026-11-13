//
//  EMPADUntrustedXMLTests.swift
//  An EMPAD header is untrusted: it goes through GuardedXML's bounds, and its raw_file.filename must stay in the header's folder
//  (macEMSuite/FormatoKit#110).
//  Red before: plain `XMLParser` took any depth and any entity; `../` or an absolute raw path was followed to another file.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMPAD

@Suite struct EMPADUntrustedXMLTests {

    private func header(_ body: String) throws -> (dir: URL, xml: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xml = dir.appendingPathComponent("header.xml")
        try Data(body.utf8).write(to: xml)
        return (dir, xml)
    }

    private func plain(filename: String) -> String {
        "<root><raw_file filename=\"\(filename)\"/><pix_x>2</pix_x><pix_y>1</pix_y></root>"
    }

    @Test func aRawPathOutsideTheHeadersFolderIsRefused() throws {
        for name in ["../scan_x2_y1.raw", "/etc/hosts", "sub/../../x.raw", "~/x.raw"] {
            let (dir, xml) = try header(plain(filename: name))
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(throws: EMPADError.invalidXML("raw_file.filename '\(name)' leaves the header's folder"), "\(name)") {
                try EMPADReader(path: xml.path)
            }
        }
        #expect(EMPADReader.isConfined("scan_x2_y1.raw"))
        #expect(EMPADReader.isConfined("raw/scan_x2_y1.raw"))
        #expect(!EMPADReader.isConfined(".."))
    }

    @Test func aHeaderThatNestsTooDeepOrDeclaresAnEntityIsRefused() throws {
        let deep = String(repeating: "<a>", count: GuardedXML.maxDepth + 10) + String(repeating: "</a>", count: GuardedXML.maxDepth + 10)
        let entity = "<?xml version=\"1.0\"?><!DOCTYPE root [<!ENTITY e \"x\">]><root><raw_file filename=\"&e;.raw\"/></root>"
        for body in [deep, entity] {
            let (dir, xml) = try header(body)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(throws: EMPADError.self) { try EMPADReader(path: xml.path) }
            do { _ = try EMPADReader(path: xml.path) } catch let error as EMPADError {
                #expect(error != .invalidXML("Missing raw_file.filename"), "refused before the fields were read")
            }
        }
    }
}
