import AppKit
import CoreGraphics
import Foundation
import OSLog
import QianniuOCRCore

struct ImageCopyTarget: Equatable {
    let box: CGRect
    let hoverPoint: CGPoint
    let copyPoint: CGPoint

    static func targets(
        boxes: [CGRect],
        imageSize: CGSize,
        panelFrame: CGRect
    ) -> [ImageCopyTarget] {
        guard imageSize.width > 0, imageSize.height > 0,
              panelFrame.width > 0, panelFrame.height > 0 else {
            return []
        }
        let scaleX = panelFrame.width / imageSize.width
        let scaleY = panelFrame.height / imageSize.height

        return boxes.compactMap { box in
            guard box.width > 0, box.height > 0 else { return nil }
            let screenBox = CGRect(
                x: panelFrame.minX + box.minX * scaleX,
                y: panelFrame.minY + box.minY * scaleY,
                width: box.width * scaleX,
                height: box.height * scaleY
            )
            let copyOffsetX = min(20, max(12, screenBox.height * 0.08))
            let copyInsetY = min(14, max(8, screenBox.height * 0.04))
            let margin: CGFloat = 2
            return ImageCopyTarget(
                box: box,
                hoverPoint: CGPoint(x: screenBox.midX, y: screenBox.midY),
                copyPoint: CGPoint(
                    x: min(screenBox.maxX + copyOffsetX, panelFrame.maxX - margin),
                    y: min(max(screenBox.maxY - copyInsetY, panelFrame.minY + margin), panelFrame.maxY - margin)
                )
            )
        }
    }
}

@MainActor
protocol ImageClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> LinkClipboardSnapshot
    func image() -> CGImage?
    func restore(_ snapshot: LinkClipboardSnapshot)
}

@MainActor
protocol ImagePointerControlling: AnyObject {
    func move(to point: CGPoint)
    func click(at point: CGPoint)
}

@MainActor
protocol ImageCopyResolving: AnyObject {
    func resolve(boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> [DetectedChatImage]
}

@MainActor
final class ChatImageCopyResolver: ImageCopyResolving {
    private let logger = Logger(subsystem: "com.scy.qianniu-ocr.copy-experiment", category: "image-copy")
    private let clipboard: any ImageClipboardAccess
    private let pointer: any ImagePointerControlling
    private let applicationActivator: any LinkApplicationActivating
    private let activationDelay: @MainActor @Sendable () async -> Void
    private let hoverDelay: @MainActor @Sendable () async -> Void
    private let pollDelay: @MainActor @Sendable () async -> Void
    private let maximumPolls: Int
    private let maximumClickAttempts: Int

    init() {
        clipboard = SystemImageClipboard()
        pointer = SystemImagePointer()
        applicationActivator = SystemLinkApplicationActivator()
        activationDelay = { try? await Task.sleep(for: .milliseconds(50)) }
        hoverDelay = { try? await Task.sleep(for: .milliseconds(120)) }
        pollDelay = { try? await Task.sleep(for: .milliseconds(35)) }
        maximumPolls = 10
        maximumClickAttempts = 3
    }

    init(
        clipboard: any ImageClipboardAccess,
        pointer: any ImagePointerControlling,
        applicationActivator: any LinkApplicationActivating,
        activationDelay: @escaping @MainActor @Sendable () async -> Void = {},
        hoverDelay: @escaping @MainActor @Sendable () async -> Void = {},
        pollDelay: @escaping @MainActor @Sendable () async -> Void = {},
        maximumPolls: Int = 10,
        maximumClickAttempts: Int = 3
    ) {
        self.clipboard = clipboard
        self.pointer = pointer
        self.applicationActivator = applicationActivator
        self.activationDelay = activationDelay
        self.hoverDelay = hoverDelay
        self.pollDelay = pollDelay
        self.maximumPolls = maximumPolls
        self.maximumClickAttempts = max(1, maximumClickAttempts)
    }

    func resolve(
        boxes: [CGRect],
        panel: LocatedPanel,
        imageSize: CGSize
    ) async -> [DetectedChatImage] {
        let targets = ImageCopyTarget.targets(
            boxes: boxes,
            imageSize: imageSize,
            panelFrame: panel.panelFrame
        )
        guard !targets.isEmpty else { return [] }

        var ownerIsFrontmost = false
        for _ in 0..<2 {
            guard !Task.isCancelled else { return [] }
            applicationActivator.activateOwner(panel: panel)
            for _ in 0..<10 {
                guard !Task.isCancelled else { return [] }
                if applicationActivator.ownerIsFrontmost(pid: panel.ownerPID) {
                    ownerIsFrontmost = true
                    break
                }
                await activationDelay()
            }
            if ownerIsFrontmost { break }
        }
        defer { applicationActivator.reactivateScanner() }
        guard ownerIsFrontmost else { return [] }

        var copiedImages: [DetectedChatImage] = []
        // Qianniu keeps at most one customer photo visible in the current page for
        // this workflow. Processing every detector box caused the same photo (or
        // card artwork) to be clicked repeatedly. One observation gets one
        // candidate and one copy click; a later genuine unread dot starts a new
        // observation.
        for target in targets.prefix(1) {
            guard !Task.isCancelled else { break }
            let originalClipboard = clipboard.snapshot()
            var copiedImage: CGImage?

            for _ in 0..<maximumClickAttempts {
                guard !Task.isCancelled else { break }
                pointer.move(to: target.hoverPoint)
                await hoverDelay()
                guard !Task.isCancelled else { break }
                let previousChangeCount = clipboard.changeCount
                pointer.click(at: target.copyPoint)
                for _ in 0..<maximumPolls {
                    guard !Task.isCancelled else { break }
                    if clipboard.changeCount != previousChangeCount,
                       let image = clipboard.image() {
                        copiedImage = image
                        break
                    }
                    await pollDelay()
                }
                if Task.isCancelled { break }
                if copiedImage != nil { break }
            }
            clipboard.restore(originalClipboard)

            if let copiedImage {
                logger.info("copied original chat image \(copiedImage.width)x\(copiedImage.height)")
                copiedImages.append(DetectedChatImage(box: target.box, image: copiedImage))
            }
        }
        return copiedImages
    }
}

@MainActor
private final class SystemImageClipboard: ImageClipboardAccess {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> LinkClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
        return LinkClipboardSnapshot(items: items)
    }

    func image() -> CGImage? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func restore(_ snapshot: LinkClipboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in values {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

@MainActor
private final class SystemImagePointer: ImagePointerControlling {
    func move(to point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    func click(at point: CGPoint) {
        move(to: point)
        Thread.sleep(forTimeInterval: 0.04)
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
