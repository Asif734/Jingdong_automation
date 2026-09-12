import XCTest
import QianniuOCRAppSupport
@testable import AutoReplyApp

final class LiveMediaRoutingTests: XCTestCase {
    func testExactVideoResolutionMapsToOpenVideoBeforeCopy() async {
        let resolver = FixedVisualMediaResolver(.ignoreVideo(messageID: "VIDEO.PNM"))

        let action = await LiveMediaRouting.action(
            resolver: resolver,
            customerUID: "buyer-a",
            now: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(action, .openVideo(messageID: "VIDEO.PNM", customerUID: "buyer-a"))
        let received = await resolver.receivedUIDs()
        XCTAssertEqual(received, ["buyer-a"])
    }

    func testImageAndUnknownResolutionMapToExistingCopyFlow() async {
        for resolution in [
            VisualMediaResolution.copyImage(messageID: "IMAGE.PNM"),
            VisualMediaResolution.copyImage(messageID: nil),
        ] {
            let resolver = FixedVisualMediaResolver(resolution)

            let action = await LiveMediaRouting.action(
                resolver: resolver,
                customerUID: "buyer-a",
                now: Date(timeIntervalSince1970: 123)
            )

            XCTAssertEqual(action, .copy)
        }
    }

    func testInFlightVideoSkipsCopyAndDoesNotOpenAgain() async {
        let action = await LiveMediaRouting.action(
            resolver: FixedVisualMediaResolver(.videoInFlight(messageID: "VIDEO.ACTIVE")),
            customerUID: "buyer-a"
        )

        XCTAssertEqual(action, .videoInFlight(messageID: "VIDEO.ACTIVE"))
    }
}

private actor FixedVisualMediaResolver: VisualMediaTypeResolving {
    let result: VisualMediaResolution
    private var uids: [String] = []

    init(_ result: VisualMediaResolution) { self.result = result }

    func resolve(customerUID: String, now: Date) async -> VisualMediaResolution {
        uids.append(customerUID)
        return result
    }

    func receivedUIDs() -> [String] { uids }
}
