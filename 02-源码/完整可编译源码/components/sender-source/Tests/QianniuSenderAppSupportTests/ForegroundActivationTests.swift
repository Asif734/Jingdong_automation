import XCTest
@testable import QianniuSenderAppSupport

final class ForegroundActivationTests: XCTestCase {
    func testRejectsFrontmostWorkbenchPageAsReceptionFocus() {
        XCTAssertFalse(QianniuAXSession.targetFocusMatches(
            appIsFrontmost: true,
            targetMatchesFocusedWindow: true,
            targetTitle: "加普威旗舰店:小甘-千牛工作台"
        ))
    }

    func testActivationRetriesUntilReceptionFocusIsConfirmed() async throws {
        var requests = 0
        var focusRequests = 0
        var raises = 0
        var readbacks = 0

        let focused = try await QianniuAXSession.activateWindow(
            request: { requests += 1 },
            focus: {
                focusRequests += 1
                return true
            },
            raise: { raises += 1; return true },
            verify: {
                readbacks += 1
                return readbacks == 3
            },
            maximumAttempts: 3,
            pause: {}
        )

        XCTAssertTrue(focused)
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(focusRequests, 3)
        XCTAssertEqual(raises, 3)
        XCTAssertEqual(readbacks, 3)
    }

    func testRejectedApplicationActivationRequestDoesNotBlockAXRaise() throws {
        XCTAssertNoThrow(try QianniuAXSession.requestApplicationActivation(
            isHidden: false,
            unhide: { XCTFail("visible app must not be unhidden"); return false },
            activate: { false }
        ))
    }

}
