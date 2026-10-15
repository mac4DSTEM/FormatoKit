// swift-tools-version: 6.2
// FormatoKit consumer check: a SEPARATE package that depends on FormatoKit by path and touches the public API every consumer
// reads (a consumer's measured list, typical application uses, the step-1 signal adapters). `package` access does not cross a
// package boundary, so this compiles only if each named symbol is `public`. Gate H1: run.sh runs it with
// FORMATO_HDF5_PATH unset, so a Velox read proves the shipped libhdf5 is found with no setup.
import Foundation
import PackageDescription

let formatoKit = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().deletingLastPathComponent()
    .lastPathComponent

let package = Package(
    name: "ConsumerCheck",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "consumer-check", dependencies: [
            .product(name: "FormatoCore", package: formatoKit),
            .product(name: "FormatoDM", package: formatoKit),
            .product(name: "FormatoEMD", package: formatoKit),
            .product(name: "FormatoHDF5", package: formatoKit),
            .product(name: "FormatoTIFF", package: formatoKit),
            .product(name: "FormatoMRC", package: formatoKit),
            .product(name: "FormatoEMPAD", package: formatoKit),
            .product(name: "FormatoMSA", package: formatoKit),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
