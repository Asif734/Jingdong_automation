// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QianniuOCR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QianniuOCRCore", targets: ["QianniuOCRCore"]),
        .library(name: "QianniuOCRAppSupport", targets: ["QianniuOCRAppSupport"]),
        .executable(name: "QianniuOCRApp", targets: ["QianniuOCRApp"]),
    ],
    dependencies: [
        .package(path: "../../Tools/QianniuVideoDirectProbe"),
    ],
    targets: [
        .target(name: "QianniuOCRCore"),
        .target(
            name: "QianniuOCRAppSupport",
            dependencies: [
                "QianniuOCRCore",
                .product(name: "QianniuVideoProbeCore", package: "QianniuVideoDirectProbe"),
            ],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "QianniuOCRApp",
            dependencies: ["QianniuOCRAppSupport"]
        ),
        .testTarget(
            name: "QianniuOCRCoreTests",
            dependencies: ["QianniuOCRCore"]
        ),
        .testTarget(
            name: "QianniuOCRAppSupportTests",
            dependencies: ["QianniuOCRAppSupport", "QianniuOCRCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
