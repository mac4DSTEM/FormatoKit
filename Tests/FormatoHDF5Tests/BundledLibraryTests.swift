//
//  BundledLibraryTests.swift
//  The in-process half of the bundled-library check (tools/consumer-check is the other): the libhdf5 FormatoKit ships (the FormatoLibHDF5 framework, a binary target) is found, loads, and
//  stands in the Velox reader's lookup after the host's own copies and before the bare name. (The consumer check proves
//  the other half: a separate package reads a Velox file with FORMATO_HDF5_PATH unset.)
//  Mutation 16 (the shipped candidate removed from the lookup) - red.
//

import Testing
import Foundation
import Darwin
import FormatoHDF5
import FormatoEMD

@Suite(.serialized) struct BundledLibraryTests {
    @Test func testTheShippedLibraryIsFoundAndLoads() throws {
        let path = try #require(FormatoHDF5Library.bundledLibraryPath, "the FormatoLibHDF5 framework is not loaded or next to the tests")
        #expect(path.contains("FormatoLibHDF5.framework/"), "\(path)")
        let handle = try #require(dlopen(path, RTLD_NOW | RTLD_LOCAL), "\(String(cString: dlerror()))")
        #expect(dlsym(handle, "H5open") != nil)
        #expect(dlsym(handle, "H5Dread") != nil)
    }

    @Test func testTheReaderLooksForTheShippedLibraryAfterTheHostsAndBeforeTheBareName() throws {
        let candidates = VeloxHDF5Library.defaultCandidates()
        let shipped = try #require(FormatoHDF5Library.bundledLibraryPath)
        let i = try #require(candidates.firstIndex(of: shipped), "the shipped libhdf5 is not a candidate: \(candidates)")
        #expect(candidates.last == "libhdf5.dylib")
        #expect(i == candidates.count - 2, "the shipped copy comes right before the bare name")
    }
}
