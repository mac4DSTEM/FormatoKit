// swift-tools-version: 6.2
// README consumer: a SEPARATE package that depends on FormatoKit by path and compiles the Swift code blocks of the repository's
// README.md, pasted verbatim, so the README's first ten minutes is proven to build and to read the files it names. run.sh
// (tools/consumer-check) builds it in Debug with 0 warnings and runs it with FORMATO_HDF5_PATH unset.
import Foundation
import PackageDescription

let formatoKit = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().lastPathComponent

let package = Package(
    name: "ReadmeCheck",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../../..")],
    targets: [
        .executableTarget(name: "readme-check", dependencies: [
            .product(name: "FormatoCore", package: formatoKit),
            .product(name: "FormatoDM", package: formatoKit),
            .product(name: "FormatoEMD", package: formatoKit),
            .product(name: "FormatoTIFF", package: formatoKit),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
