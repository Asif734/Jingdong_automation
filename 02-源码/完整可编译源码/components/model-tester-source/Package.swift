// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrozziieModelTester",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GrozziieModelTesterCore", targets: ["GrozziieModelTesterCore"]),
        .executable(name: "GrozziieModelTesterApp", targets: ["GrozziieModelTesterApp"]),
    ],
    dependencies: [
        .package(path: "../batch-source"),
    ],
    targets: [
        .target(
            name: "GrozziieModelTesterCore",
            dependencies: [
                .product(name: "CustomerReplyBatchCore", package: "batch-source"),
                .product(name: "CustomerReplyBatchAppSupport", package: "batch-source"),
            ]
        ),
        .executableTarget(
            name: "GrozziieModelTesterApp",
            dependencies: ["GrozziieModelTesterCore"]
        ),
        .testTarget(
            name: "GrozziieModelTesterCoreTests",
            dependencies: [
                "GrozziieModelTesterCore",
                .product(name: "CustomerReplyBatchAppSupport", package: "batch-source"),
            ]
        ),
        .testTarget(
            name: "GrozziieModelTesterAppTests",
            dependencies: ["GrozziieModelTesterApp", "GrozziieModelTesterCore"]
        ),
    ]
)
