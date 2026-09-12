import CoreGraphics
import Foundation

public struct OCRLine: Codable, Equatable, Sendable {
    public let text: String
    public let box: CGRect
    public let confidence: Double?

    public init(text: String, box: CGRect, confidence: Double? = nil) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

public enum OCRPresentation {
    public static func jsonArray(_ lines: [OCRLine]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(lines.map(\.text))
        guard let result = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return result
    }
}

public enum CropGeometry {
    public static func pixelCrop(
        panel: CGRect,
        window: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard window.width > 0, window.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let intersection = panel.intersection(window)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }

        let scaleX = imageSize.width / window.width
        let scaleY = imageSize.height / window.height
        return CGRect(
            x: (intersection.minX - window.minX) * scaleX,
            y: (intersection.minY - window.minY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        ).integral
    }
}
