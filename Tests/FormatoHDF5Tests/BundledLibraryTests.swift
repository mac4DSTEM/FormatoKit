//
//  BundledLibraryTests.swift
//  Registration §5 and gate H1's in-process half: the libhdf5 FormatoKit ships is found next to the test bundle, loads, and
//  stands in the Velox reader's lookup after the host's own copies and before the bare name. (The consumer check proves
//  the other half: a separate package reads a Velox file with MAC4DSTEM_HDF5_PATH unset.)
//  Mutation 16 (the shipped candidate removed from the lookup) - red.
//

import XCTest
import Darwin
import FormatoHDF5
import FormatoEMD

final class BundledLibraryTests: XCTestCase {
    func testTheShippedLibraryIsFoundAndLoads() throws {
        let path = try XCTUnwrap(FormatoHDF5Library.bundledLibraryPath, "the FormatoKit_FormatoHDF5 bundle is not next to the tests")
        XCTAssertTrue(path.hasSuffix("hdf5/libhdf5.dylib"), path)
        let handle = try XCTUnwrap(dlopen(path, RTLD_NOW | RTLD_LOCAL), String(cString: dlerror()))
        XCTAssertNotNil(dlsym(handle, "H5open"))
        XCTAssertNotNil(dlsym(handle, "H5Dread"))
    }

    func testTheReaderLooksForTheShippedLibraryAfterTheHostsAndBeforeTheBareName() throws {
        let candidates = VeloxHDF5Library.defaultCandidates()
        let shipped = try XCTUnwrap(FormatoHDF5Library.bundledLibraryPath)
        let i = try XCTUnwrap(candidates.firstIndex(of: shipped), "the shipped libhdf5 is not a candidate: \(candidates)")
        XCTAssertEqual(candidates.last, "libhdf5.dylib")
        XCTAssertEqual(i, candidates.count - 2, "the shipped copy comes right before the bare name")
    }
}
