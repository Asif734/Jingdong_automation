import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class PipelineStatusReaderTests: XCTestCase {
    func testNewSuccessIsNotHiddenByOlderUncertainSend() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("待人工确认/old.json")
        let new = root.appendingPathComponent("已完成/tb263147182/new.json")
        try writeJSON(["uid": "tb263147182", "send_error": "旧发送待核实"], to: old)
        try writeJSON(["uid": "tb263147182", "send_status": "sent"], to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: new.path)

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .completed)
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNil(snapshot.detail)
        XCTAssertEqual(snapshot.counts.humanReview, 1, "Old warning must remain available, not be deleted")
        XCTAssertTrue(snapshot.earlierWarning?.contains("旧发送待核实") == true)
        XCTAssertTrue(snapshot.earlierWarning?.contains("tb263147182") == true)
    }

    func testNewUncertainSendStillAppearsAheadOfOldSuccess() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("已完成/customer/old.json")
        let new = root.appendingPathComponent("待人工确认/new.json")
        try writeJSON(["uid": "customer", "send_status": "sent"], to: old)
        try writeJSON(["uid": "customer", "send_error": "本次待核实"], to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: new.path)
        let snapshot = PipelineStatusReader(root: root).read()
        XCTAssertEqual(snapshot.stage, .humanReview)
        XCTAssertEqual(snapshot.detail, "本次待核实")
    }

    func testReportsGeneratingTaskAheadOfQueuedTask() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(["uid": "queued-user"], to: root.appendingPathComponent("待处理/queued.json"))
        try writeJSON(["uid": "working-user"], to: root.appendingPathComponent("处理中/working.json"))

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .generating)
        XCTAssertEqual(snapshot.currentUID, "working-user")
        XCTAssertEqual(snapshot.counts.queued, 1)
        XCTAssertEqual(snapshot.counts.generating, 1)
        XCTAssertEqual(snapshot.headline, "Codex 正在生成回复")
    }

    func testReportsSendingAheadOfWaitingToSend() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(["uid": "waiting-user"], to: root.appendingPathComponent("待发送/waiting.json"))
        try writeJSON(["uid": "sending-user"], to: root.appendingPathComponent("发送中/sending.json"))

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .sending)
        XCTAssertEqual(snapshot.currentUID, "sending-user")
        XCTAssertEqual(snapshot.counts.awaitingSend, 1)
        XCTAssertEqual(snapshot.counts.sending, 1)
    }

    func testPublishedHumanReviewIsNotStillCountedAsGenerating() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(
            ["uid": "review-user"],
            to: root.appendingPathComponent("处理中/shared-task.json")
        )
        try writeJSON(
            ["uid": "review-user", "reason": "需要人工核实"],
            to: root.appendingPathComponent("待人工确认/shared-task.json")
        )

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .humanReview)
        XCTAssertEqual(snapshot.counts.generating, 0)
        XCTAssertEqual(snapshot.counts.humanReview, 1)
        XCTAssertEqual(snapshot.detail, "需要人工核实")
    }

    func testReportsMostRecentTerminalFailureAndItsReason() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(
            ["uid": "failed-user", "send_error": "没有找到输入框"],
            to: root.appendingPathComponent("发送失败/failed.json")
        )

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .failed)
        XCTAssertEqual(snapshot.currentUID, "failed-user")
        XCTAssertEqual(snapshot.detail, "没有找到输入框")
        XCTAssertEqual(snapshot.counts.failed, 1)
    }

    func testReportsLatestCompletedTaskRecursively() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJSON(
            ["uid": "done-user", "send_status": "sent"],
            to: root.appendingPathComponent("已完成/done-user/task.json")
        )

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .completed)
        XCTAssertEqual(snapshot.currentUID, "done-user")
        XCTAssertEqual(snapshot.counts.completed, 1)
    }

    func testIgnoresHiddenAndNonJSONFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("待处理/.partial.json"))
        try Data().write(to: root.appendingPathComponent("待处理/readme.txt"))

        let snapshot = PipelineStatusReader(root: root).read()

        XCTAssertEqual(snapshot.stage, .idle)
        XCTAssertEqual(snapshot.counts.totalActive, 0)
    }

    func testRefreshesCachedDirectoryAfterQueueChanges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = PipelineStatusReader(root: root)
        XCTAssertEqual(reader.read().counts.queued, 0)

        try writeJSON(
            ["uid": "new-user"],
            to: root.appendingPathComponent("待处理/new-task.json")
        )

        let refreshed = reader.read()
        XCTAssertEqual(refreshed.stage, .queued)
        XCTAssertEqual(refreshed.currentUID, "new-user")
        XCTAssertEqual(refreshed.counts.queued, 1)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-status-tests-\(UUID().uuidString)", isDirectory: true)
        for name in ["待处理", "处理中", "待发送", "发送中", "待人工确认", "失败", "发送失败", "已完成"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private func writeJSON(_ object: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}
