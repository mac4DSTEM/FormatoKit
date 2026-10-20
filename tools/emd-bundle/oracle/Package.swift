// swift-tools-version: 6.2
import PackageDescription
let settings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"]),
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
let package = Package(
    name: "oracle",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "kits/SpectroKit"), .package(path: "kits/FormatoKit"), .package(path: "kits/DiffractoKit"),
        .package(path: "kits/CuboKit"), .package(path: "kits/ImagoKit"),
    ],
    targets: [
        .target(name: "DSTEMCore",
            dependencies: [.product(name: "SpectroCore", package: "SpectroKit"), .product(name: "SpectroEDX", package: "SpectroKit"),
                           .product(name: "FormatoCore", package: "FormatoKit"), .product(name: "FormatoDM", package: "FormatoKit"),
                           .product(name: "FormatoEMD", package: "FormatoKit"), .product(name: "FormatoHDF5", package: "FormatoKit"),
                           .product(name: "DiffractoCore", package: "DiffractoKit"), .product(name: "DiffractoScattering", package: "DiffractoKit"),
                           .product(name: "DiffractoGeometry", package: "DiffractoKit"), .product(name: "DiffractoOrientation", package: "DiffractoKit"),
                           .product(name: "CuboCore", package: "CuboKit"), .product(name: "CuboVirtual", package: "CuboKit"),
                           .product(name: "CuboPhase", package: "CuboKit"), .product(name: "ImagoCore", package: "ImagoKit"),
                           .product(name: "ImagoFFT", package: "ImagoKit")],
            path: "Sources/DSTEMCore", swiftSettings: settings),
        .executableTarget(name: "oracle", dependencies: ["DSTEMCore", .product(name: "FormatoHDF5", package: "FormatoKit"), .product(name: "SpectroCore", package: "SpectroKit")],
            path: "Sources/oracle", swiftSettings: settings),
    ])
