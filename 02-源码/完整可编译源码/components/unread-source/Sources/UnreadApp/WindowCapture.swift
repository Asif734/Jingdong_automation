import ScreenCaptureKit
import CoreGraphics
import UnreadCore

@MainActor enum WindowCapture {
    static func capture(_ scene: SceneSnapshot, pid: pid_t) async throws -> PixelImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == scene.windowID && $0.owningApplication?.processID == pid }),
              window.frame == scene.frame else { throw AssistantError.unsafe("截图前千牛窗口已移动或不可见；未点击。") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(scene.frame.width * 2)
        configuration.height = Int(scene.frame.height * 2)
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
