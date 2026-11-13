//
//  TIFFVendorXMLGuardTests.swift
//  The JEOL SightX description XML goes through GuardedXML's bounds before it is built (macEMSuite/FormatoKit#110).
//  Red before: plain `XMLParser` built any depth and accepted an entity declaration.
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFVendorXMLGuardTests {
    @Test func aDescriptionThatNestsTooDeepOrDeclaresAnEntityIsAParseError() {
        let deep = String(repeating: "<a>", count: GuardedXML.maxDepth + 10) + String(repeating: "</a>", count: GuardedXML.maxDepth + 10)
        let entity = "<?xml version=\"1.0\"?><!DOCTYPE TemReporter [<!ENTITY e \"x\">]><TemReporter>&e;</TemReporter>"
        for xml in [deep, entity] {
            #expect(throws: TIFFError.unsupportedLayout("ParseError")) { try FormatoTIFF.XMLNode.parse(xml) }
        }
        #expect((try? FormatoTIFF.XMLNode.parse("<TemReporter><Eos><EosMode>TEM MAG</EosMode></Eos></TemReporter>"))?.name == "TemReporter")
    }
}
