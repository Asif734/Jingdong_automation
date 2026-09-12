import AppKit
import CoreGraphics
import Foundation
import QianniuOCRCore
import ScreenCaptureKit

@MainActor
protocol WindowCapturing {
    func capture(_ target: LocatedPanel) async throws -> CGImage
}

enum OCRWindowCaptureGeometry {
    static func outputSize(for frame: CGRect) -> CGSize {
        CGSize(width: max(1, ceil(frame.width)), height: max(1, ceil(frame.height)))
    }
}

@MainActor
final class WindowCaptureService: WindowCapturing {
    func capture(_ target: LocatedPanel) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw OCRAppError.screenRecordingPermissionMissing
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = bestWindow(in: content.windows, for: target) else {
            throw OCRAppError.receptionWindowNotFound
        }

        let configuration = SCStreamConfiguration()
        let outputSize = OCRWindowCaptureGeometry.outputSize(for: window.frame)
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let fullImage: CGImage
        do {
            fullImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw OCRAppError.captureFailed(error.localizedDescription)
        }

        guard let crop = CropGeometry.pixelCrop(
            panel: target.panelFrame,
            window: target.windowFrame,
            imageSize: CGSize(width: fullImage.width, height: fullImage.height)
        ), let cropped = fullImage.cropping(to: crop) else {
            throw OCRAppError.captureFailed("消息记录面板的裁剪范围无效")
        }
        return cropped
    }

    private func bestWindow(in windows: [SCWindow], for target: LocatedPanel) -> SCWindow? {
        windows
            .filter { $0.owningApplication?.processID == target.ownerPID }
            .min { lhs, rhs in windowDistance(lhs, target) < windowDistance(rhs, target) }
    }

    private func windowDistance(_ window: SCWindow, _ target: LocatedPanel) -> CGFloat {
        let titlePenalty: CGFloat = window.title == target.windowTitle ? 0 : 10_000
        return titlePenalty
            + abs(window.frame.minX - target.windowFrame.minX)
            + abs(window.frame.minY - target.windowFrame.minY)
            + abs(window.frame.width - target.windowFrame.width)
            + abs(window.frame.height - target.windowFrame.height)
    }
}
