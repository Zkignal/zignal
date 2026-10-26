// swift-tools-version:5.6
// Vendored by Zignal from zcash-swift-wallet-sdk 3.0.0 (MIT), with the stop fix described in
// ZIGNAL-PATCHES.md. Same prebuilt libzcashlc binary and checksum as the upstream release.
import PackageDescription
import Foundation

// Automatically detect local FFI development mode.
// When LocalPackages/Package.swift exists (created by Scripts/init-local-ffi.sh),
// the SDK builds against the locally-built FFI instead of the pre-built binary
// from GitHub Releases. Run `rm -rf LocalPackages` to switch back.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let useLocalFFI = FileManager.default.fileExists(atPath: packageDir + "/LocalPackages/Package.swift")

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.2"),
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3")
]

var sdkDependencies: [Target.Dependency] = [
    .product(name: "SQLite", package: "SQLite.swift"),
    .product(name: "GRPC", package: "grpc-swift"),
]

var targets: [Target] = []

if useLocalFFI {
    dependencies.append(.package(name: "libzcashlc", path: "LocalPackages"))
    sdkDependencies.append(.product(name: "libzcashlc", package: "libzcashlc"))
} else {
    // Binary target for the Rust FFI library
    // Updated by Scripts/release.sh during the release process
    targets.append(
        .binaryTarget(
            name: "libzcashlc",
            url: "https://github.com/zcash/zcash-swift-wallet-sdk/releases/download/3.0.0/libzcashlc.xcframework.zip",
            checksum: "122bff46bb5b34ee354170e261d9ac7f61efe09962a411a99419782cb94857fc"
        )
    )
    sdkDependencies.append("libzcashlc")
}

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
