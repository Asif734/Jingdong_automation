import CoreGraphics
import Foundation
import ScreenCaptureKit
import UnreadCore

struct CapturedTransferPopup {
    let windowID: UInt32?
    let frame: CGRect
    let fullImage: CGImage
    let topImage: CGImage
}

@MainActor enum TransferPopupCapture {
    static func visibleWindowIDs(ownerPID: pid_t) async throws -> Set<UInt32> {
        let content = try await shareableContent()
        return Set(content.windows.compactMap { window in
            window.owningApplication?.processID == ownerPID ? window.windowID : nil
        })
    }

    static func waitForPopup(
        anchor: TransferMenuAnchor,
        visibleBefore: Set<UInt32>
    ) async throws -> CapturedTransferPopup {
        for _ in 0..<20 {
            let content = try await shareableContent()
            let owned = content.windows.filter {
                $0.owningApplication?.processID == anchor.ownerPID
            }
            let candidates = owned.map {
                TransferWindowCandidate(id: $0.windowID, frame: $0.frame)
            }
            if let selected = TransferPopupSelection.select(
                windows: candidates,
                visibleBefore: visibleBefore,
                receptionWindowID: anchor.receptionWindowID,
                receptionFrame: anchor.receptionFrame,
                transferButtonFrame: anchor.buttonFrame
            ), let window = owned.first(where: { $0.windowID == selected.id }) {
                return try await captureTop(of: window)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await captureFallback(anchor: anchor)
    }

    static func recapture(
        popup: CapturedTransferPopup,
        anchor: TransferMenuAnchor
    ) async throws -> CapturedTransferPopup? {
        if let windowID = popup.windowID {
            let content = try await shareableContent()
            guard let window = content.windows.first(where: {
                $0.windowID == windowID && $0.owningApplication?.processID == anchor.ownerPID
            }) else { return nil }
            return try await captureTop(of: window)
        }
        return try await captureFallback(anchor: anchor, fullHeight: true)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func captureTop(of window: SCWindow) async throws -> CapturedTransferPopup {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(ceil(window.frame.width)))
        configuration.height = max(1, Int(ceil(window.frame.height)))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        let topHeight = min(CGFloat(image.height), max(110, ceil(CGFloat(image.height) * 0.30)))
        guard let top = image.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: topHeight
        )) else {
            throw AssistantError.unsafe("转人工弹窗顶部截图失败；未点击内部选项。")
        }
        return CapturedTransferPopup(
            windowID: window.windowID,
            frame: window.frame,
            fullImage: image,
            topImage: top
        )
    }

    private static func captureFallback(
        anchor: TransferMenuAnchor,
        fullHeight: Bool = false
    ) async throws -> CapturedTransferPopup {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: {
            $0.frame.contains(anchor.buttonFrame) && $0.frame.intersects(anchor.receptionFrame)
        }), let region = (fullHeight ? TransferPopupFallback.fullRegion(
            displayFrame: display.frame,
            receptionFrame: anchor.receptionFrame,
            transferButtonFrame: anchor.buttonFrame
        ) : TransferPopupFallback.region(
            displayFrame: display.frame,
            receptionFrame: anchor.receptionFrame,
            transferButtonFrame: anchor.buttonFrame
        )) else {
            throw AssistantError.unsafe("转人工弹窗已打开，但无法确定它所在的显示器；未点击内部选项。")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(ceil(display.frame.width)))
        configuration.height = max(1, Int(ceil(display.frame.height)))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        let crop = CGRect(
            x: region.minX - display.frame.minX,
            y: region.minY - display.frame.minY,
            width: region.width,
            height: region.height
        ).integral
        guard let cropped = image.cropping(to: crop) else {
            throw AssistantError.unsafe("转人工弹窗局部截图失败；未点击内部选项。")
        }
        let topHeight = min(CGFloat(cropped.height), max(110, ceil(CGFloat(cropped.height) * 0.30)))
        guard let top = cropped.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(cropped.width),
            height: topHeight
        )) else {
            throw AssistantError.unsafe("转人工弹窗顶部截图失败；未点击内部选项。")
        }
        return CapturedTransferPopup(
            windowID: nil,
            frame: region,
            fullImage: cropped,
            topImage: top
        )
    }
}
