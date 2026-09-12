import CoreGraphics
import Foundation

public struct CaptureSelectionPolicy: Codable, Equatable, Sendable {
    public let relativeMessageRect: CGRect

    public init(relativeMessageRect: CGRect) {
        self.relativeMessageRect = relativeMessageRect
    }

    public func absoluteMessageRect(in window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + relativeMessageRect.minX * window.width,
            y: window.minY + relativeMessageRect.minY * window.height,
            width: relativeMessageRect.width * window.width,
            height: relativeMessageRect.height * window.height
        )
    }
}
