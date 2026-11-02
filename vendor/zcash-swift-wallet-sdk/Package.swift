// swift-tools-version:5.6
// Vendored by Zignal from zcash-swift-wallet-sdk 3.0.0 (MIT), with the changes described in
// ZIGNAL-PATCHES.md. libzcashlc is built from this folder's Rust source, which is on the NU7
// crates, not taken from the upstream 3.0.0 release.
import PackageDescription

// libzcashlc comes from LocalPackages/, which Scripts/build-ios-ffi.sh creates. There is no
// fallback to the upstream 3.0.0 binary on purpose: that binary can't follow the chain after NU7,
// so without LocalPackages/ package resolution fails instead of quietly linking it.
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.2"),
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
    .package(name: "libzcashlc", path: "LocalPackages")
]

let sdkDependencies: [Target.Dependency] = [
    .product(name: "SQLite", package: "SQLite.swift"),
    .product(name: "GRPC", package: "grpc-swift"),
    .product(name: "libzcashlc", package: "libzcashlc")
]

var targets: [Target] = []

targets.append(contentsOf: [
    .target(
        name: "ZcashLightClientKit",
        dependencies: sdkDependencies,
        exclude: [
            "Modules/Service/GRPC/ProtoBuf/proto/proposal.proto",
            "Error/Sourcery/"
        ],
        resources: [
            .copy("Resources/checkpoints")
        ]
    )
    // Zignal: upstream test targets removed; the tests are not vendored.
])

let package = Package(
    name: "ZcashLightClientKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ZcashLightClientKit",
            targets: ["ZcashLightClientKit"]
        )
    ],
    dependencies: dependencies,
    targets: targets
)
