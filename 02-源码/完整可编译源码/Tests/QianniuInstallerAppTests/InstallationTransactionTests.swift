import CryptoKit
import Foundation
import XCTest
@testable import QianniuInstallerApp

final class InstallationTransactionTests: XCTestCase {
    func testUsesUserApplicationsWhenSystemApplicationsIsNotWritable() throws {
        let root = temporaryDirectory()
        let transaction = InstallationTransaction(
            systemApplicationsURL: root.appendingPathComponent("system"),
            userApplicationsURL: root.appendingPathComponent("user"),
            isWritable: { $0.lastPathComponent == "user" },
            verifySignature: { _ in true },
            executableArchitectures: { _ in ["arm64"] }
        )

        XCTAssertEqual(
            try transaction.chooseDestination(),
            root.appendingPathComponent("user/千牛全自动客服-版本B.app")
        )
    }

    func testHashFailureLeavesExistingApplicationUntouched() throws {
        let root = temporaryDirectory()
        let applications = root.appendingPathComponent("Applications")
        let destination = applications.appendingPathComponent("千牛全自动客服-版本B.app")
        try writeApp(destination, executable: Data("old".utf8))
        let payload = root.appendingPathComponent("payload.app")
        try writeApp(payload, executable: Data("new".utf8))
        let manifest = DistributionManifest(
            schemaVersion: 1,
            appVersion: "1",
            architecture: "arm64",
            files: [DistributionFile(path: "Contents/MacOS/AutoReplyApp", sha256: "bad")]
        )
        let transaction = InstallationTransaction(
            systemApplicationsURL: applications,
            userApplicationsURL: applications,
            isWritable: { _ in true },
            verifySignature: { _ in true },
            executableArchitectures: { _ in ["arm64"] }
        )

        XCTAssertThrowsError(try transaction.install(
            payload: payload,
            manifest: manifest,
            destinations: InstallationDestinations(system: applications, user: applications)
        ))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/AutoReplyApp")),
            Data("old".utf8)
        )
    }

    func testPostRenameFailureRestoresBackup() throws {
        let root = temporaryDirectory()
        let applications = root.appendingPathComponent("Applications")
        let destination = applications.appendingPathComponent("千牛全自动客服-版本B.app")
        try writeApp(destination, executable: Data("old".utf8))
        let payload = root.appendingPathComponent("payload.app")
        try writeApp(payload, executable: Data("new".utf8))
        let manifest = try DistributionManifest.make(for: payload, version: "2")
        let transaction = InstallationTransaction(
            systemApplicationsURL: applications,
            userApplicationsURL: applications,
            isWritable: { _ in true },
            verifySignature: { url in url.lastPathComponent != "千牛全自动客服-版本B.app" },
            executableArchitectures: { _ in ["arm64"] }
        )

        XCTAssertThrowsError(try transaction.install(
            payload: payload,
            manifest: manifest,
            destinations: InstallationDestinations(system: applications, user: applications)
        ))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/AutoReplyApp")),
            Data("old".utf8)
        )
    }

    private func writeApp(_ url: URL, executable: Data) throws {
        let binary = url.appendingPathComponent("Contents/MacOS/AutoReplyApp")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executable.write(to: binary)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
