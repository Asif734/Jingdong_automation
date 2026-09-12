import CoreGraphics
import ImageIO
import XCTest
@testable import QianniuOCRAppSupport

final class ImageCopyCandidateDetectorTests: XCTestCase {
    func testFindsPaleScreenshotThatLegacyImageDetectorMisses() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "qianniu-pale-screenshot-message",
                withExtension: "jpeg",
                subdirectory: "Fixtures"
            )
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertTrue(ConsensusChatImageDetector().detect(in: image).isEmpty)

        let candidates = ImageCopyCandidateDetector().detect(in: image)

        XCTAssertTrue(candidates.contains {
            intersectionOverUnion($0, CGRect(x: 0, y: 39, width: 270, height: 304)) >= 0.88
        }, "candidates: \(candidates)")
    }
}

private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    return unionArea > 0 ? intersectionArea / unionArea : 0
}
