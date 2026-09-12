import CoreGraphics
import XCTest
@testable import AutoReplyApp

final class WindowCalibrationTests: XCTestCase {
    func testCalibrationMatchesAXAndCaptureUsingMeasuredScale() throws {
        let policy = try WindowCalibration.calibrate(snapshot: .twoXScaleReceptionFixture)

        XCTAssertEqual(policy.coordinateMapping.pointsToPixelsX, 2, accuracy: 0.001)
        XCTAssertEqual(policy.coordinateMapping.pointsToPixelsY, 2, accuracy: 0.001)
        XCTAssertEqual(policy.coordinateMapping.originOffsetX, 10, accuracy: 0.001)
        XCTAssertEqual(policy.coordinateMapping.originOffsetY, 20, accuracy: 0.001)
    }

    func testReceptionOutranksWorkbenchWithIndependentEvidence() throws {
        let policy = try WindowCalibration.calibrate(snapshot: .receptionAndWorkbenchFixture)

        XCTAssertEqual(policy.selectedWindowRole, "reception")
        XCTAssertTrue(policy.requiredRegions.contains("conversation-list"))
        XCTAssertTrue(policy.requiredRegions.contains("composer"))
        XCTAssertTrue(policy.requiredTitleTokens.contains("接待中心"))
    }

    func testCalibrationRejectsWindowWithOnlyOneReceptionSignal() {
        let snapshot = CalibrationSnapshot.windowFixture(windows: [
            CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 10, y: 20, width: 1200, height: 800),
                captureFrame: CGRect(x: 30, y: 60, width: 2400, height: 1600),
                minimized: false,
                focused: true,
                regionCategories: []
            )
        ])

        XCTAssertThrowsError(try WindowCalibration.calibrate(snapshot: snapshot))
    }
}

private extension CalibrationSnapshot {
    static var twoXScaleReceptionFixture: CalibrationSnapshot {
        windowFixture(windows: [
            CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 10, y: 20, width: 1200, height: 800),
                captureFrame: CGRect(x: 30, y: 60, width: 2400, height: 1600),
                minimized: false,
                focused: true,
                regionCategories: ["conversation-list", "chat", "composer"]
            )
        ])
    }

    static var receptionAndWorkbenchFixture: CalibrationSnapshot {
        windowFixture(windows: [
            CalibrationWindow(
                roleCategory: "workbench",
                relativeFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                captureFrame: CGRect(x: 0, y: 0, width: 2560, height: 1600),
                minimized: false,
                focused: true,
                regionCategories: ["navigation"]
            ),
            CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 20, y: 30, width: 1200, height: 760),
                captureFrame: CGRect(x: 40, y: 60, width: 2400, height: 1520),
                minimized: false,
                focused: false,
                regionCategories: ["conversation-list", "chat", "composer"]
            )
        ])
    }

    static func windowFixture(windows: [CalibrationWindow]) -> CalibrationSnapshot {
        CalibrationSnapshot(
            macOSBuild: "25G83",
            architecture: "arm64",
            qianniuVersion: "9.97.74",
            qianniuBuild: "20260812105806",
            qianniuRuntimeArchitecture: "arm64",
            displays: [CalibrationDisplay(
                relativeFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                scale: 2
            )],
            windows: windows,
            nodes: []
        )
    }
}
