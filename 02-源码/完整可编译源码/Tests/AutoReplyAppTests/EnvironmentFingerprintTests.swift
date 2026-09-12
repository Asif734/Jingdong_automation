import CoreGraphics
import XCTest
@testable import AutoReplyApp

final class EnvironmentFingerprintTests: XCTestCase {
    func testFingerprintIgnoresCustomerTextButTracksStructure() throws {
        let first = CalibrationSnapshot.fixture(customerLabel: "customer-A", rowHeight: 66)
        let second = CalibrationSnapshot.fixture(customerLabel: "customer-B", rowHeight: 66)

        XCTAssertEqual(
            EnvironmentFingerprint.make(from: first).digest,
            EnvironmentFingerprint.make(from: second).digest
        )
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(encoded.contains("customer-A"))
    }

    func testFingerprintChangesForQianniuBuildOrStructure() {
        let original = CalibrationSnapshot.fixture(qianniuBuild: "1", rowHeight: 66)
        let changedBuild = CalibrationSnapshot.fixture(qianniuBuild: "2", rowHeight: 66)
        let changedStructure = CalibrationSnapshot.fixture(qianniuBuild: "1", rowHeight: 34)

        XCTAssertNotEqual(
            EnvironmentFingerprint.make(from: original).digest,
            EnvironmentFingerprint.make(from: changedBuild).digest
        )
        XCTAssertNotEqual(
            EnvironmentFingerprint.make(from: original).digest,
            EnvironmentFingerprint.make(from: changedStructure).digest
        )
    }
}

private extension CalibrationSnapshot {
    static func fixture(
        customerLabel: String = "fixture-customer",
        qianniuBuild: String = "1",
        rowHeight: CGFloat
    ) -> CalibrationSnapshot {
        _ = customerLabel // Raw customer text is categorized before snapshot creation.
        let window = CGRect(x: 20, y: 40, width: 1200, height: 800)
        return CalibrationSnapshot(
            macOSBuild: "25G83",
            architecture: "arm64",
            qianniuVersion: "9.97.74",
            qianniuBuild: qianniuBuild,
            qianniuRuntimeArchitecture: "arm64",
            displays: [CalibrationDisplay(relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 2)],
            windows: [CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                captureFrame: CGRect(x: 40, y: 80, width: 2400, height: 1600),
                minimized: false,
                focused: true,
                regionCategories: ["conversation-list", "chat", "composer"]
            )],
            nodes: [
                CalibrationAXNode(
                    id: 1,
                    parentID: nil,
                    role: "AXGroup",
                    actionNames: ["AXPress"],
                    labelCategory: "identity-like",
                    relativeFrame: CGRect(x: 0.02, y: 0.15, width: 0.28, height: rowHeight / window.height),
                    hasValue: false
                )
            ]
        )
    }
}
