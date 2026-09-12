import XCTest
@testable import UnreadApp

final class ActivationTests: XCTestCase {
    @MainActor func testOpeningApplicationErrorStopsBeforeRaisingWindow() async {
        do {
            try await NativeSession.activateWindow(request: { throw NSError(domain: "activation", code: 1) }, raise: {
                XCTFail("failed open must not raise or click"); return true
            }, isFrontmost: { true })
            XCTFail("must propagate activation failure")
        } catch { XCTAssertEqual((error as NSError).domain, "activation") }
    }
    // OS calls are external boundaries; exercise the production activation decision.
    @MainActor func testRejectedRequestStillSucceedsWhenRaiseMakesTargetFrontmost() async throws {
        var front = false
        try await NativeSession.activateWindow(request: { false }, raise: { front = true; return true }, isFrontmost: { front })
    }
    @MainActor func testAcceptedRequestWaitsForActualForeground() async throws {
        var front = false
        let transition = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            front = true
        }
        try await NativeSession.activateWindow(request: { true }, raise: { true }, isFrontmost: { front })
        XCTAssertTrue(front, "request acceptance alone must not permit clicking")
        try await transition.value
    }
    @MainActor func testAcceptedRequestWithoutForegroundFailsWithinBound() async {
        let start = Date()
        do {
            try await NativeSession.activateWindow(request: { true }, raise: { true }, isFrontmost: { false })
            XCTFail("must not proceed while another app is foreground")
        } catch { XCTAssertTrue(error.localizedDescription.contains("前台")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    @MainActor func testRaiseFailureDoesNotProceedEvenIfAppIsFrontmost() async {
        do {
            try await NativeSession.activateWindow(request: { true }, raise: { false }, isFrontmost: { true })
            XCTFail("the exact reception window must be raised")
        } catch { XCTAssertTrue(error.localizedDescription.contains("接待窗口")) }
    }
}
