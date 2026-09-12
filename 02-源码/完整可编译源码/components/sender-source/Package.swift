// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QianniuAutoSender",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "QianniuSenderCore", targets: ["QianniuSenderCore"]),
        .library(name: "QianniuSenderAppSupport", targets: ["QianniuSenderAppSupport"]),
        .executable(name: "QianniuAutoSender", targets: ["QianniuAutoSender"]),
    ],
    targets: [
        .target(name: "QianniuSenderCore"),
        .target(
            name: "QianniuSenderAppSupport",
            dependencies: ["QianniuSenderCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "QianniuAutoSender",
            dependencies: ["QianniuSenderCore", "QianniuSenderAppSupport"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "QianniuSenderCoreTests", dependencies: ["QianniuSenderCore"]),
        .testTarget(
            name: "QianniuSenderAppSupportTests",
            dependencies: ["QianniuSenderAppSupport"]
        ),
    ]
)
