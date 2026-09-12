import CoreGraphics
import ImageIO
import XCTest
@testable import QianniuOCRAppSupport

@MainActor
final class ChatImageDetectorTests: XCTestCase {
    func testConsensusDetectorFindsRealCustomerImagePrecisely() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "qianniu-image-message",
                withExtension: "jpeg",
                subdirectory: "Fixtures"
            )
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let screenshot = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mainChat = try XCTUnwrap(
            screenshot.cropping(to: CGRect(x: 304, y: 94, width: 523, height: 375))
        )

        let candidates = ConsensusChatImageDetector().detect(in: mainChat)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertGreaterThanOrEqual(
            intersectionOverUnion(candidates[0], CGRect(x: 22, y: 60, width: 302, height: 227)),
            0.95
        )
    }

    func testConsensusDetectorKeepsLargeLowTextureImage() throws {
        let image = try makeImage(width: 500, height: 350) { x, y in
            if (50..<270).contains(x), (60..<210).contains(y) {
                return (170, 175, 180)
            }
            return (245, 245, 245)
        }

        let candidates = ConsensusChatImageDetector().detect(in: image)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertGreaterThanOrEqual(
            intersectionOverUnion(candidates[0], CGRect(x: 50, y: 60, width: 220, height: 150)),
            0.95
        )
    }

    func testConsensusDetectorRejectsTextOnlyBubble() throws {
        let image = try makeImage(width: 500, height: 350) { x, y in
            if (50..<270).contains(x), (60..<120).contains(y) {
                return (224, 238, 250)
            }
            return (245, 245, 245)
        }

        XCTAssertEqual(ConsensusChatImageDetector().detect(in: image), [])
    }

    func testConsensusDetectorRejectsBlankChatBackground() throws {
        let image = try makeImage(width: 500, height: 350) { _, _ in (245, 245, 245) }

        XCTAssertEqual(ConsensusChatImageDetector().detect(in: image), [])
    }

    func testConsensusDetectorDoesNotDropFifthImage() throws {
        let boxes = [
            CGRect(x: 30, y: 30, width: 100, height: 60),
            CGRect(x: 160, y: 30, width: 100, height: 60),
            CGRect(x: 290, y: 30, width: 100, height: 60),
            CGRect(x: 30, y: 130, width: 100, height: 60),
            CGRect(x: 160, y: 130, width: 100, height: 60),
        ]
        let image = try makeImage(width: 500, height: 350) { x, y in
            if boxes.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                return (150, 170, 190)
            }
            return (245, 245, 245)
        }

        let candidates = ConsensusChatImageDetector().detect(in: image)

        XCTAssertEqual(candidates.count, 5)
        for box in boxes {
            XCTAssertTrue(candidates.contains { intersectionOverUnion($0, box) >= 0.95 })
        }
    }
}

private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    return intersectionArea / unionArea
}

private func makeImage(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
) throws -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (red, green, blue) = pixel(x, y)
            let offset = (y * width + x) * 4
            bytes[offset] = red
            bytes[offset + 1] = green
            bytes[offset + 2] = blue
        }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    return try XCTUnwrap(
        CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    )
}
