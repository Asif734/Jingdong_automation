import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import QianniuOCRCore
import ScreenCaptureKit

public enum VideoOpenProgressPhase: String, Sendable {
    case detected
    case opening
    case downloadRequested = "download-requested"
    case closingPlayer = "closing-player"
    case resumedScanning = "resumed-scanning"
}

struct VideoMediaTarget: Equatable, Sendable {
    let sourceBox: CGRect
    let screenRect: CGRect
}

enum VideoTargetSelection {
    static func target(boxes: [CGRect], imageSize: CGSize, panelFrame: CGRect) -> VideoMediaTarget? {
        guard imageSize.width > 0, imageSize.height > 0,
              panelFrame.width > 0, panelFrame.height > 0 else { return nil }
        let scaleX = panelFrame.width / imageSize.width
        let scaleY = panelFrame.height / imageSize.height
        let plausible = boxes
            .filter { box in
                box.width * scaleX >= 120 && box.height * scaleY >= 80
                    && box.minX <= imageSize.width * 0.55
                    && box.midX <= imageSize.width * 0.72
            }
        let awayFromWindowEdge = plausible.filter { $0.minX >= imageSize.width * 0.12 }
        return (awayFromWindowEdge.isEmpty ? plausible : awayFromWindowEdge)
            .max { lhs, rhs in
                lhs.maxY == rhs.maxY ? lhs.width * lhs.height < rhs.width * rhs.height : lhs.maxY < rhs.maxY
            }
            .map { box in
                VideoMediaTarget(
                    sourceBox: box,
                    screenRect: CGRect(
                        x: panelFrame.minX + box.minX * scaleX,
                        y: panelFrame.minY + box.minY * scaleY,
                        width: box.width * scaleX,
                        height: box.height * scaleY
                    )
                )
            }
    }

    static func refreshedTarget(
        image: CGImage,
        previous: VideoMediaTarget,
        panelFrame: CGRect
    ) -> VideoMediaTarget? {
        let boxes = ImageCopyCandidateDetector().detect(in: image)
        let size = CGSize(width: image.width, height: image.height)
        let candidates = boxes.compactMap { box in
            target(boxes: [box], imageSize: size, panelFrame: panelFrame)
        }
        return candidates
            .filter { overlap($0.screenRect, previous.screenRect) >= 0.55 }
            .max { overlap($0.screenRect, previous.screenRect) < overlap($1.screenRect, previous.screenRect) }
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return union > 0 ? intersectionArea / union : 0
    }
}

struct VideoWindowDescriptor: Equatable, Sendable {
    let id: UInt32
    let title: String
    let frame: CGRect
}

@MainActor
protocol VideoOpenEnvironment: AnyObject {
    func activateOwner(panel: LocatedPanel) async -> Bool
    func capture(panel: LocatedPanel) async throws -> CGImage
    func move(to point: CGPoint) async
    func click(at point: CGPoint) async
    func dismissPlayer(panel: LocatedPanel) async
    func windows(ownerPID: Int32) async throws -> [VideoWindowDescriptor]
}

enum VideoAttemptStatus: String, Codable, Equatable, Sendable {
    case attempted
    case opened
}

@MainActor
protocol ArmedVideoTransfer: AnyObject {
    func start()
}

@MainActor
protocol VideoTransferArming: AnyObject {
    func arm(messageID: String, customerUID: String) -> (any ArmedVideoTransfer)?
}

@MainActor
private final class NoopVideoTransferArmer: VideoTransferArming {
    func arm(messageID: String, customerUID: String) -> (any ArmedVideoTransfer)? { nil }
}

@MainActor
protocol VideoAttemptRecording: AnyObject {
    func status(for messageID: String) async throws -> VideoAttemptStatus?
    func mark(_ status: VideoAttemptStatus, for messageID: String) async throws
}

protocol VideoTransferDispositionReading: Sendable {
    func disposition(for key: VideoTransferKey) async throws -> VideoTransferDisposition
}

extension DurableVideoTransferStore: VideoTransferDispositionReading {}

@MainActor
final class InMemoryVideoAttemptStore: VideoAttemptRecording {
    private var values: [String: VideoAttemptStatus] = [:]
    func status(for messageID: String) async throws -> VideoAttemptStatus? { values[messageID] }
    func mark(_ status: VideoAttemptStatus, for messageID: String) async throws { values[messageID] = status }
}

@MainActor
final class PersistentVideoAttemptStore: VideoAttemptRecording {
    private struct Payload: Codable { var schemaVersion = 2; var values: [String: VideoAttemptStatus] }
    private let url: URL
    private var payload: Payload?

    init(url: URL) { self.url = url }

    func status(for messageID: String) async throws -> VideoAttemptStatus? {
        try load().values[Self.hash(messageID)]
    }

    func mark(_ status: VideoAttemptStatus, for messageID: String) async throws {
        var value = try load()
        value.values[Self.hash(messageID)] = status
        try write(value)
    }

    private func write(_ value: Payload) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        payload = value
    }

    private func load() throws -> Payload {
        if let payload { return payload }
        var value: Payload
        if FileManager.default.fileExists(atPath: url.path) {
            value = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        } else {
            value = Payload(values: [:])
        }
        let requiresMigration = value.schemaVersion < 2 || value.values.keys.contains { !Self.looksHashed($0) }
        if requiresMigration {
            var migrated: [String: VideoAttemptStatus] = [:]
            for (key, status) in value.values {
                let hashedKey = Self.looksHashed(key) ? key : Self.hash(key)
                if migrated[hashedKey] != .opened { migrated[hashedKey] = status }
            }
            value = Payload(schemaVersion: 2, values: migrated)
            try write(value)
        }
        payload = value
        return value
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func looksHashed(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

@MainActor
final class QianniuVideoOpener: VideoOpening {
    typealias Delay = @MainActor @Sendable () async -> Void
    typealias TargetRefresher = @MainActor @Sendable (CGImage, VideoMediaTarget, CGRect) -> VideoMediaTarget?
    typealias PlayPointLocator = @MainActor @Sendable (CGImage, CGRect, CGRect) -> CGPoint?
    typealias ProgressReporter = @MainActor @Sendable (VideoOpenProgressPhase) -> Void

    private let environment: any VideoOpenEnvironment
    private let attempts: any VideoAttemptRecording
    private let transferState: (any VideoTransferDispositionReading)?
    private let videoTransfers: any VideoTransferArming
    private let hoverDelay: Delay
    private let pollDelay: Delay
    private let maximumPlayerPolls: Int
    private let targetRefresher: TargetRefresher
    private let playPointLocator: PlayPointLocator
    private let onProgress: ProgressReporter

    init(journalURL: URL) {
        environment = SystemVideoOpenEnvironment()
        attempts = PersistentVideoAttemptStore(url: journalURL)
        transferState = nil
        videoTransfers = NoopVideoTransferArmer()
        hoverDelay = { try? await Task.sleep(for: .milliseconds(120)) }
        pollDelay = { try? await Task.sleep(for: .milliseconds(100)) }
        maximumPlayerPolls = 100
        targetRefresher = { image, target, panelFrame in
            VideoTargetSelection.refreshedTarget(image: image, previous: target, panelFrame: panelFrame)
        }
        playPointLocator = { image, target, panel in
            PlayButtonLocatorCascade.point(
                openCV: { OpenCVPlayButtonLocator.point(image: image, target: panel, panelFrame: panel) },
                legacy: { VideoPlayTriangleLocator.point(image: image, target: target, panelFrame: panel) }
            )
        }
        onProgress = { _ in }
    }

    init(
        journalURL: URL,
        videoTransfers: any VideoTransferArming,
        transferState: (any VideoTransferDispositionReading)? = nil,
        onProgress: @escaping ProgressReporter = { _ in }
    ) {
        environment = SystemVideoOpenEnvironment()
        attempts = PersistentVideoAttemptStore(url: journalURL)
        self.transferState = transferState
        self.videoTransfers = videoTransfers
        hoverDelay = { try? await Task.sleep(for: .milliseconds(120)) }
        pollDelay = { try? await Task.sleep(for: .milliseconds(100)) }
        maximumPlayerPolls = 100
        targetRefresher = { image, target, panelFrame in
            VideoTargetSelection.refreshedTarget(image: image, previous: target, panelFrame: panelFrame)
        }
        playPointLocator = { image, target, panel in
            PlayButtonLocatorCascade.point(
                openCV: { OpenCVPlayButtonLocator.point(image: image, target: panel, panelFrame: panel) },
                legacy: { VideoPlayTriangleLocator.point(image: image, target: target, panelFrame: panel) }
            )
        }
        self.onProgress = onProgress
    }

    init(
        environment: any VideoOpenEnvironment,
        attempts: any VideoAttemptRecording,
        videoTransfers: (any VideoTransferArming)? = nil,
        transferState: (any VideoTransferDispositionReading)? = nil,
        hoverDelay: @escaping Delay,
        pollDelay: @escaping Delay,
        maximumPlayerPolls: Int,
        targetRefresher: @escaping TargetRefresher,
        playPointLocator: @escaping PlayPointLocator,
        onProgress: @escaping ProgressReporter = { _ in }
    ) {
        self.environment = environment
        self.attempts = attempts
        self.transferState = transferState
        self.videoTransfers = videoTransfers ?? NoopVideoTransferArmer()
        self.hoverDelay = hoverDelay
        self.pollDelay = pollDelay
        self.maximumPlayerPolls = max(1, maximumPlayerPolls)
        self.targetRefresher = targetRefresher
        self.playPointLocator = playPointLocator
        self.onProgress = onProgress
    }

    func open(messageID: String, customerUID: String = "", boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> VideoOpenOutcome {
        do {
            var durableRetryPermitsClick = false
            if !customerUID.isEmpty, let transferState {
                let key = VideoTransferIdentity.key(customerUID: customerUID, messageID: messageID)
                switch try await transferState.disposition(for: key) {
                case .needsOpen:
                    durableRetryPermitsClick = true
                case .inFlight, .waitingUntil:
                    return .inFlight
                case .terminal:
                    return .alreadyAttempted
                }
            }
            if !durableRetryPermitsClick {
                guard try await attempts.status(for: messageID) == nil else { return .alreadyAttempted }
            }
            guard let initial = VideoTargetSelection.target(
                boxes: boxes,
                imageSize: imageSize,
                panelFrame: panel.panelFrame
            ) else { return .failedBeforeClick("没有找到可信的客户视频区域") }
            onProgress(.opening)
            guard await environment.activateOwner(panel: panel) else {
                return .failedBeforeClick("千牛接待中心未能置前")
            }
            let existingWindowIDs = Set(try await environment.windows(ownerPID: panel.ownerPID).map(\.id))
            var target = initial
            guard let firstClickPoint = try await locateClickPoint(target: &target, panel: panel, fallbackIndex: 0) else {
                return .failedBeforeClick("没有找到视频播放按钮")
            }
            let transfer = videoTransfers.arm(messageID: messageID, customerUID: customerUID)
            try await attempts.mark(.attempted, for: messageID)
            transfer?.start()
            try Task.checkCancellation()
            let maximumClickAttempts = 6
            let pollsPerClick = max(2, maximumPlayerPolls / maximumClickAttempts)
            var clickPoint: CGPoint? = firstClickPoint

            for clickAttempt in 0..<maximumClickAttempts {
                guard let currentClickPoint = clickPoint else {
                    await pollDelay()
                    if clickAttempt + 1 < maximumClickAttempts {
                        clickPoint = try await locateClickPoint(
                            target: &target,
                            panel: panel,
                            fallbackIndex: clickAttempt + 1
                        )
                    }
                    continue
                }
                await environment.click(at: currentClickPoint)

                if try await waitForPlayerOrDownloadStart(
                    panel: panel,
                    existingWindowIDs: existingWindowIDs,
                    transferKey: transferKey(customerUID: customerUID, messageID: messageID),
                    polls: pollsPerClick
                ) {
                    if transfer != nil, transferState != nil {
                        guard try await waitForDownloadStart(
                            key: transferKey(customerUID: customerUID, messageID: messageID),
                            polls: maximumPlayerPolls
                        ) else {
                            return .uncertainAfterClick("播放器已打开，但尚未确认后台下载开始")
                        }
                    }
                    if transfer != nil {
                        onProgress(.downloadRequested)
                        onProgress(.closingPlayer)
                        await environment.dismissPlayer(panel: panel)
                        onProgress(.resumedScanning)
                    }
                    try await attempts.mark(.opened, for: messageID)
                    return .opened
                }

                guard clickAttempt + 1 < maximumClickAttempts else { break }
                clickPoint = try await locateClickPoint(
                    target: &target,
                    panel: panel,
                    fallbackIndex: clickAttempt + 1
                )
            }
            return .uncertainAfterClick("点击后没有确认到新播放器窗口或原窗口播放状态")
        } catch is CancellationError {
            return .failedBeforeClick("视频打开任务已取消")
        } catch {
            if (try? await attempts.status(for: messageID)) != nil {
                return .uncertainAfterClick(error.localizedDescription)
            }
            return .failedBeforeClick(error.localizedDescription)
        }
    }

    private func locateClickPoint(
        target: inout VideoMediaTarget,
        panel: LocatedPanel,
        fallbackIndex: Int
    ) async throws -> CGPoint? {
        let freshImage = try await environment.capture(panel: panel)
        if let refreshed = targetRefresher(freshImage, target, panel.panelFrame) {
            target = refreshed
        }
        await environment.move(to: CGPoint(x: target.screenRect.midX, y: target.screenRect.midY))
        await hoverDelay()
        try Task.checkCancellation()
        let hoveredImage = try await environment.capture(panel: panel)
        let detectedPlayPoint = fallbackIndex == 0
            ? playPointLocator(hoveredImage, target.screenRect, panel.panelFrame)
            : nil
        if let detectedPlayPoint, panel.panelFrame.contains(detectedPlayPoint) {
            return detectedPlayPoint
        }
        guard let point = verticalFallbackPoint(
            in: target.screenRect,
            panelFrame: panel.panelFrame,
            index: fallbackIndex
        ), fallbackSearchRect(for: target.screenRect, panelFrame: panel.panelFrame).contains(point) else {
            return nil
        }
        return point
    }

    private func verticalFallbackPoint(in target: CGRect, panelFrame: CGRect, index: Int) -> CGPoint? {
        guard target.width >= 120, target.height >= 80 else { return nil }
        let clampedIndex = min(max(index, 0), 5)
        let progress = CGFloat(clampedIndex) / 5
        let upperBound = fallbackSearchRect(for: target, panelFrame: panelFrame).minY
        return CGPoint(
            x: target.midX,
            y: target.midY + (upperBound - target.midY) * progress
        )
    }

    private func fallbackSearchRect(for target: CGRect, panelFrame: CGRect) -> CGRect {
        let minimumY = max(panelFrame.minY + 80, target.minY - target.height * 0.42)
        return CGRect(x: target.minX - 2, y: minimumY, width: target.width + 4, height: target.maxY - minimumY + 2)
    }

    private func waitForPlayerOrDownloadStart(
        panel: LocatedPanel,
        existingWindowIDs: Set<UInt32>,
        transferKey: VideoTransferKey?,
        polls: Int
    ) async throws -> Bool {
        for _ in 0..<max(1, polls) {
            if let transferKey, try await transferHasAdvanced(key: transferKey) { return true }
            let windows = try await environment.windows(ownerPID: panel.ownerPID)
            if windows.contains(where: {
                !existingWindowIDs.contains($0.id) && isPlayerLike($0, receptionFrame: panel.windowFrame)
            }) { return true }
            await pollDelay()
            try Task.checkCancellation()
        }
        return false
    }

    private func waitForDownloadStart(key: VideoTransferKey?, polls: Int) async throws -> Bool {
        guard let key else { return false }
        for _ in 0..<max(1, polls) {
            if try await transferHasAdvanced(key: key) { return true }
            await pollDelay()
            try Task.checkCancellation()
        }
        return false
    }

    private func transferHasAdvanced(key: VideoTransferKey) async throws -> Bool {
        guard let transferState else { return false }
        if case .needsOpen = try await transferState.disposition(for: key) { return false }
        return true
    }

    private func transferKey(customerUID: String, messageID: String) -> VideoTransferKey? {
        guard !customerUID.isEmpty, transferState != nil else { return nil }
        return VideoTransferIdentity.key(customerUID: customerUID, messageID: messageID)
    }

    private func isPlayerLike(_ window: VideoWindowDescriptor, receptionFrame: CGRect) -> Bool {
        guard window.frame.width >= 240, window.frame.height >= 160 else { return false }
        return window.title.contains("视频播放")
    }
}

@MainActor
private final class SystemVideoOpenEnvironment: VideoOpenEnvironment {
    private let captureService = WindowCaptureService()

    func activateOwner(panel: LocatedPanel) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: panel.ownerPID), !app.isTerminated else { return false }
        let application = AXUIElementCreateApplication(panel.ownerPID)
        AXUIElementSetMessagingTimeout(application, 3.0)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
              let windows = rawWindows as? [AXUIElement] else { return false }
        let titles = windows.map { window -> String in
            var rawTitle: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle)
            return rawTitle as? String ?? ""
        }
        guard let index = SystemLinkApplicationActivator.matchingWindowIndex(
            titles: titles,
            targetTitle: panel.windowTitle
        ) else { return false }
        let receptionWindow = windows[index]
        _ = app.activate(options: [])
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            receptionWindow
        )
        _ = AXUIElementSetAttributeValue(receptionWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(receptionWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(receptionWindow, kAXRaiseAction as CFString)
        for _ in 0..<10 {
            var rawFocused: CFTypeRef?
            let exactWindowIsFocused = AXUIElementCopyAttributeValue(
                application,
                kAXFocusedWindowAttribute as CFString,
                &rawFocused
            ) == .success && rawFocused.map {
                CFGetTypeID($0) == AXUIElementGetTypeID()
                    && CFEqual(unsafeDowncast($0, to: AXUIElement.self), receptionWindow)
            } == true
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == panel.ownerPID,
               exactWindowIsFocused { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    func capture(panel: LocatedPanel) async throws -> CGImage {
        try await captureService.capture(panel)
    }

    func move(to point: CGPoint) async {
        post(.mouseMoved, at: point)
    }

    func click(at point: CGPoint) async {
        post(.mouseMoved, at: point)
        try? await Task.sleep(for: .milliseconds(40))
        post(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(20))
        post(.leftMouseUp, at: point)
    }

    func dismissPlayer(panel: LocatedPanel) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == panel.ownerPID else { return }
        try? await Task.sleep(for: .milliseconds(60))
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func windows(ownerPID: Int32) async throws -> [VideoWindowDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard window.owningApplication?.processID == ownerPID else { return nil }
            return VideoWindowDescriptor(id: window.windowID, title: window.title ?? "", frame: window.frame)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}

enum VideoPlayTriangleLocator {
    static func point(image: CGImage, target: CGRect, panelFrame: CGRect) -> CGPoint? {
        guard let pixels = VideoPixelImage(image), panelFrame.width > 0, panelFrame.height > 0 else { return nil }
        let scaleX = CGFloat(pixels.width) / panelFrame.width
        let scaleY = CGFloat(pixels.height) / panelFrame.height
        let local = CGRect(
            x: (target.minX - panelFrame.minX) * scaleX,
            y: (target.minY - panelFrame.minY) * scaleY,
            width: target.width * scaleX,
            height: target.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard !local.isNull, local.width >= 5, local.height >= 5 else { return nil }
        let bounds = (
            minX: max(0, Int(local.minX)),
            maxX: min(pixels.width - 1, Int(local.maxX)),
            minY: max(0, Int(local.minY)),
            maxY: min(pixels.height - 1, Int(local.maxY))
        )
        let minimumWidth = max(4, Int(5 * scaleX))
        let maximumWidth = max(minimumWidth, Int(36 * scaleX))
        let minimumHeight = max(4, Int(5 * scaleY))
        let maximumHeight = max(minimumHeight, Int(36 * scaleY))
        var visited = [Bool](repeating: false, count: pixels.width * pixels.height)
        var candidates: [(point: CGPoint, area: Int)] = []

        for y in bounds.minY...bounds.maxY {
            for x in bounds.minX...bounds.maxX {
                let index = y * pixels.width + x
                guard !visited[index], pixels.isBrightNeutral(x: x, y: y) else { continue }
                visited[index] = true
                var queue = [(x, y)]
                var cursor = 0
                var left = x, right = x, top = y, bottom = y
                while cursor < queue.count {
                    let (currentX, currentY) = queue[cursor]
                    cursor += 1
                    left = min(left, currentX); right = max(right, currentX)
                    top = min(top, currentY); bottom = max(bottom, currentY)
                    for neighborY in max(bounds.minY, currentY - 1)...min(bounds.maxY, currentY + 1) {
                        for neighborX in max(bounds.minX, currentX - 1)...min(bounds.maxX, currentX + 1) {
                            let neighborIndex = neighborY * pixels.width + neighborX
                            if !visited[neighborIndex], pixels.isBrightNeutral(x: neighborX, y: neighborY) {
                                visited[neighborIndex] = true
                                queue.append((neighborX, neighborY))
                            }
                        }
                    }
                }
                let width = right - left + 1
                let height = bottom - top + 1
                guard width >= minimumWidth, width <= maximumWidth,
                      height >= minimumHeight, height <= maximumHeight else { continue }
                let occupancy = Double(queue.count) / Double(width * height)
                guard occupancy >= 0.20, occupancy <= 0.78,
                      triangularRowProfile(points: queue, bounds: (left, right, top, bottom)),
                      darkSurroundRatio(
                        pixels,
                        component: (left, right, top, bottom),
                        padding: (max(4, Int(8 * scaleX)), max(4, Int(8 * scaleY)))
                      ) >= 0.60 else { continue }
                candidates.append((
                    point: CGPoint(
                        x: panelFrame.minX + CGFloat(left + right) / 2 / scaleX,
                        y: panelFrame.minY + CGFloat(top + bottom) / 2 / scaleY
                    ),
                    area: width * height
                ))
            }
        }

        let expected = CGPoint(x: local.midX, y: local.midY)
        guard let best = candidates.min(by: { lhs, rhs in
            let lhsLocal = CGPoint(
                x: (lhs.point.x - panelFrame.minX) * scaleX,
                y: (lhs.point.y - panelFrame.minY) * scaleY
            )
            let rhsLocal = CGPoint(
                x: (rhs.point.x - panelFrame.minX) * scaleX,
                y: (rhs.point.y - panelFrame.minY) * scaleY
            )
            let leftDistance = squaredDistance(lhsLocal, expected)
            let rightDistance = squaredDistance(rhsLocal, expected)
            return leftDistance == rightDistance ? lhs.area > rhs.area : leftDistance < rightDistance
        })?.point,
        abs(best.x - target.midX) <= max(24, target.width * 0.28) else { return nil }
        return best
    }

    private static func triangularRowProfile(
        points: [(Int, Int)],
        bounds: (left: Int, right: Int, top: Int, bottom: Int)
    ) -> Bool {
        let height = bounds.bottom - bounds.top + 1
        guard height >= 5 else { return false }
        var minimums = [Int](repeating: Int.max, count: height)
        var maximums = [Int](repeating: Int.min, count: height)
        for (x, y) in points {
            let row = y - bounds.top
            minimums[row] = min(minimums[row], x)
            maximums[row] = max(maximums[row], x)
        }
        let spans = (0..<height).map { row -> Int in
            minimums[row] == Int.max ? 0 : maximums[row] - minimums[row] + 1
        }
        guard let maximum = spans.max(), maximum > 0,
              Double(spans.first ?? 0) <= Double(maximum) * 0.38,
              Double(spans.last ?? 0) <= Double(maximum) * 0.38 else { return false }
        return spans.filter { Double($0) >= Double(maximum) * 0.85 }.count
            <= max(2, Int(Double(height) * 0.35))
    }

    private static func darkSurroundRatio(
        _ image: VideoPixelImage,
        component: (left: Int, right: Int, top: Int, bottom: Int),
        padding: (x: Int, y: Int)
    ) -> Double {
        let left = max(0, component.left - padding.x)
        let right = min(image.width - 1, component.right + padding.x)
        let top = max(0, component.top - padding.y)
        let bottom = min(image.height - 1, component.bottom + padding.y)
        var dark = 0
        var total = 0
        for y in top...bottom {
            for x in left...right {
                if x >= component.left, x <= component.right,
                   y >= component.top, y <= component.bottom { continue }
                total += 1
                if image.maximumChannel(x: x, y: y) <= 100 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }
}

enum PlayButtonLocatorCascade {
    static func point(openCV: () -> CGPoint?, legacy: () -> CGPoint?) -> CGPoint? {
        openCV() ?? legacy()
    }
}

private enum OpenCVPlayButtonLocator {
    private struct Response: Decodable {
        let found: Bool
        let x: Double?
        let y: Double?
    }

    static func point(image: CGImage, target: CGRect, panelFrame: CGRect) -> CGPoint? {
        guard panelFrame.width > 0, panelFrame.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / panelFrame.width
        let scaleY = CGFloat(image.height) / panelFrame.height
        let crop = CGRect(
            x: (target.minX - panelFrame.minX) * scaleX,
            y: (target.minY - panelFrame.minY) * scaleY,
            width: target.width * scaleX,
            height: target.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, crop.width >= 20, crop.height >= 20,
              let cropped = image.cropping(to: crop),
              let runtime = runtimePaths() else { return nil }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-play-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]),
              (try? png.write(to: temporary, options: .atomic)) != nil else { return nil }

        let process = Process()
        process.executableURL = runtime.python
        process.arguments = [runtime.script.path, "--image", temporary.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPATH"] = runtime.pythonPath
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let response = try? JSONDecoder().decode(
                Response.self,
                from: output.fileHandleForReading.readDataToEndOfFile()
              ),
              response.found,
              let x = response.x,
              let y = response.y else { return nil }
        let point = CGPoint(
            x: panelFrame.minX + (crop.minX + CGFloat(x)) / scaleX,
            y: panelFrame.minY + (crop.minY + CGFloat(y)) / scaleY
        )
        return target.insetBy(dx: -2, dy: -2).contains(point) ? point : nil
    }

    private static func runtimePaths() -> (python: URL, script: URL, pythonPath: String)? {
        let resources = Bundle.main.resourceURL
        let packagedPython = resources?.appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12")
        let developmentPython = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12")
        let python = packagedPython.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
            ?? (FileManager.default.isExecutableFile(atPath: developmentPython.path) ? developmentPython : nil)
        let packagedScript = resources?.appendingPathComponent("OpenCV/video_play_locator.py")
        let script = try? ResourceRootSelection.openCVScript(packaged: packagedScript) {
            guard let moduleScript = Bundle.module.resourceURL?
                .appendingPathComponent("OpenCV/video_play_locator.py"),
                  FileManager.default.fileExists(atPath: moduleScript.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return moduleScript
        }
        guard let python, let script else { return nil }
        let paths = [
            resources?.appendingPathComponent("OpenCV/site-packages").path,
            resources?.appendingPathComponent("V2Knowledge/site-packages").path,
            "/Library/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages",
        ].compactMap { $0 }
        return (python, script, paths.joined(separator: ":"))
    }
}

private struct VideoPixelImage {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = storage
    }

    func isBrightNeutral(x: Int, y: Int) -> Bool {
        let offset = (y * width + x) * 4
        let values = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
        return values.min()! >= 185 && values.max()! - values.min()! <= 35
    }

    func maximumChannel(x: Int, y: Int) -> UInt8 {
        let offset = (y * width + x) * 4
        return max(bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}
