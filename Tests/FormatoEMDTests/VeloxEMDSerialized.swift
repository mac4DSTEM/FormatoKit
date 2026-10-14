import Testing

/// The parent of the four Velox suites in this target. XCTest ran every test of the target one after another;
/// Swift Testing runs suites side by side, and `.serialized` orders only what is inside one suite. These suites share
/// process-wide state: `VeloxLockAndCancelTests.testLibraryCandidatesDefaultAndOverride` replaces
/// `VeloxHDF5Library.libraryCandidates` for a moment, and the file reads of the other suites would then look for
/// `/nonexistent/libhdf5-not-here.dylib`. A serialized parent runs everything below it one test at a time.
@Suite(.serialized) enum VeloxEMDSerialized {}
