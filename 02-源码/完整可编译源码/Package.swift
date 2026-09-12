// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QianniuAutoReply",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AutoReplyCore", targets: ["AutoReplyCore"]),
               .executable(name: "AutoReplyApp", targets: ["AutoReplyApp"]),
               .executable(name: "QianniuInstallerApp", targets: ["QianniuInstallerApp"])],
    dependencies: [.package(path: "components/batch-source"), .package(path: "components/ocr-source"),
                   .package(path: "components/sender-source"), .package(path: "components/unread-source")],
    targets: [
        .target(name: "AutoReplyCore", dependencies: [
            .product(name: "CustomerReplyBatchAppSupport", package: "batch-source"),
            .product(name: "CustomerReplyBatchCore", package: "batch-source")
        ]),
        .testTarget(name: "AutoReplyCoreTests", dependencies: ["AutoReplyCore"]),
        .executableTarget(name: "AutoReplyApp", dependencies: ["AutoReplyCore",
            .product(name: "QianniuOCRAppSupport", package: "ocr-source"),
            .product(name: "QianniuOCRCore", package: "ocr-source"),
            .product(name: "QianniuSenderAppSupport", package: "sender-source"),
            .product(name: "QianniuSenderCore", package: "sender-source"),
            .product(name: "UnreadCore", package: "unread-source")],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("Speech")]),
        .testTarget(name: "AutoReplyAppTests", dependencies: ["AutoReplyApp"]),
        .executableTarget(name: "QianniuInstallerApp"),
        .testTarget(name: "QianniuInstallerAppTests", dependencies: ["QianniuInstallerApp"])
    ]
)
