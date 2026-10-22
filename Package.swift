// swift-tools-version: 6.2
// FormatoKit — a file-format library for electron microscopy on the Mac, the counterpart of RosettaSciIO: readers (and later writers)
// for the electron-microscopy formats, one module per format, over one data model (FormatoCore: axes, units, metadata
// with provenance, lazy signals). Checked bit for bit against RosettaSciIO (GPL-3.0) at a pinned commit; the DM and Velox
// readers are inherited from an earlier GPL-3.0 package (registration step 1 §1.1). docs/registration-step-1.md is the first registration.
//
// Swift 6 language mode, nonisolated by default (no `.defaultIsolation`), the three upcoming features that
// the settings below enable, no unsafe flags (a versioned dependency cannot carry them): a consumer builds the kit optimised itself,
// and tools/test.sh runs this package's tests with `-c release`. One product per module. What one module needs from
// another is `package`, never `public`; what a consumer reads is `public` and is guarded by tools/consumer-check.
// libhdf5 ships as three binary targets (FormatoLibHDF5, FormatoLibSZ, FormatoLibAEC: dynamic-framework XCFrameworks, arm64 macOS, minos 15),
// so an app that embeds the kit gets them embedded and signed with its own identity at archive time. The readers still dlopen libhdf5.
// Built by tools/xcframework/build.sh; the release assets are the zips it writes (the checksums below are its checksums.txt).
// With FORMATO_LOCAL_XCFRAMEWORKS set (tools/test.sh, CI and the consumer check set it) the targets are the local build in dist/xcframeworks.
// macOS 15 / iOS 18 (0.2.1). FormatoHDF5 and FormatoEMD load libhdf5 at run time and are macOS-only in practice: on iOS they
// build (the binary targets are macOS-only and conditional), but a Velox read refuses (no libhdf5 for iOS). The other modules are pure Swift.
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The release the three zips are attached to, and their SwiftPM checksums (written by a release run of tools/xcframework/build.sh).
let xcframeworkRelease = "0.4.0"
let xcframeworks: [(name: String, checksum: String)] = [
    ("FormatoLibHDF5", "8b6b74bc65088e4ba28e6bb5c897ef85e5f17a24ad3ab6ce0dae18531788d236"),
    ("FormatoLibSZ", "52388745a16c0856d162a8ed7efc1befa23f8274cdb7b169ee320e10d8f0a28d"),
    ("FormatoLibAEC", "bef7dd2368f3caf3c8d878ddd30784f1f4bf2570820a2384c693e0f5d6d28518"),
]
let useLocalXCFrameworks = Context.environment["FORMATO_LOCAL_XCFRAMEWORKS"] != nil
let binaryTargets: [Target] = xcframeworks.map { framework in
    useLocalXCFrameworks
        ? .binaryTarget(name: framework.name, path: "dist/xcframeworks/\(framework.name).xcframework")
        : .binaryTarget(
            name: framework.name,
            url: "https://github.com/mac4DSTEM/FormatoKit/releases/download/\(xcframeworkRelease)/\(framework.name).xcframework.zip",
            checksum: framework.checksum)
}

let package = Package(
    name: "FormatoKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "FormatoCore", targets: ["FormatoCore"]),
        .library(name: "FormatoDM", targets: ["FormatoDM"]),
        .library(name: "FormatoEMD", targets: ["FormatoEMD"]),
        .library(name: "FormatoHDF5", targets: ["FormatoHDF5"]),
        .library(name: "FormatoTIFF", targets: ["FormatoTIFF"]),
        .library(name: "FormatoMRC", targets: ["FormatoMRC"]),
        .library(name: "FormatoEMPAD", targets: ["FormatoEMPAD"]),
        .library(name: "FormatoMIB", targets: ["FormatoMIB"]),
        .library(name: "FormatoMSA", targets: ["FormatoMSA"]),
        // One import and one `FormatoLoader.load(path:)` for every format that reads as signals (0.9.0).
        .library(name: "Formato", targets: ["Formato"]),
        // One decimated frame and the header facts of a file, never more than one frame read (0.10.0): Quick Look and Finder-style consumers.
        .library(name: "FormatoPeek", targets: ["FormatoPeek"]),
    ],
    targets: binaryTargets + [
        // The data model every reader returns: arrays, axes, units, metadata with provenance, lazy signals; cancellation.
        .target(name: "FormatoCore", swiftSettings: settings),
        // HDF5: the process-wide HDF5 lock and quit barrier (HDF5Serial), the shipped libhdf5. Later: hspy, the sidecar.
        .target(name: "FormatoHDF5",
                dependencies: ["FormatoCore"] + xcframeworks.map { .target(name: $0.name, condition: .when(platforms: [.macOS])) },
                swiftSettings: settings),
        // Gatan DigitalMicrograph .dm3 / .dm4: DM4Experiment (inherited reader, registration step 1 §1.1) and the signal adapter.
        .target(name: "FormatoDM", dependencies: ["FormatoCore"], swiftSettings: settings),
        // EMD: Velox (inherited reader, registration step 1 §1.1) and its image adapter. Later: NCEM / Berkeley EMD.
        .target(name: "FormatoEMD", dependencies: ["FormatoCore", "FormatoHDF5"], swiftSettings: settings),
        // Additional formats; EMPAD reads XML + memory-mapped raw frames.
        .target(name: "FormatoTIFF", dependencies: ["FormatoCore", "FormatoDM"], swiftSettings: settings),
        .target(name: "FormatoMRC", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoEMPAD", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoMIB", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoMSA", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "Formato", dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoMRC", "FormatoMSA", "FormatoTIFF"],
                swiftSettings: settings),
        .target(name: "FormatoPeek",
                dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoHDF5", "FormatoMRC", "FormatoMSA", "FormatoTIFF", "Formato"],
                swiftSettings: settings),
        // The first ten minutes: `swift run formato-info <file>` prints every signal of a DM, Velox or TIFF file (public API
        // only). An example, not a product.
        .executableTarget(name: "formato-peek", dependencies: ["FormatoPeek"], path: "Examples/formato-peek", swiftSettings: settings),
        .executableTarget(name: "formato-info", dependencies: ["FormatoCore", "Formato"],
                          path: "Examples/formato-info", swiftSettings: settings),

        // The kit's side of the FormatoKit-vs-RosettaSciIO benchmark (tools/benchmarks/bench.py). Not a product.
        .executableTarget(name: "formato-bench",
                          dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoHDF5", "FormatoMIB", "FormatoMRC", "FormatoMSA",
                                         "FormatoEMPAD", "FormatoTIFF"],
                          path: "tools/benchmarks/formato-bench", swiftSettings: settings),

        // FormatoCore's own tests: the data model, units, lazy = eager, and the pins against RosettaSciIO.
        .testTarget(name: "FormatoCoreTests", dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        // The moved tests, names unchanged (registration §1.2), and the adapters' own.
        // Test support: the pinned acquisition-metadata comparisons (tools/acq-metadata). Not a product.
        .target(name: "FormatoAcquisitionPins", dependencies: ["FormatoCore"], path: "Tests/FormatoAcquisitionPins", swiftSettings: settings),
        .testTarget(name: "FormatoDMTests", dependencies: ["FormatoDM", "FormatoCore", "FormatoAcquisitionPins"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMDTests", dependencies: ["FormatoEMD", "FormatoCore", "FormatoHDF5", "FormatoAcquisitionPins"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoHDF5Tests", dependencies: ["FormatoHDF5", "FormatoCore", "FormatoEMD", "FormatoHDF5ExitProbe"],
                    exclude: ["Fixtures"],
                    swiftSettings: settings),
        // A child process for the quit-barrier tests (`exit` runs the atexit handlers, which a test cannot watch from inside
        // its own process). Not a product; FormatoHDF5Tests depends on it only so `swift test` builds it.
        .executableTarget(name: "FormatoHDF5ExitProbe", dependencies: ["FormatoEMD", "FormatoHDF5"],
                          path: "Tests/FormatoHDF5ExitProbe", swiftSettings: settings),
        // The Velox reader's part of the inherited golden baseline, byte for byte (registration §1.3).
        // Step 2 (docs/registration-step-2.md): the TIFF container and TIFF files as signals, against RosettaSciIO and tifffile.
        .testTarget(name: "FormatoTIFFTests", dependencies: ["FormatoTIFF", "FormatoDM", "FormatoCore", "FormatoAcquisitionPins", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMRCTests", dependencies: ["FormatoMRC", "FormatoCore", "FormatoAcquisitionPins"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMPADTests", dependencies: ["FormatoEMPAD", "FormatoCore"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMIBTests", dependencies: ["FormatoMIB", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoMSATests", dependencies: ["FormatoMSA", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoPeekTests", dependencies: ["FormatoPeek", "FormatoCore", "FormatoHDF5", "FormatoKitTestSupport"], swiftSettings: settings),
        .testTarget(name: "FormatoLoaderTests", dependencies: ["Formato", "FormatoCore"], swiftSettings: settings),
        // The comparisons with the pinned RosettaSciIO, Pint and tifffile values and the inherited golden baseline
        // (`swift test -c release --parallel --skip FormatoKitParityTests` leaves them out). Fixtures stay in the old test folders.
        .target(name: "FormatoKitTestSupport", path: "Tests/FormatoKitTestSupport", swiftSettings: settings),
        .testTarget(name: "FormatoKitParityTests",
                    dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoTIFF", "FormatoKitTestSupport"],
                    swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
