// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QianniuVideoDirectProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QianniuVideoProbeCore", targets: ["QianniuVideoProbeCore"]),
        .executable(name: "QianniuVideoProbeApp", targets: ["QianniuVideoProbeApp"])
    ],
    targets: [
        .target(name: "QianniuVideoProbeCore"),
        .executableTarget(
            name: "QianniuVideoProbeApp",
            dependencies: ["QianniuVideoProbeCore"]
        ),
        .testTarget(
            name: "QianniuVideoProbeCoreTests",
            dependencies: ["QianniuVideoProbeCore"]
        )
    ]
)
