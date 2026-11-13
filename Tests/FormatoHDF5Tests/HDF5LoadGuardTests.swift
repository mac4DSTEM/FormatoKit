//
//  HDF5LoadGuardTests.swift
//  The libhdf5 load: no bare search-path lookup in a release build, every resolved symbol checked before `H5open`, and the
//  pinned version (macEMSuite/FormatoKit#110). The pinned library itself loads in every other HDF5 suite.
//

import Foundation
import Testing
@testable import FormatoHDF5

@Suite struct HDF5LoadGuardTests {

    @Test func aReleaseBuildNeverSearchesTheLoaderPath() {
        #if DEBUG
        #expect(SharedHDF5.standardCandidates().last == "libhdf5.dylib")
        #else
        #expect(!SharedHDF5.standardCandidates().contains("libhdf5.dylib"))
        #endif
    }

    @Test func aMissingLibraryIsRefusedInWords() {
        #expect(throws: HDF5DatacubeError.self) { try SharedHDF5.load(candidates: ["/nonexistent/libhdf5.dylib"]) }
    }

    @Test func aLibraryWithoutTheSymbolsIsClosedAndRefused() {
        // libSystem has none of HDF5's symbols: refused by name before anything in it runs.
        #expect(throws: HDF5DatacubeError.self) { try SharedHDF5.load(candidates: ["/usr/lib/libSystem.B.dylib"]) }
    }

    @Test func everySymbolTheLoaderResolvesIsCheckedFirst() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/FormatoHDF5/SharedHDF5.swift").standardized, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"try (?:symbol|global)\("([A-Za-z0-9_]+)""#)
        let names = Set(regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        })
        #expect(names.count > 60)
        #expect(names.subtracting(SharedHDF5.requiredSymbols).isEmpty, "\(names.subtracting(SharedHDF5.requiredSymbols).sorted())")
        #expect(SharedHDF5.pinnedVersion.major == 2 && SharedHDF5.pinnedVersion.minor == 1)
    }
}
