// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "QianniuUnreadAssistant", platforms: [.macOS(.v14)], products: [
    .library(name: "UnreadCore", targets: ["UnreadCore"]),
    .executable(name: "UnreadApp", targets: ["UnreadApp"])
], targets: [.target(name: "UnreadCore"), .executableTarget(name: "UnreadApp", dependencies: ["UnreadCore"]), .testTarget(name: "UnreadCoreTests", dependencies: ["UnreadCore"]), .testTarget(name: "UnreadAppTests", dependencies: ["UnreadApp"])])
