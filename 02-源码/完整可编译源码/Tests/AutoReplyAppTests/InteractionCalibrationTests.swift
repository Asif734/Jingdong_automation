import CoreGraphics
import QianniuOCRCore
import QianniuSenderCore
import XCTest
@testable import AutoReplyApp

final class InteractionCalibrationTests: XCTestCase {
    func testCaptureRegionUsesWindowRelativeRect() {
        let policy = CaptureSelectionPolicy(
            relativeMessageRect: CGRect(x: 0.24, y: 0.16, width: 0.43, height: 0.62)
        )

        XCTAssertEqual(
            policy.absoluteMessageRect(in: CGRect(x: 100, y: 50, width: 1000, height: 800)),
            CGRect(x: 340, y: 178, width: 430, height: 496)
        )
    }

    func testAXButtonUsesPressAndMenuButtonUsesReturn() {
        XCTAssertEqual(
            ComposerSelectionPolicy.resolveSendTrigger(role: "AXButton", actions: ["AXPress"]),
            .accessibilityPress
        )
        XCTAssertEqual(
            ComposerSelectionPolicy.resolveSendTrigger(role: "AXMenuButton", actions: []),
            .returnKeyOnce
        )
        XCTAssertNil(ComposerSelectionPolicy.resolveSendTrigger(role: "AXButton", actions: []))
    }

    func testGenericPressableButtonIsNotClassifiedAsSendControl() {
        XCTAssertEqual(
            CalibrationLabelCategory.classify(
                rawLabel: "刷新",
                role: "AXButton",
                actions: ["AXPress"]
            ),
            "press-control"
        )
    }

    func testFortyPressableControlsSelectOnlyExactNearbySendButton() throws {
        let policies = try InteractionCalibration.calibrate(
            snapshot: .colleagueB40Controls(exactSendLabel: true)
        )

        XCTAssertEqual(policies.sendTrigger, .accessibilityPress)
        XCTAssertEqual(policies.sendDiagnostic.rawPressableCount, 40)
        XCTAssertEqual(policies.sendDiagnostic.eligibleCandidateCount, 1)
        XCTAssertEqual(policies.sendDiagnostic.level, .verified)
    }

    func testAmbiguousFortyControlsFallBackToReturnInsteadOfFailingProfile() throws {
        let profile = try AdaptiveCalibrationEngine.calibrate(
            snapshot: .colleagueB40Controls(exactSendLabel: false)
        )

        XCTAssertEqual(profile.sendPolicy, .returnKeyOnce)
        XCTAssertFalse(profile.requiresFullAdaptiveCalibration)
        XCTAssertEqual(profile.capabilities["sendAX"]?.level, .fallback)
    }
}
