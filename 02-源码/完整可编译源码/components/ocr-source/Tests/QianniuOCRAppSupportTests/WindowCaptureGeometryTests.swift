import CoreGraphics
import XCTest
@testable import QianniuOCRAppSupport

final class WindowCaptureGeometryTests: XCTestCase {
    func testMixedScaleExternalWindowUsesOneOutputPixelPerWindowPoint() {
        XCTAssertEqual(
            OCRWindowCaptureGeometry.outputSize(
                for: CGRect(x: -1278, y: 190, width: 1310, height: 800)
            ),
            CGSize(width: 1310, height: 800)
        )
    }
}
