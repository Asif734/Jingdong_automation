import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class TargetSelectionTests: XCTestCase {
    func testCalibratedCapturePolicyMovesAndScalesWithWindow() {
        let policy = CaptureSelectionPolicy(
            relativeMessageRect: CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        )

        XCTAssertEqual(
            TargetSelection.messagePanelFrame(
                policy: policy,
                inside: CGRect(x: 200, y: 100, width: 1000, height: 800)
            ),
            CGRect(x: 450, y: 260, width: 500, height: 480)
        )
    }

    func testPolicySelectsReceptionAndRejectsLargerWorkbench() {
        let candidates = [
            WindowCandidate(id: 1, ownerPID: 30, bundleID: "com.taobao.Aliworkbench", title: "千牛工作台", frame: CGRect(x: 0, y: 0, width: 1500, height: 900), isVisible: true),
            WindowCandidate(id: 2, ownerPID: 30, bundleID: "com.taobao.Aliworkbench", title: "加普威旗舰店:小丹-接待中心", frame: CGRect(x: 20, y: 30, width: 1200, height: 760), isVisible: true),
        ]
        let policy = WindowSelectionPolicy(
            selectedWindowRole: "reception",
            requiredTitleTokens: ["接待中心"],
            minimumRelativeSize: CGSize(width: 500, height: 300),
            requiredRegions: ["conversation-list", "composer"],
            coordinateMapping: CoordinateMapping(
                pointsToPixelsX: 2,
                pointsToPixelsY: 2,
                originOffsetX: 0,
                originOffsetY: 0,
                maximumResidual: 3
            )
        )

        XCTAssertEqual(TargetSelection.qianniuWindow(from: candidates, policy: policy)?.id, 2)
    }

    func testCoordinateMappingAcceptsMeasuredOnePixelRepresentationDifference() {
        let mapping = CoordinateMapping(
            pointsToPixelsX: 2,
            pointsToPixelsY: 2,
            originOffsetX: 10,
            originOffsetY: 20,
            maximumResidual: 3
        )

        XCTAssertTrue(mapping.matches(
            accessibility: CGRect(x: 10, y: 20, width: 1200, height: 800),
            capture: CGRect(x: 31, y: 59, width: 2399, height: 1601)
        ))
        XCTAssertFalse(mapping.matches(
            accessibility: CGRect(x: 10, y: 20, width: 1200, height: 800),
            capture: CGRect(x: 120, y: 180, width: 2200, height: 1400)
        ))
    }

    func testSelectsVisibleQianniuReceptionWindow() {
        let candidates = [
            WindowCandidate(id: 1, ownerPID: 20, bundleID: "com.apple.TextEdit", title: "接待中心", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isVisible: true),
            WindowCandidate(id: 2, ownerPID: 30, bundleID: "com.taobao.Aliworkbench", title: "千牛首页", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isVisible: true),
            WindowCandidate(id: 3, ownerPID: 30, bundleID: "com.taobao.Aliworkbench", title: "加普威旗舰店:小丹-接待中心", frame: CGRect(x: 20, y: 30, width: 1200, height: 800), isVisible: true),
        ]

        XCTAssertEqual(TargetSelection.qianniuWindow(from: candidates)?.id, 3)
    }

    func testRejectsInvisibleAndZeroSizedWindows() {
        let candidates = [
            WindowCandidate(id: 1, ownerPID: 30, bundleID: "com.taobao.Aliworkbench", title: "接待中心", frame: .zero, isVisible: true),
            WindowCandidate(id: 2, ownerPID: 30, bundleID: "com.taobao.Aliworkbench", title: "接待中心", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isVisible: false),
        ]

        XCTAssertNil(TargetSelection.qianniuWindow(from: candidates))
    }

    func testSelectsVisibleMessageRecordContainerInsideWindow() {
        let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
        let candidates = [
            AXCandidate(role: "AXGroup", title: "消息记录", description: nil, value: nil, frame: CGRect(x: 1400, y: 100, width: 200, height: 300)),
            AXCandidate(role: "AXScrollArea", title: nil, description: "消息记录", value: nil, frame: CGRect(x: 900, y: 150, width: 350, height: 700)),
            AXCandidate(role: "AXButton", title: "消息记录", description: nil, value: nil, frame: CGRect(x: 850, y: 120, width: 80, height: 28)),
        ]

        let selected = TargetSelection.messagePanel(from: candidates, inside: window)

        XCTAssertEqual(selected?.role, "AXScrollArea")
        XCTAssertEqual(selected?.frame, CGRect(x: 900, y: 150, width: 350, height: 700))
    }

    func testRelativeCropClampsPanelToWindow() {
        let crop = TargetSelection.relativeCrop(
            panel: CGRect(x: 850, y: 80, width: 400, height: 700),
            window: CGRect(x: 100, y: 100, width: 1000, height: 600)
        )

        XCTAssertEqual(crop, CGRect(x: 750, y: 0, width: 250, height: 600))
    }

    func testExpandsMessageTabAnchorToDockedRightPanel() {
        let frame = TargetSelection.expandedMessagePanelFrame(
            anchor: CGRect(x: 828, y: 63, width: 481, height: 31),
            window: CGRect(x: 0, y: 0, width: 1309, height: 729)
        )

        XCTAssertEqual(frame, CGRect(x: 828, y: 63, width: 481, height: 666))
    }

    func testSelectsRefreshButtonNextToMessageRecordAfterWindowTranslation() {
        let window = CGRect(x: 500, y: 300, width: 1309, height: 729)
        let tab = AXCandidate(
            role: "AXGroup",
            title: "消息记录",
            description: nil,
            value: nil,
            frame: CGRect(x: 1604, y: 363, width: 135, height: 31)
        )
        let candidates = [
            AXCandidate(
                role: "AXButton",
                title: "刷新",
                description: nil,
                value: nil,
                frame: CGRect(x: 700, y: 500, width: 30, height: 30)
            ),
            AXCandidate(
                role: "AXButton",
                title: "刷新",
                description: nil,
                value: nil,
                frame: CGRect(x: 1742, y: 363, width: 31, height: 31)
            ),
        ]

        XCTAssertEqual(
            TargetSelection.refreshButton(from: candidates, nextTo: tab, inside: window)?.frame,
            CGRect(x: 1742, y: 363, width: 31, height: 31)
        )
    }

    func testSelectsRefreshButtonAfterWindowAndControlsAreScaled() {
        let window = CGRect(x: 80, y: 40, width: 980, height: 600)
        let tab = AXCandidate(
            role: "AXGroup",
            title: "消息记录",
            description: nil,
            value: nil,
            frame: CGRect(x: 760, y: 90, width: 160, height: 42)
        )
        let expected = AXCandidate(
            role: "AXButton",
            title: nil,
            description: "刷新",
            value: nil,
            frame: CGRect(x: 930, y: 93, width: 36, height: 36)
        )
        let candidates = [
            AXCandidate(
                role: "AXButton",
                title: "刷新",
                description: nil,
                value: nil,
                frame: CGRect(x: 500, y: 98, width: 36, height: 36)
            ),
            expected,
        ]

        XCTAssertEqual(TargetSelection.refreshButton(from: candidates, nextTo: tab, inside: window), expected)
    }

    func testRejectsRefreshButtonsOutsideWindowOrFarFromMessageRecordRow() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let tab = AXCandidate(
            role: "AXGroup",
            title: "消息记录",
            description: nil,
            value: nil,
            frame: CGRect(x: 700, y: 60, width: 180, height: 32)
        )
        let candidates = [
            AXCandidate(role: "AXButton", title: "刷新", description: nil, value: nil,
                        frame: CGRect(x: 1010, y: 60, width: 30, height: 30)),
            AXCandidate(role: "AXButton", title: "刷新", description: nil, value: nil,
                        frame: CGRect(x: 900, y: 300, width: 30, height: 30)),
        ]

        XCTAssertNil(TargetSelection.refreshButton(from: candidates, nextTo: tab, inside: window))
    }
}
