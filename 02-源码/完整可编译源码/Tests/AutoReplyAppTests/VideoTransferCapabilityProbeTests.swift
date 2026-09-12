import XCTest
@testable import AutoReplyApp

private struct FixedVideoCapabilityRunner: VideoTransferCapabilityRunning {
    let reachable: Bool
    func hostnameIsReachable(_ hostname: String, timeout: Duration) async -> Bool {
        reachable
    }
}

final class VideoTransferCapabilityProbeTests: XCTestCase {
    func testAvailableHelpersAndHostnameProduceBothTransferCapabilities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let curl = root.appendingPathComponent("curl")
        let dig = root.appendingPathComponent("dig")
        for url in [curl, dig] {
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let result = await VideoTransferCapabilityProbe(
            curlURL: curl,
            digURL: dig,
            runner: FixedVideoCapabilityRunner(reachable: true)
        ).probe()

        XCTAssertEqual(result["videoDownloadSystem"]?.level, .verified)
        XCTAssertEqual(result["videoDownloadAlternate"]?.level, .verified)
    }

    func testMissingAlternateHelpersKeepsSystemRouteUsable() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = await VideoTransferCapabilityProbe(
            curlURL: root.appendingPathComponent("missing-curl"),
            digURL: root.appendingPathComponent("missing-dig"),
            runner: FixedVideoCapabilityRunner(reachable: true)
        ).probe()

        XCTAssertEqual(result["videoDownloadSystem"]?.level, .verified)
        XCTAssertEqual(result["videoDownloadAlternate"]?.level, .unavailable)
    }
}
