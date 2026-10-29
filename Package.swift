// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// FormatoKit: electron-microscopy file formats for the Mac, checked bit for bit against RosettaSciIO at a pinned commit.
// Swift 6 mode, no unsafe flags. What one module needs from another is `package`, never `public`; what a consumer reads
// is `public` and is guarded by tools/consumer-check. libhdf5 ships as three binary XCFramework targets (arm64 macOS,
// built by tools/xcframework/build.sh); with FORMATO_LOCAL_XCFRAMEWORKS set they are the local build in dist/xcframeworks.
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
    platforms: [.macOS(.v15)],
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
        // Gatan DigitalMicrograph .dm3 / .dm4: DM4Experiment (inherited reader) and the signal adapter.
        .target(name: "FormatoDM", dependencies: ["FormatoCore"], swiftSettings: settings),
        // EMD: Velox (inherited reader) and its image adapter. Later: NCEM / Berkeley EMD.
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
        // Examples, not products. `swift run formato-peek <file>`: one decimated frame and the header facts.
        .executableTarget(name: "formato-peek", dependencies: ["FormatoPeek"], path: "Examples/formato-peek", swiftSettings: settings),
        // The first ten minutes: `swift run formato-info <file>` prints every signal of a DM, Velox or TIFF file (public API only).
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
        // Test support, not a product: the fixture folders (FixtureDirs) and the pinned acquisition-metadata comparisons
        // (tools/acq-metadata).
        .target(name: "FormatoKitTestSupport", dependencies: ["FormatoCore"], path: "Tests/FormatoKitTestSupport", swiftSettings: settings),
        .testTarget(name: "FormatoDMTests", dependencies: ["FormatoDM", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMDTests", dependencies: ["FormatoEMD", "FormatoCore", "FormatoHDF5", "FormatoKitTestSupport"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoHDF5Tests", dependencies: ["FormatoHDF5", "FormatoCore", "FormatoEMD", "FormatoHDF5ExitProbe"],
                    exclude: ["Fixtures"],
                    swiftSettings: settings),
        // A child process for the quit-barrier tests (`exit` runs the atexit handlers, which a test cannot watch from inside
        // its own process). Not a product; FormatoHDF5Tests depends on it only so `swift test` builds it.
        .executableTarget(name: "FormatoHDF5ExitProbe", dependencies: ["FormatoEMD", "FormatoHDF5"],
                          path: "Tests/FormatoHDF5ExitProbe", swiftSettings: settings),
        // The TIFF container and TIFF files as signals, against RosettaSciIO and tifffile.
        .testTarget(name: "FormatoTIFFTests", dependencies: ["FormatoTIFF", "FormatoDM", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMRCTests", dependencies: ["FormatoMRC", "FormatoCore", "FormatoKitTestSupport"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMPADTests", dependencies: ["FormatoEMPAD", "FormatoCore"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoMIBTests", dependencies: ["FormatoMIB", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoMSATests", dependencies: ["FormatoMSA", "FormatoCore"], exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoPeekTests", dependencies: ["FormatoPeek", "FormatoCore", "FormatoHDF5", "FormatoKitTestSupport"], swiftSettings: settings),
        .testTarget(name: "FormatoLoaderTests", dependencies: ["Formato", "FormatoCore"], swiftSettings: settings),
        // The comparisons with the pinned RosettaSciIO, Pint and tifffile values and the inherited golden baseline, byte for byte
        // (`swift test -c release --parallel --skip FormatoKitParityTests` leaves them out). Fixtures stay in the old test folders.
        .testTarget(name: "FormatoKitParityTests",
                    dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoTIFF", "FormatoKitTestSupport"],
                    swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
