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
// libhdf5 ships inside FormatoHDF5 as a resource (the readers dlopen it): `swift build` and `swift test` need no setup.
// macOS 15 / iOS 18 (0.2.1). The shipped dylibs are arm64 with minos 15. FormatoHDF5 and FormatoEMD load libhdf5 at run time and
// are macOS-only in practice: on iOS they build, but a Velox read refuses (no libhdf5 for iOS). The other modules are pure Swift.
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

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
        .library(name: "FormatoMSA", targets: ["FormatoMSA"]),
    ],
    targets: [
        // The data model every reader returns: arrays, axes, units, metadata with provenance, lazy signals; cancellation.
        .target(name: "FormatoCore", swiftSettings: settings),
        // HDF5: the process-wide HDF5 lock and quit barrier (HDF5Serial), the shipped libhdf5. Later: hspy, the sidecar.
        .target(name: "FormatoHDF5", resources: [.copy("Resources/hdf5")], swiftSettings: settings),
        // Gatan DigitalMicrograph .dm3 / .dm4: DM4Experiment (inherited reader, registration step 1 §1.1) and the signal adapter.
        .target(name: "FormatoDM", dependencies: ["FormatoCore"], swiftSettings: settings),
        // EMD: Velox (inherited reader, registration step 1 §1.1) and its image adapter. Later: NCEM / Berkeley EMD.
        .target(name: "FormatoEMD", dependencies: ["FormatoCore", "FormatoHDF5"], swiftSettings: settings),
        // Empty until registered; their scope is in their one source file's doc comment.
        .target(name: "FormatoTIFF", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoMRC", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoEMPAD", dependencies: ["FormatoCore"], swiftSettings: settings),
        .target(name: "FormatoMSA", dependencies: ["FormatoCore"], swiftSettings: settings),
        // The first ten minutes: `swift run formato-info <file>` prints every signal of a DM, Velox or TIFF file (public API
        // only). An example, not a product.
        .executableTarget(name: "formato-info", dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD", "FormatoTIFF"],
                          path: "Examples/formato-info", swiftSettings: settings),

        // FormatoCore's own tests: the data model, units, lazy = eager, and the pins against RosettaSciIO.
        .testTarget(name: "FormatoCoreTests", dependencies: ["FormatoCore", "FormatoDM", "FormatoEMD"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        // The moved tests, names unchanged (registration §1.2), and the adapters' own.
        .testTarget(name: "FormatoDMTests", dependencies: ["FormatoDM", "FormatoCore"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoEMDTests", dependencies: ["FormatoEMD", "FormatoCore", "FormatoHDF5"],
                    exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "FormatoHDF5Tests", dependencies: ["FormatoHDF5", "FormatoEMD", "FormatoHDF5ExitProbe"],
                    swiftSettings: settings),
        // A child process for the quit-barrier tests (`exit` runs the atexit handlers, which a test cannot watch from inside
        // its own process). Not a product; FormatoHDF5Tests depends on it only so `swift test` builds it.
        .executableTarget(name: "FormatoHDF5ExitProbe", dependencies: ["FormatoEMD", "FormatoHDF5"],
                          path: "Tests/FormatoHDF5ExitProbe", swiftSettings: settings),
        // The Velox reader's part of the inherited golden baseline, byte for byte (registration §1.3).
        // Step 2 (docs/registration-step-2.md): the TIFF container and TIFF files as signals, against RosettaSciIO and tifffile.
        .testTarget(name: "FormatoTIFFTests", dependencies: ["FormatoTIFF", "FormatoCore"], exclude: ["Fixtures"],
                    swiftSettings: settings),
        .testTarget(name: "FormatoGoldenTests", dependencies: ["FormatoEMD", "FormatoCore"], exclude: ["Fixtures"],
                    swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
