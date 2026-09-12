import CoreGraphics
import XCTest
@testable import QianniuOCRAppSupport
import QianniuOCRCore

@MainActor
final class ChatImageCopyResolverTests: XCTestCase {
    func testTargetGeometryMovesWithPanelAndUsesImageBottomRightCopyButton() throws {
        let box = CGRect(x: 20, y: 60, width: 300, height: 220)
        let firstPanel = CGRect(x: 100, y: 200, width: 800, height: 600)
        let movedPanel = firstPanel.offsetBy(dx: 317, dy: 121)

        let first = try XCTUnwrap(ImageCopyTarget.targets(
            boxes: [box],
            imageSize: CGSize(width: 800, height: 600),
            panelFrame: firstPanel
        ).first)
        let moved = try XCTUnwrap(ImageCopyTarget.targets(
            boxes: [box],
            imageSize: CGSize(width: 800, height: 600),
            panelFrame: movedPanel
        ).first)

        XCTAssertEqual(moved.hoverPoint.x - first.hoverPoint.x, 317, accuracy: 0.001)
        XCTAssertEqual(moved.hoverPoint.y - first.hoverPoint.y, 121, accuracy: 0.001)
        XCTAssertEqual(moved.copyPoint.x - first.copyPoint.x, 317, accuracy: 0.001)
        XCTAssertEqual(moved.copyPoint.y - first.copyPoint.y, 121, accuracy: 0.001)
        XCTAssertGreaterThan(first.copyPoint.x, firstPanel.minX + box.maxX)
        XCTAssertLessThan(first.copyPoint.y, firstPanel.minY + box.maxY)
    }

    func testSuccessfulImageCopyReturnsOriginalImageAndRestoresClipboard() async throws {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("私人内容".utf8)]])
        let copiedImage = try makeImage(width: 1179, height: 884)
        let clipboard = FakeImageClipboard(snapshot: oldClipboard)
        let pointer = FakeImagePointer {
            clipboard.replaceWithImage(copiedImage)
        }
        let activator = FakeImageApplicationActivator()
        let resolver = ChatImageCopyResolver(
            clipboard: clipboard,
            pointer: pointer,
            applicationActivator: activator,
            hoverDelay: {},
            pollDelay: {}
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            panelFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let box = CGRect(x: 20, y: 60, width: 300, height: 220)

        let copied = await resolver.resolve(
            boxes: [box],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied[0].box, box)
        XCTAssertEqual(copied[0].image.width, 1179)
        XCTAssertEqual(copied[0].image.height, 884)
        XCTAssertEqual(pointer.movedPoints.count, 1)
        XCTAssertEqual(pointer.clickedPoints.count, 1)
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
        XCTAssertEqual(activator.scannerReactivationCount, 1)
    }

    func testPlainTextClipboardIsIgnoredAndRestored() async {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("旧值".utf8)]])
        let clipboard = FakeImageClipboard(snapshot: oldClipboard)
        let pointer = FakeImagePointer {
            clipboard.replaceWithText("不是图片")
        }
        let resolver = ChatImageCopyResolver(
            clipboard: clipboard,
            pointer: pointer,
            applicationActivator: FakeImageApplicationActivator(),
            hoverDelay: {},
            pollDelay: {},
            maximumPolls: 1
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: .zero,
            panelFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let copied = await resolver.resolve(
            boxes: [CGRect(x: 20, y: 60, width: 300, height: 220)],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
    }

    func testOnePageProcessesOnlyFirstImageCandidateAndClicksAtMostOnce() async throws {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("old".utf8)]])
        let copiedImage = try makeImage(width: 640, height: 480)
        let clipboard = FakeImageClipboard(snapshot: oldClipboard)
        let pointer = FakeImagePointer { clipboard.replaceWithImage(copiedImage) }
        let resolver = ChatImageCopyResolver(
            clipboard: clipboard,
            pointer: pointer,
            applicationActivator: FakeImageApplicationActivator(),
            hoverDelay: {},
            pollDelay: {}
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: .zero,
            panelFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let copied = await resolver.resolve(
            boxes: [
                CGRect(x: 20, y: 60, width: 300, height: 220),
                CGRect(x: 20, y: 300, width: 300, height: 220)
            ],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(pointer.movedPoints.count, 1)
        XCTAssertEqual(pointer.clickedPoints.count, 1)
    }

    func testDelayedCopyButtonIsRetriedAndStopsImmediatelyAfterClipboardImageAppears() async throws {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("old".utf8)]])
        let copiedImage = try makeImage(width: 800, height: 600)
        let clipboard = FakeImageClipboard(snapshot: oldClipboard)
        var clickCount = 0
        let pointer = FakeImagePointer {
            clickCount += 1
            if clickCount == 3 { clipboard.replaceWithImage(copiedImage) }
        }
        let resolver = ChatImageCopyResolver(
            clipboard: clipboard,
            pointer: pointer,
            applicationActivator: FakeImageApplicationActivator(),
            hoverDelay: {},
            pollDelay: {},
            maximumPolls: 1
        )
        let panel = LocatedPanel(
            ownerPID: 9,
            windowTitle: "千牛",
            windowFrame: .zero,
            panelFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let copied = await resolver.resolve(
            boxes: [CGRect(x: 20, y: 60, width: 300, height: 220)],
            panel: panel,
            imageSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(pointer.clickedPoints.count, 3)
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
    }

    func testCancellationStopsFurtherClipboardClicksAndRestoresOriginalClipboard() async {
        let oldClipboard = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data("old".utf8)]])
        let clipboard = FakeImageClipboard(snapshot: oldClipboard)
        let pointer = FakeImagePointer {}
        let resolver = ChatImageCopyResolver(
            clipboard: clipboard,
            pointer: pointer,
            applicationActivator: FakeImageApplicationActivator(),
            hoverDelay: {},
            pollDelay: { try? await Task.sleep(for: .seconds(1)) },
            maximumPolls: 100,
            maximumClickAttempts: 3
        )
        let panel = LocatedPanel(ownerPID: 9, windowTitle: "千牛", windowFrame: .zero,
                                 panelFrame: CGRect(x: 0, y: 0, width: 800, height: 600))

        let task = Task {
            await resolver.resolve(boxes: [CGRect(x: 20, y: 60, width: 300, height: 220)],
                                   panel: panel, imageSize: CGSize(width: 800, height: 600))
        }
        for _ in 0..<100 where pointer.clickedPoints.isEmpty { await Task.yield() }
        task.cancel()
        _ = await task.value

        XCTAssertEqual(pointer.clickedPoints.count, 1)
        XCTAssertEqual(clipboard.currentSnapshot, oldClipboard)
    }
}

@MainActor
private final class FakeImageClipboard: ImageClipboardAccess {
    private(set) var changeCount = 1
    private(set) var currentSnapshot: LinkClipboardSnapshot
    private var currentImage: CGImage?

    init(snapshot: LinkClipboardSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() -> LinkClipboardSnapshot { currentSnapshot }
    func image() -> CGImage? { currentImage }

    func restore(_ snapshot: LinkClipboardSnapshot) {
        currentSnapshot = snapshot
        currentImage = nil
        changeCount += 1
    }

    func replaceWithImage(_ image: CGImage) {
        currentImage = image
        currentSnapshot = LinkClipboardSnapshot(items: [["public.tiff": Data([1])]])
        changeCount += 1
    }

    func replaceWithText(_ text: String) {
        currentImage = nil
        currentSnapshot = LinkClipboardSnapshot(items: [["public.utf8-plain-text": Data(text.utf8)]])
        changeCount += 1
    }
}

@MainActor
private final class FakeImagePointer: ImagePointerControlling {
    private let clickAction: () -> Void
    private(set) var movedPoints: [CGPoint] = []
    private(set) var clickedPoints: [CGPoint] = []

    init(clickAction: @escaping () -> Void) {
        self.clickAction = clickAction
    }

    func move(to point: CGPoint) {
        movedPoints.append(point)
    }

    func click(at point: CGPoint) {
        clickedPoints.append(point)
        clickAction()
    }
}

@MainActor
private final class FakeImageApplicationActivator: LinkApplicationActivating {
    private(set) var scannerReactivationCount = 0

    func activateOwner(panel: LocatedPanel) {}
    func ownerIsFrontmost(pid: Int32) -> Bool { true }
    func reactivateScanner() { scannerReactivationCount += 1 }
}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try XCTUnwrap(context.makeImage())
}
