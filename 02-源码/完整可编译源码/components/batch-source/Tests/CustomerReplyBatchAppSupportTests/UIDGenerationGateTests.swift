import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class UIDGenerationGateTests: XCTestCase {
    func testSameUIDSerializesFIFOWhileDifferentUIDRunsImmediately() async throws {
        let gate = UIDGenerationGate()
        let events = EventRecorder()

        let first = Task {
            await gate.withPermit(for: "u1") {
                await events.append("u1-first-start")
                try? await Task.sleep(nanoseconds: 150_000_000)
                await events.append("u1-first-end")
            }
        }
        await events.waitUntilRecorded("u1-first-start")

        let second = Task {
            await gate.withPermit(for: "u1") {
                await events.append("u1-second-start")
            }
        }
        let otherUser = Task {
            await gate.withPermit(for: "u2") {
                await events.append("u2-start")
            }
        }

        try await Task.sleep(nanoseconds: 40_000_000)
        let whileFirstRuns = await events.snapshot()
        XCTAssertTrue(whileFirstRuns.contains("u2-start"))
        XCTAssertFalse(whileFirstRuns.contains("u1-second-start"))

        await first.value
        await second.value
        await otherUser.value
        let completed = await events.snapshot()
        XCTAssertLessThan(
            completed.firstIndex(of: "u1-first-end")!,
            completed.firstIndex(of: "u1-second-start")!
        )
    }
}

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func waitUntilRecorded(_ event: String) async {
        while !events.contains(event) {
            await Task.yield()
        }
    }
}
