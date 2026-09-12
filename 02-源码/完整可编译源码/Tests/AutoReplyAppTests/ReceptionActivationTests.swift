import XCTest
@testable import AutoReplyApp

final class ReceptionActivationTests: XCTestCase {
    @MainActor func testRejectsFrontmostWorkbenchPageAsReceptionFocus() {
        XCTAssertFalse(NativeSession.targetFocusMatches(
            appIsFrontmost: true,
            targetMatchesFocusedWindow: true,
            targetTitle: "加普威旗舰店:小甘-千牛工作台"
        ))
    }

    @MainActor func testActivationRetriesUntilReceptionFocusIsConfirmed() async throws {
        var requests = 0
        var focusRequests = 0
        var raises = 0
        var readbacks = 0

        let focused = try await NativeSession.activateWindow(
            request: { requests += 1; return true },
            focus: { focusRequests += 1; return true },
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
}
