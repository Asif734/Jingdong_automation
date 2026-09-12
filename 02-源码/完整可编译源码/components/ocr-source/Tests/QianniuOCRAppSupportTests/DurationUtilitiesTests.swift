import XCTest
@testable import QianniuOCRAppSupport

final class DurationUtilitiesTests: XCTestCase {
    func testWholeMillisecondsIncludesWholeSecondsAndFraction() {
        let duration = Duration.seconds(2) + .milliseconds(345)

        XCTAssertEqual(duration.wholeMilliseconds, 2_345)
    }
}
