// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QianniuCodexBatchRunner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CustomerReplyBatchCore", targets: ["CustomerReplyBatchCore"]),
        .library(name: "CustomerReplyBatchAppSupport", targets: ["CustomerReplyBatchAppSupport"]),
        .executable(name: "AI客服-Codex批处理", targets: ["CustomerReplyBatchApp"])
    ],
    targets: [
        .target(name: "CustomerReplyBatchCore"),
        .target(
            name: "CustomerReplyBatchAppSupport",
            dependencies: ["CustomerReplyBatchCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CustomerReplyBatchApp",
            dependencies: ["CustomerReplyBatchCore", "CustomerReplyBatchAppSupport"]
        ),
        .testTarget(name: "CustomerReplyBatchCoreTests", dependencies: ["CustomerReplyBatchCore"]),
        .testTarget(name: "CustomerReplyBatchAppSupportTests", dependencies: ["CustomerReplyBatchCore", "CustomerReplyBatchAppSupport"])
    ]
)
