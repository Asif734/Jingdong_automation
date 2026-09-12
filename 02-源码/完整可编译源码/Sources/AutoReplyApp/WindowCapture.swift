import ScreenCaptureKit
import CoreGraphics
import QianniuOCRCore
import UnreadCore

enum WindowCaptureGeometry {
    static func outputSize(for frame: CGRect) -> CGSize {
        CGSize(width: max(1, ceil(frame.width)), height: max(1, ceil(frame.height)))
    }
}

@MainActor enum WindowCapture {
    static func capture(
        _ scene: SceneSnapshot,
        pid: pid_t,
        coordinateMapping: CoordinateMapping? = nil
    ) async throws -> PixelImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            guard $0.windowID == scene.windowID, $0.owningApplication?.processID == pid else { return false }
            if let coordinateMapping {
                return ReceptionWindowGeometry.matches(
                    accessibility: scene.frame,
                    capture: $0.frame,
                    mapping: coordinateMapping
                )
            }
            return ReceptionWindowGeometry.matches(accessibility: scene.frame, capture: $0.frame)
        }) else { throw AssistantError.unsafe("截图前千牛窗口已移动或不可见；未点击。") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let outputSize = WindowCaptureGeometry.outputSize(for: scene.frame)
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let context = CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AssistantError.unsafe("无法解码窗口截图。") }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return PixelImage(width: cg.width, height: cg.height, rgba: bytes)
    }
}
