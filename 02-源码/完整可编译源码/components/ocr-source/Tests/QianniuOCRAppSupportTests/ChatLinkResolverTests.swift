import CoreGraphics
import XCTest
@testable import QianniuOCRAppSupport
import QianniuOCRCore

@MainActor
final class ChatLinkResolverTests: XCTestCase {
    func testOwnerActivationSelectsOnlyTheExactReceptionWindowAndNeverFallsBack() {
        let titles = [
            "加普威旗舰店:小丹-千牛工作台",
            "加普威旗舰店:小丹-接待中心",
            "视频播放"
        ]

        XCTAssertEqual(
            SystemLinkApplicationActivator.matchingWindowIndex(
                titles: titles,
                targetTitle: "加普威旗舰店:小丹-接待中心"
            ),
            1
        )
        XCTAssertNil(
            SystemLinkApplicationActivator.matchingWindowIndex(
                titles: titles,
                targetTitle: "不存在的接待中心"
            )
        )
        XCTAssertNil(
            SystemLinkApplicationActivator.matchingWindowIndex(
                titles: titles,
                targetTitle: "加普威旗舰店:小丹-千牛工作台"
            )
        )
    }

    func testCopyTargetMovesWithPanelInsteadOfUsingFixedScreenCoordinates() throws {
        let line = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 14)
        )
        let imageSize = CGSize(width: 800, height: 600)
        let firstPanel = CGRect(x: 100, y: 200, width: 800, height: 600)
        let movedPanel = firstPanel.offsetBy(dx: 317, dy: 121)

        let first = try XCTUnwrap(
            LinkCopyTarget.targets(lines: [line], imageSize: imageSize, panelFrame: firstPanel).first
        )
        let moved = try XCTUnwrap(
            LinkCopyTarget.targets(lines: [line], imageSize: imageSize, panelFrame: movedPanel).first
        )

        XCTAssertEqual(moved.screenPoint.x - first.screenPoint.x, 317, accuracy: 0.001)
        XCTAssertEqual(moved.screenPoint.y - first.screenPoint.y, 121, accuracy: 0.001)
    }

    func testCopyTargetUsesTextHeightToAimAtAdjacentCopyIcon() throws {
        let line = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 20)
        )
        let target = try XCTUnwrap(
            LinkCopyTarget.targets(
                lines: [line],
                imageSize: CGSize(width: 800, height: 600),
                panelFrame: CGRect(x: 100, y: 200, width: 800, height: 600)
            ).first
        )

        XCTAssertEqual(target.screenPoint.x, line.box.maxX + line.box.height * 3.2 + 100, accuracy: 0.001)
        XCTAssertEqual(target.screenPoint.y, line.box.midY + 200, accuracy: 0.001)
    }

    func testSuccessfulCopyReplacesEllipsizedOCRAndRestoresClipboard() async throws {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("私人内容".utf8)]])
        let fullURL = "https://detail.tmall.com/item.htm?id=539699766942&ut_sk=test"
        let clipboard = FakeLinkClipboard(snapshot: oldClipboard, string: "私人内容")
        let clicker = FakeLinkClicker {
            clipboard.replaceWithCopiedString(fullURL)
        }
        let activator = FakeLinkApplicationActivator()
        let resolver = ChatLinkResolver(
            clipboard: clipboard,
            clicker: clicker,
            applicationActivator: activator,
            pollDelay: {}
        )
        let visible = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 14)
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            panelFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let resolved = await resolver.resolve(
            lines: [visible],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(resolved.map(\.text), [fullURL])
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
        XCTAssertEqual(clicker.points.count, 1)
        XCTAssertEqual(activator.activatedPanels.map(\.ownerPID), [9])
        XCTAssertEqual(activator.scannerReactivationCount, 1)
    }

    func testFailedCopyPreservesLegacyOCRAndRestoresClipboard() async {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("旧值".utf8)]])
        let clipboard = FakeLinkClipboard(snapshot: oldClipboard, string: "旧值")
        let resolver = ChatLinkResolver(
            clipboard: clipboard,
            clicker: FakeLinkClicker {},
            applicationActivator: FakeLinkApplicationActivator(),
            pollDelay: {},
            maximumPolls: 2
        )
        let visible = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 14)
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            panelFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let resolved = await resolver.resolve(
            lines: [visible],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(resolved, [visible])
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
    }

    func testSameHostDifferentPathIsRejectedAndClipboardIsRestored() async {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("旧值".utf8)]])
        let wrongURL = "https://detail.tmall.com/other.htm?id=539699766942"
        let clipboard = FakeLinkClipboard(snapshot: oldClipboard, string: "旧值")
        let clicker = FakeLinkClicker {
            clipboard.replaceWithCopiedString(wrongURL)
        }
        let resolver = ChatLinkResolver(
            clipboard: clipboard,
            clicker: clicker,
            applicationActivator: FakeLinkApplicationActivator(),
            pollDelay: {},
            maximumPolls: 1
        )
        let visible = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 14)
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            panelFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let resolved = await resolver.resolve(
            lines: [visible],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(resolved, [visible])
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
    }

    func testDoesNotClickWhenQianniuCannotBecomeFrontmost() async {
        let clipboard = FakeLinkClipboard(snapshot: LinkClipboardSnapshot(items: []), string: nil)
        let clicker = FakeLinkClicker {}
        let activator = FakeLinkApplicationActivator(ownerIsFrontmost: false)
        let resolver = ChatLinkResolver(
            clipboard: clipboard,
            clicker: clicker,
            applicationActivator: activator,
            activationDelay: {},
            pollDelay: {}
        )
        let visible = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 14)
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            panelFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let resolved = await resolver.resolve(
            lines: [visible],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(resolved, [visible])
        XCTAssertTrue(clicker.points.isEmpty)
        XCTAssertEqual(activator.activatedPanels.count, 2)
        XCTAssertEqual(activator.scannerReactivationCount, 1)
    }

    func testRetriesOnceWhenFirstClickOnlyActivatesQianniuWindow() async {
        let oldClipboard = LinkClipboardSnapshot(items: [])
        let fullURL = "https://detail.tmall.com/item.htm?id=539699766942"
        let clipboard = FakeLinkClipboard(snapshot: oldClipboard, string: nil)
        var attempts = 0
        let clicker = FakeLinkClicker {
            attempts += 1
            if attempts == 2 {
                clipboard.replaceWithCopiedString(fullURL)
            }
        }
        let resolver = ChatLinkResolver(
            clipboard: clipboard,
            clicker: clicker,
            applicationActivator: FakeLinkApplicationActivator(),
            pollDelay: {},
            maximumPolls: 1
        )
        let visible = OCRLine(
            text: "https://detail.tmall.com/item.htm?..",
            box: CGRect(x: 40, y: 70, width: 260, height: 14)
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            panelFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let resolved = await resolver.resolve(
            lines: [visible],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(resolved.map(\.text), [fullURL])
        XCTAssertEqual(clicker.points.count, 2)
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
    }
}

@MainActor
private final class FakeLinkApplicationActivator: LinkApplicationActivating {
    private(set) var activatedPanels: [LocatedPanel] = []
    private(set) var scannerReactivationCount = 0
    private let frontmost: Bool

    init(ownerIsFrontmost: Bool = true) {
        frontmost = ownerIsFrontmost
    }

    func activateOwner(panel: LocatedPanel) {
        activatedPanels.append(panel)
    }

    func reactivateScanner() {
        scannerReactivationCount += 1
    }

    func ownerIsFrontmost(pid: Int32) -> Bool {
        frontmost
    }
}

@MainActor
private final class FakeLinkClipboard: LinkClipboardAccess {
    private(set) var changeCount = 1
    private(set) var currentSnapshot: LinkClipboardSnapshot
    private var currentString: String?

    init(snapshot: LinkClipboardSnapshot, string: String?) {
        currentSnapshot = snapshot
        currentString = string
    }

    func snapshot() -> LinkClipboardSnapshot { currentSnapshot }
    func string() -> String? { currentString }

    func restore(_ snapshot: LinkClipboardSnapshot) {
        currentSnapshot = snapshot
        currentString = snapshot.items.first?["public.utf8-plain-text"]
            .flatMap { String(data: $0, encoding: .utf8) }
        changeCount += 1
    }

    func replaceWithCopiedString(_ string: String) {
        currentString = string
        currentSnapshot = LinkClipboardSnapshot(
            items: [["public.utf8-plain-text": Data(string.utf8)]]
        )
        changeCount += 1
    }
}

@MainActor
private final class FakeLinkClicker: LinkMouseClicking {
    private let action: () -> Void
    private(set) var points: [CGPoint] = []

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func click(at point: CGPoint) {
        points.append(point)
        action()
    }
}
