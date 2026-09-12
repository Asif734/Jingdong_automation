import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import QianniuOCRCore

struct LinkCopyTarget: Equatable {
    let lineIndex: Int
    let visibleText: String
    let screenPoint: CGPoint

    static func targets(
        lines: [OCRLine],
        imageSize: CGSize,
        panelFrame: CGRect
    ) -> [LinkCopyTarget] {
        guard imageSize.width > 0, imageSize.height > 0,
              panelFrame.width > 0, panelFrame.height > 0 else {
            return []
        }
        let scaleX = panelFrame.width / imageSize.width
        let scaleY = panelFrame.height / imageSize.height

        return lines.enumerated().compactMap { index, line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEllipsizedWebURL(text), line.box.height > 0 else { return nil }

            // 千牛的复制按钮紧邻省略链接右侧。偏移量只取决于 OCR 字高，
            // 然后随面板 frame 缩放/平移，不依赖任何固定屏幕坐标。
            let pixelX = line.box.maxX + line.box.height * 3.2
            let pixelY = line.box.midY
            let unclamped = CGPoint(
                x: panelFrame.minX + pixelX * scaleX,
                y: panelFrame.minY + pixelY * scaleY
            )
            let marginX = max(1, line.box.height * scaleX)
            let marginY = max(1, line.box.height * scaleY / 2)
            let point = CGPoint(
                x: min(max(unclamped.x, panelFrame.minX + marginX), panelFrame.maxX - marginX),
                y: min(max(unclamped.y, panelFrame.minY + marginY), panelFrame.maxY - marginY)
            )
            return LinkCopyTarget(lineIndex: index, visibleText: text, screenPoint: point)
        }
    }

    private static func isEllipsizedWebURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        return text.hasSuffix("..") || text.contains("…")
    }
}

struct LinkClipboardSnapshot: Equatable {
    let items: [[String: Data]]
}

@MainActor
protocol LinkClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> LinkClipboardSnapshot
    func string() -> String?
    func restore(_ snapshot: LinkClipboardSnapshot)
}

@MainActor
protocol LinkMouseClicking: AnyObject {
    func click(at point: CGPoint)
}

@MainActor
protocol LinkApplicationActivating: AnyObject {
    func activateOwner(panel: LocatedPanel)
    func ownerIsFrontmost(pid: Int32) -> Bool
    func reactivateScanner()
}

@MainActor
protocol LinkResolving: AnyObject {
    func resolve(lines: [OCRLine], panel: LocatedPanel, imageSize: CGSize) async -> [OCRLine]
}

@MainActor
final class ChatLinkResolver: LinkResolving {
    private let logger = Logger(subsystem: "com.scy.qianniu-ocr.copy-experiment", category: "link-copy")
    private let clipboard: any LinkClipboardAccess
    private let clicker: any LinkMouseClicking
    private let applicationActivator: any LinkApplicationActivating
    private let activationDelay: @MainActor @Sendable () async -> Void
    private let pollDelay: @MainActor @Sendable () async -> Void
    private let maximumPolls: Int

    init() {
        clipboard = SystemLinkClipboard()
        clicker = SystemLinkClicker()
        applicationActivator = SystemLinkApplicationActivator()
        activationDelay = { try? await Task.sleep(for: .milliseconds(50)) }
        pollDelay = { try? await Task.sleep(for: .milliseconds(35)) }
        maximumPolls = 10
    }

    init(
        clipboard: any LinkClipboardAccess,
        clicker: any LinkMouseClicking,
        applicationActivator: any LinkApplicationActivating,
        activationDelay: @escaping @MainActor @Sendable () async -> Void = {},
        pollDelay: @escaping @MainActor @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(35))
        },
        maximumPolls: Int = 10
    ) {
        self.clipboard = clipboard
        self.clicker = clicker
        self.applicationActivator = applicationActivator
        self.activationDelay = activationDelay
        self.pollDelay = pollDelay
        self.maximumPolls = maximumPolls
    }

    func resolve(
        lines: [OCRLine],
        panel: LocatedPanel,
        imageSize: CGSize
    ) async -> [OCRLine] {
        let targets = LinkCopyTarget.targets(
            lines: lines,
            imageSize: imageSize,
            panelFrame: panel.panelFrame
        )
        guard !targets.isEmpty else { return lines }

        logger.info("found \(targets.count) ellipsized link target(s)")

        var ownerIsFrontmost = false
        for _ in 0..<2 {
            guard !Task.isCancelled else { return lines }
            applicationActivator.activateOwner(panel: panel)
            for _ in 0..<10 {
                guard !Task.isCancelled else { return lines }
                if applicationActivator.ownerIsFrontmost(pid: panel.ownerPID) {
                    ownerIsFrontmost = true
                    break
                }
                await activationDelay()
            }
            if ownerIsFrontmost { break }
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        logger.info("requested owner pid \(panel.ownerPID); frontmost pid \(frontmostPID)")
        defer { applicationActivator.reactivateScanner() }
        guard ownerIsFrontmost else {
            logger.info("owner did not become frontmost; skipped link copy clicks")
            return lines
        }

        var resolved = lines
        for target in targets {
            guard !Task.isCancelled else { break }
            let originalClipboard = clipboard.snapshot()
            let sourceBox = lines[target.lineIndex].box
            logger.info("panel x=\(panel.panelFrame.minX) y=\(panel.panelFrame.minY) w=\(panel.panelFrame.width) h=\(panel.panelFrame.height); image w=\(imageSize.width) h=\(imageSize.height); link box x=\(sourceBox.minX) y=\(sourceBox.minY) w=\(sourceBox.width) h=\(sourceBox.height)")
            var copiedURL: String?
            for attempt in 1...2 {
                guard !Task.isCancelled else { break }
                if attempt == 2 {
                    applicationActivator.activateOwner(panel: panel)
                    var retryOwnerIsFrontmost = false
                    for _ in 0..<10 {
                        guard !Task.isCancelled else { break }
                        if applicationActivator.ownerIsFrontmost(pid: panel.ownerPID) {
                            retryOwnerIsFrontmost = true
                            break
                        }
                        await activationDelay()
                    }
                    guard retryOwnerIsFrontmost else { break }
                }
                let previousChangeCount = clipboard.changeCount
                guard !Task.isCancelled else { break }
                logger.info("clicking link target at x=\(target.screenPoint.x) y=\(target.screenPoint.y), attempt \(attempt)")
                clicker.click(at: target.screenPoint)

                var loggedClipboardChange = false
                for _ in 0..<maximumPolls {
                    guard !Task.isCancelled else { break }
                    if clipboard.changeCount != previousChangeCount {
                        let candidate = clipboard.string()
                        if !loggedClipboardChange {
                            logger.info("clipboard changed; copied string length \(candidate?.count ?? 0)")
                            loggedClipboardChange = true
                        }
                        if let candidate,
                           isMatchingCompleteURL(candidate, visibleText: target.visibleText) {
                            copiedURL = candidate
                            break
                        }
                    }
                    await pollDelay()
                }
                if Task.isCancelled { break }
                if copiedURL != nil { break }
            }
            clipboard.restore(originalClipboard)

            if let copiedURL {
                logger.info("resolved full link with \(copiedURL.count) characters")
                let original = resolved[target.lineIndex]
                resolved[target.lineIndex] = OCRLine(
                    text: copiedURL,
                    box: original.box,
                    confidence: original.confidence
                )
            } else {
                logger.info("copy did not produce a matching URL after two attempts")
            }
        }
        return resolved
    }

    private func isMatchingCompleteURL(_ candidate: String, visibleText: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        var visiblePrefix = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        while visiblePrefix.hasSuffix(".") || visiblePrefix.hasSuffix("…") {
            visiblePrefix.removeLast()
        }
        guard !trimmed.hasSuffix(".."), !trimmed.contains("…"),
              !visiblePrefix.isEmpty,
              trimmed.hasPrefix(visiblePrefix),
              let copied = URLComponents(string: trimmed),
              copied.scheme == "http" || copied.scheme == "https",
              let copiedHost = copied.host, !copiedHost.isEmpty,
              let visibleHost = URLComponents(string: visibleText)?.host else {
            return false
        }
        return copiedHost.caseInsensitiveCompare(visibleHost) == .orderedSame
    }
}

@MainActor
final class SystemLinkApplicationActivator: LinkApplicationActivating {
    private let scanner = NSRunningApplication.current
    private var activatedWindow: AXUIElement?

    static func matchingWindowIndex(titles: [String], targetTitle: String) -> Int? {
        guard targetTitle.contains("接待中心") else { return nil }
        let matches = titles.indices.filter {
            titles[$0] == targetTitle && titles[$0].contains("接待中心")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func activateOwner(panel: LocatedPanel) {
        activatedWindow = nil
        let application = AXUIElementCreateApplication(panel.ownerPID)
        AXUIElementSetMessagingTimeout(application, 3.0)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
           let windows = value as? [AXUIElement] {
            let titles = windows.map { window -> String in
                var titleValue: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(
                    window,
                    kAXTitleAttribute as CFString,
                    &titleValue
                )
                return titleValue as? String ?? ""
            }
            guard let index = Self.matchingWindowIndex(titles: titles, targetTitle: panel.windowTitle) else {
                activatedWindow = nil
                return
            }
            let matchingWindow = windows[index]
            activatedWindow = matchingWindow
            _ = NSRunningApplication(processIdentifier: panel.ownerPID)?.activate(options: [])
            _ = AXUIElementSetAttributeValue(
                application,
                kAXFocusedWindowAttribute as CFString,
                matchingWindow
            )
            _ = AXUIElementSetAttributeValue(matchingWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(matchingWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
        }
    }

    func ownerIsFrontmost(pid: Int32) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let activatedWindow else { return false }
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return CFEqual(unsafeDowncast(value, to: AXUIElement.self), activatedWindow)
    }

    func reactivateScanner() {
        scanner.activate()
    }
}

@MainActor
private final class SystemLinkClipboard: LinkClipboardAccess {
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

    func string() -> String? {
        pasteboard.string(forType: .string)
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
private final class SystemLinkClicker: LinkMouseClicking {
    func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
