import XCTest
@testable import UnreadApp

final class LiveNicknameFallbackTests: XCTestCase {
    @MainActor
    func testLiveSnapshotListsCurrentRowsWithoutClicking() throws {
        guard ProcessInfo.processInfo.environment["QIANNIU_LIVE_READONLY"] == "1" else {
            throw XCTSkip("只在显式只读实机验证时运行")
        }
        let session = NativeSession()
        try session.check()
        let rows = try session.snapshot().rows
        XCTAssertFalse(rows.isEmpty)
        print("LIVE_ROWS=" + rows.map { "\($0.uid)|\($0.nickname ?? "-")" }.joined(separator: ","))
    }
}
