import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class HistoryContinuationTests: XCTestCase {
    func testFirstSubmissionContainsFullHistoryAndEveryAttachment() throws {
        let images = try makeImages(["one": "first-image", "two": "second-image"])
        defer { try? FileManager.default.removeItem(at: images.root) }
        let input = PromptInput(
            uid: "u1",
            historyVersion: "v1",
            historyJSONL: "{\"v\":\"first\"}\n{\"v\":\"second\"}",
            historyText: "",
            imagePaths: [images.paths["one"]!, images.paths["two"]!]
        )

        let submission = try HistoryContinuation.plan(input: input, after: nil)

        XCTAssertEqual(submission.mode, .full)
        XCTAssertEqual(submission.historyJSONL, input.historyJSONL)
        XCTAssertEqual(submission.imagePaths, input.imagePaths)
    }

    func testStrictAppendSubmitsOnlyHistorySuffix() throws {
        let original = PromptInput(
            uid: "u1", historyVersion: "v1",
            historyJSONL: "{\"v\":\"first\"}\n",
            historyText: "", imagePaths: []
        )
        let checkpoint = try HistoryContinuation.plan(input: original, after: nil).checkpoint
        let updated = PromptInput(
            uid: "u1", historyVersion: "v2",
            historyJSONL: "{\"v\":\"first\"}\n{\"v\":\"second\"}\n",
            historyText: "", imagePaths: []
        )

        let submission = try HistoryContinuation.plan(input: updated, after: checkpoint)

        XCTAssertEqual(submission.mode, .incremental)
        XCTAssertEqual(submission.historyJSONL, "{\"v\":\"second\"}\n")
    }

    func testEditedHistoryInvalidatesIncrementalSubmission() throws {
        let original = PromptInput(
            uid: "u1", historyVersion: "v1",
            historyJSONL: "{\"v\":\"first\"}\n",
            historyText: "", imagePaths: []
        )
        let checkpoint = try HistoryContinuation.plan(input: original, after: nil).checkpoint
        let rewritten = PromptInput(
            uid: "u1", historyVersion: "v2",
            historyJSONL: "{\"v\":\"changed\"}\n{\"v\":\"second\"}\n",
            historyText: "", imagePaths: []
        )

        let submission = try HistoryContinuation.plan(input: rewritten, after: checkpoint)

        XCTAssertEqual(submission.mode, .full)
        XCTAssertEqual(submission.historyJSONL, rewritten.historyJSONL)
    }

    func testIncrementalSubmissionIncludesOnlyNewAttachmentContent() throws {
        let images = try makeImages(["old": "old-image", "new": "new-image"])
        defer { try? FileManager.default.removeItem(at: images.root) }
        let original = PromptInput(
            uid: "u1", historyVersion: "v1", historyJSONL: "old\n", historyText: "",
            imagePaths: [images.paths["old"]!]
        )
        let checkpoint = try HistoryContinuation.plan(input: original, after: nil).checkpoint
        let updated = PromptInput(
            uid: "u1", historyVersion: "v2", historyJSONL: "old\nnew\n", historyText: "",
            imagePaths: [images.paths["old"]!, images.paths["new"]!]
        )

        let submission = try HistoryContinuation.plan(input: updated, after: checkpoint)

        XCTAssertEqual(submission.mode, .incremental)
        XCTAssertEqual(submission.imagePaths, [images.paths["new"]!])
    }

    func testSameAttachmentBytesAtANewPathAreNotResubmitted() throws {
        let images = try makeImages(["old": "same-image", "copy": "same-image"])
        defer { try? FileManager.default.removeItem(at: images.root) }
        let original = PromptInput(
            uid: "u1", historyVersion: "v1", historyJSONL: "old\n", historyText: "",
            imagePaths: [images.paths["old"]!]
        )
        let checkpoint = try HistoryContinuation.plan(input: original, after: nil).checkpoint
        let updated = PromptInput(
            uid: "u1", historyVersion: "v2", historyJSONL: "old\nnew\n", historyText: "",
            imagePaths: [images.paths["old"]!, images.paths["copy"]!]
        )

        let submission = try HistoryContinuation.plan(input: updated, after: checkpoint)

        XCTAssertTrue(submission.imagePaths.isEmpty)
    }

    func testMissingAttachmentFailsInsteadOfSilentlyLosingCustomerContent() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
            .path
        let input = PromptInput(
            uid: "u1", historyVersion: "v1", historyJSONL: "image\n", historyText: "",
            imagePaths: [missingPath]
        )

        XCTAssertThrowsError(try HistoryContinuation.plan(input: input, after: nil))
    }

    func testExternalEvidenceSubmitsAllEvidenceButPreservesConversationCheckpoint() throws {
        let images = try makeImages(["frame": "video-frame"])
        defer { try? FileManager.default.removeItem(at: images.root) }
        let ordinary = PromptInput(
            uid: "u1", historyVersion: "ordinary",
            historyJSONL: "{\"v\":\"earlier customer message\"}\n",
            historyText: "", imagePaths: []
        )
        let existing = try HistoryContinuation.plan(input: ordinary, after: nil).checkpoint
        let video = PromptInput(
            uid: "u1", historyVersion: "video-analysis:hash",
            historyJSONL: "{\"t\":\"video_evidence\"}\n",
            historyText: "", imagePaths: [images.paths["frame"]!],
            preservesHistoryCheckpoint: true
        )

        let submission = try HistoryContinuation.planExternalEvidence(input: video, preserving: existing)

        XCTAssertEqual(submission.mode, .incremental)
        XCTAssertEqual(submission.historyJSONL, video.historyJSONL)
        XCTAssertEqual(submission.imagePaths, video.imagePaths)
        XCTAssertEqual(submission.checkpoint, existing)
    }

    private func makeImages(_ contents: [String: String]) throws -> (root: URL, paths: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryContinuationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var paths: [String: String] = [:]
        for (name, content) in contents {
            let url = root.appendingPathComponent(name).appendingPathExtension("jpg")
            try Data(content.utf8).write(to: url)
            paths[name] = url.path
        }
        return (root, paths)
    }
}
