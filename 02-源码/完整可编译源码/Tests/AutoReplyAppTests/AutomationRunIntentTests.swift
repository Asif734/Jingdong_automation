import XCTest
@testable import AutoReplyApp

final class AutomationRunIntentTests: XCTestCase {
    func testAtomicIntentRoundTripIncludesAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationRunIntentStore(url: root.appendingPathComponent("运行意图.json"))
        let value = AutomationRunIntent(desiredState: .running, aliases: ["小丹", "小秦"])
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
    }

    func testLegacyTestOnlyIntentLoadsAsAllCustomers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-intent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("运行意图.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"desiredState":"running","testOnly":true,"aliases":["小丹"]}"#.utf8).write(to: url)

        let value = try AutomationRunIntentStore(url: url).load()

        XCTAssertEqual(value, AutomationRunIntent(desiredState: .running, aliases: ["小丹"]))
    }

    func testMissingIntentDefaultsToStopped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())/运行意图.json")
        XCTAssertEqual(try AutomationRunIntentStore(url: url).load(), .stoppedDefault)
    }

    func testRetryBackoffCapsAtThirtySeconds() {
        XCTAssertEqual((0..<7).map(StartRetryPolicy.delay(afterFailureCount:)), [1, 2, 5, 10, 30, 30, 30])
    }
}
