import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class CodexLoginCacheTests: XCTestCase {
    func testSuccessfulLoginCheckIsCachedForSixtySeconds() async throws {
        let cache = CodexLoginCache(ttl: 60)
        let recorder = LoginCheckRecorder()
        let start = Date(timeIntervalSince1970: 1_000)

        try await cache.ensureLoggedIn(now: start) { await recorder.check() }
        try await cache.ensureLoggedIn(now: start.addingTimeInterval(59)) {
            await recorder.check()
        }
        var count = await recorder.count
        XCTAssertEqual(count, 1)

        try await cache.ensureLoggedIn(now: start.addingTimeInterval(61)) {
            await recorder.check()
        }
        count = await recorder.count
        XCTAssertEqual(count, 2)
    }

    func testConcurrentCallsShareOneInFlightLoginCheck() async throws {
        let cache = CodexLoginCache(ttl: 60)
        let recorder = LoginCheckRecorder(delay: .milliseconds(10))
        let now = Date(timeIntervalSince1970: 1_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await cache.ensureLoggedIn(now: now) {
                        await recorder.check()
                    }
                }
            }
            try await group.waitForAll()
        }

        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testFailedCheckAlwaysClearsSharedInFlightState() async throws {
        let cache = CodexLoginCache(ttl: 60)
        do {
            try await cache.ensureLoggedIn { throw LoginFixtureError.failed }
            XCTFail("first check must fail")
        } catch { }
        let recorder = LoginCheckRecorder()
        try await cache.ensureLoggedIn { await recorder.check() }
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }
}

private enum LoginFixtureError: Error { case failed }

private actor LoginCheckRecorder {
    private(set) var count = 0
    private let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    func check() async {
        count += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
    }
}
