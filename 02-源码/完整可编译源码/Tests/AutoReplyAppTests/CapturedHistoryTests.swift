import XCTest
import CryptoKit
import AutoReplyCore
import Darwin
@testable import AutoReplyApp

final class CapturedHistoryTests: XCTestCase {
    func testSnapshotUsesInjectedPortableKnowledgeBasePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-portable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("用户/buyer")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("{\"request_id\":\"c1\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"问\",\"timestamp\":\"2026-8-28 10:00:00\"}\n".utf8)
            .write(to: user.appendingPathComponent("history.jsonl"))
        let portable = root.appendingPathComponent("Support/KnowledgeBase/current.zip")

        let snapshot = try CapturedHistory(root: root, knowledgeBasePaths: [portable.path])
            .snapshot(uid: "buyer", latestSpeaker: "customer", newlyQueued: true)

        XCTAssertEqual(snapshot.knowledgeBasePaths, [portable.path])
    }
    private var root: URL!
    private var user: URL { root.appendingPathComponent("用户/tb12345") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("images"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: user.appendingPathComponent("history.jsonl"))
    }
    private let first = "{\"request_id\":\"capture1\",\"created_at\":\"now\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"你好\",\"timestamp\":\"2026-8-26 11:00:00\",\"read_status\":\"未读\"}\n"
    private func capture(_ speaker: String? = "customer", queued: Bool = true) throws -> AutoReplyCore.CaptureSnapshot {
        try CapturedHistory(root: root).snapshot(uid: "tb12345", latestSpeaker: speaker, newlyQueued: queued)
    }
    private func capture(after cursor: CustomerCursor, speaker: String? = "customer", queued: Bool = true) throws -> AutoReplyCore.CaptureSnapshot {
        try CapturedHistory(root: root).snapshot(
            uid: "tb12345",
            latestSpeaker: speaker,
            newlyQueued: queued,
            after: cursor
        )
    }

    func testServiceTailCannotHideLaterCustomerMessagesBeyondAnsweredCursor() throws {
        let a = "{\"request_id\":\"a\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"A\"}\n"
        let b = "{\"request_id\":\"b\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"B\"}\n"
        let c = "{\"request_id\":\"c\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"C\"}\n"
        let replyA = "{\"request_id\":\"reply-a\",\"sender\":\"service\",\"t\":\"text\",\"v\":\"answer A\"}\n"
        try write(a)
        let cursorA = try XCTUnwrap(try capture(after: .empty).endCursor)
        try write(a + b + c + replyA)

        let snapshot = try capture(after: cursorA, speaker: "service", queued: true)

        XCTAssertTrue(snapshot.hasUnansweredCustomer)
        XCTAssertTrue(snapshot.shouldGenerate)
        XCTAssertEqual(snapshot.startCursor, cursorA)
        XCTAssertTrue(snapshot.targetCustomerJSONL.contains("\"v\":\"B\""))
        XCTAssertTrue(snapshot.targetCustomerJSONL.contains("\"v\":\"C\""))
        XCTAssertFalse(snapshot.targetCustomerJSONL.contains("answer A"))
    }
    func testMigrationBaselineStopsAtLastServiceAndLeavesLaterCustomerTail() throws {
        let a = "{\"request_id\":\"a\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"A\"}\n"
        let replyA = "{\"request_id\":\"reply-a\",\"sender\":\"service\",\"t\":\"text\",\"v\":\"answer A\"}\n"
        let b = "{\"request_id\":\"b\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"B\"}\n"
        try write(a + replyA + b)

        let baseline = try CapturedHistory(root: root).migrationBaselineCursor(uid: "tb12345")
        let tail = try capture(after: baseline, speaker: "customer", queued: true)

        XCTAssertEqual(baseline.count, 1)
        XCTAssertEqual(tail.targetCustomerJSONL, b)
    }
    func testRevisionIgnoresReadStatusServiceAppendAndCreatedAt() throws {
        try write(first)
        let before = try capture()
        try write(first.replacingOccurrences(of: "未读", with: "已读").replacingOccurrences(of: "now", with: "later") +
            "{\"request_id\":\"service1\",\"sender\":\"service\",\"t\":\"text\",\"v\":\"您好\"}\n")
        let after = try capture("service")
        XCTAssertFalse(before.customerRevision.isEmpty)
        XCTAssertEqual(before.customerRevision, after.customerRevision)
        XCTAssertTrue(before.hasUnansweredCustomer)
        XCTAssertFalse(after.hasUnansweredCustomer)
    }
    func testRepeatedIdenticalCustomerEventsRetainIdentity() throws {
        try write(first)
        let before = try capture()
        try write(first + first.replacingOccurrences(of: "capture1", with: "capture2"))
        XCTAssertNotEqual(before.customerRevision, try capture().customerRevision)
    }
    func testRepeatedIdenticalEventsWithinOneCaptureRemainDistinct() throws {
        try write(first)
        let before = try capture()
        try write(first + first)
        XCTAssertNotEqual(before.customerRevision, try capture().customerRevision)
    }
    func testImageRevisionUsesBytesAndSnapshotImagesAreImmutable() throws {
        let image = user.appendingPathComponent("images/old.jpg")
        try Data("photo".utf8).write(to: image)
        let line = "{\"request_id\":\"capture1\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/old.jpg\"}\n"
        try write(line)
        let before = try capture()
        try Data("photo".utf8).write(to: user.appendingPathComponent("images/new.jpg"))
        try write(line.replacingOccurrences(of: "old.jpg", with: "new.jpg"))
        XCTAssertEqual(before.customerRevision, try capture().customerRevision)
        XCTAssertEqual(before.imagePaths.count, 1)
        guard let frozen = before.imagePaths.first else { return XCTFail("Missing frozen image") }
        try Data("changed".utf8).write(to: image)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: frozen)), Data("photo".utf8))
        try Data("different photo".utf8).write(to: user.appendingPathComponent("images/new.jpg"))
        XCTAssertNotEqual(before.customerRevision, try capture().customerRevision)
    }
    func testMissingHistoricalImageGetsStableLocalIdentityWithoutWeakeningPathValidation() throws {
        let line = "{\"request_id\":\"old-image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/deleted.jpg\"}\n"
        try write(line)

        let firstCursor = try CapturedHistory(root: root).currentCursor(uid: "tb12345")
        let secondCursor = try CapturedHistory(root: root).currentCursor(uid: "tb12345")

        XCTAssertEqual(firstCursor, secondCursor)
        XCTAssertEqual(firstCursor.count, 1)
        try write("{\"request_id\":\"bad\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"../../outside.jpg\"}\n")
        XCTAssertThrowsError(try CapturedHistory(root: root).currentCursor(uid: "tb12345"))
    }
    func testMissingImageDoesNotBlockTextFromSameCursorBatch() throws {
        try write(
            "{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/deleted.jpg\"}\n" +
            "{\"request_id\":\"text\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"机器不开机\"}\n"
        )

        let snapshot = try capture(after: .empty)

        XCTAssertTrue(snapshot.shouldGenerate)
        XCTAssertTrue(snapshot.imagePaths.isEmpty)
        XCTAssertTrue(snapshot.targetCustomerJSONL.contains("机器不开机"))
    }
    func testPureMissingImageBatchWaitsForAttachmentInsteadOfGeneratingWithoutIt() throws {
        try write("{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/deleted.jpg\"}\n")

        let snapshot = try capture(after: .empty)

        XCTAssertTrue(snapshot.hasUnansweredCustomer)
        XCTAssertFalse(snapshot.shouldGenerate)
        XCTAssertTrue(snapshot.imagePaths.isEmpty)
    }
    func testImageIdentityManifestIsIsolatedPerUIDForSameRelativePath() throws {
        let other = root.appendingPathComponent("用户/tb67890")
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )
        let line = "{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/x.jpg\"}\n"
        try Data("first customer photo".utf8).write(to: user.appendingPathComponent("images/x.jpg"))
        try Data(line.utf8).write(to: user.appendingPathComponent("history.jsonl"))
        try Data("second customer photo".utf8).write(to: other.appendingPathComponent("images/x.jpg"))
        try Data(line.utf8).write(to: other.appendingPathComponent("history.jsonl"))
        let history = CapturedHistory(root: root)
        let first = try history.currentCursor(uid: "tb12345")
        let second = try history.currentCursor(uid: "tb67890")
        XCTAssertNotEqual(first, second)

        try FileManager.default.removeItem(at: user.appendingPathComponent("images/x.jpg"))
        try FileManager.default.removeItem(at: other.appendingPathComponent("images/x.jpg"))

        XCTAssertEqual(try history.currentCursor(uid: "tb12345"), first)
        XCTAssertEqual(try history.currentCursor(uid: "tb67890"), second)
        let identityRoot = root.appendingPathComponent("运行状态/调度器/image-identities")
        let identityFiles = try FileManager.default.subpathsOfDirectory(atPath: identityRoot.path)
            .map { identityRoot.appendingPathComponent($0) }
            .filter { $0.pathExtension == "txt" }
        XCTAssertEqual(identityFiles.count, 2)
        for file in identityFiles {
            let permissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }
    func testLinkMessagesParticipateInCustomerRevisionJustLikeTextAndImages() throws {
        try write("{\"request_id\":\"link1\",\"sender\":\"customer\",\"t\":\"link\",\"v\":\"https://example.com/first\"}\n")
        let before = try capture()
        try write(
            "{\"request_id\":\"link1\",\"sender\":\"customer\",\"t\":\"link\",\"v\":\"https://example.com/first\"}\n" +
            "{\"request_id\":\"link2\",\"sender\":\"customer\",\"t\":\"link\",\"v\":\"https://example.com/second\"}\n"
        )
        XCTAssertNotEqual(before.customerRevision, try capture().customerRevision)
    }
    func testPromptNeverReadsHistoryTextAndVisibleServiceInvalidatesOldCustomerTail() throws {
        try write(first)
        try Data("DO NOT READ history.txt".utf8).write(to: user.appendingPathComponent("history.txt"))
        let snapshot = try capture("service")
        XCTAssertEqual(snapshot.historyJSONL, first)
        XCTAssertEqual(snapshot.promptInput.historyText, "")
        XCTAssertFalse(snapshot.hasUnansweredCustomer)
    }
    func testDurablyQueuedCustomerImageOverridesStaleVisibleServiceTail() throws {
        let image = user.appendingPathComponent("images/new.jpg")
        try Data("photo".utf8).write(to: image)
        try write(
            "{\"request_id\":\"capture1\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/new.jpg\"}\n" +
            "{\"request_id\":\"capture1\",\"sender\":\"service\",\"t\":\"text\",\"v\":\"旧回复\"}\n"
        )

        let snapshot = try capture("service", queued: true)

        XCTAssertTrue(snapshot.hasUnansweredCustomer)
        XCTAssertTrue(snapshot.shouldGenerate)
        XCTAssertEqual(snapshot.imagePaths.count, 1)
    }
    private func pointer(history: String, currentCustomerImagePaths: [String] = []) throws -> URL {
        let dir = root.appendingPathComponent("待处理")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tb12345.json")
        let hash = SHA256.hash(data: Data(history.utf8)).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: [
            "uid": "tb12345",
            "user_directory": user.path,
            "queued_at": "now",
            "history_version": hash,
            "current_customer_image_paths": currentCustomerImagePaths,
        ])
        try data.write(to: url)
        return url
    }
    func testSnapshotAttachesOnlyCurrentCustomerImages() throws {
        let oldImage = user.appendingPathComponent("images/old.jpg")
        let currentImage = user.appendingPathComponent("images/current.jpg")
        try Data("old photo".utf8).write(to: oldImage)
        try Data("current photo".utf8).write(to: currentImage)
        let history =
            "{\"request_id\":\"old\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/old.jpg\"}\n" +
            "{\"request_id\":\"current\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/current.jpg\"}\n" +
            "{\"request_id\":\"current\",\"sender\":\"service\",\"t\":\"text\",\"v\":\"旧回复\"}\n" +
            "{\"request_id\":\"current\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"旧的可见文字\"}\n"
        try write(history)
        _ = try pointer(history: history, currentCustomerImagePaths: ["images/current.jpg"])

        let snapshot = try capture("customer", queued: true)

        XCTAssertEqual(snapshot.imagePaths.count, 1)
        XCTAssertEqual(try snapshot.imagePaths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, [
            Data("current photo".utf8),
        ])
    }
    func testRepeatedIdenticalHistoricalImagesAttachOnlyCurrentImageOnce() throws {
        let firstImage = user.appendingPathComponent("images/first.jpg")
        let repeatedImage = user.appendingPathComponent("images/repeated.jpg")
        try Data("same photo".utf8).write(to: firstImage)
        try Data("same photo".utf8).write(to: repeatedImage)
        let history =
            "{\"request_id\":\"first\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/first.jpg\"}\n" +
            "{\"request_id\":\"second\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/repeated.jpg\"}\n"
        try write(history)
        _ = try pointer(history: history, currentCustomerImagePaths: ["images/repeated.jpg"])

        let snapshot = try capture("customer", queued: true)

        XCTAssertEqual(snapshot.imagePaths.count, 1)
        XCTAssertEqual(try snapshot.imagePaths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, [
            Data("same photo".utf8),
        ])
    }
    func testTextOnlyPendingMessageDoesNotResubmitHistoricalImages() throws {
        let oldImage = user.appendingPathComponent("images/old.jpg")
        try Data("old photo".utf8).write(to: oldImage)
        let history =
            "{\"request_id\":\"old\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/old.jpg\"}\n" +
            "{\"request_id\":\"old\",\"sender\":\"service\",\"t\":\"text\",\"v\":\"已回复旧图\"}\n" +
            "{\"request_id\":\"current\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"新问题\"}\n"
        try write(history)
        _ = try pointer(history: history, currentCustomerImagePaths: [])

        let snapshot = try capture("customer", queued: true)

        XCTAssertTrue(snapshot.imagePaths.isEmpty)
    }
    func testCommittedExporterPointerRecoversAfterSnapshotCrashGap() throws {
        try write(first)
        _ = try pointer(history: first)
        XCTAssertTrue(try capture(queued: false).shouldGenerate)
        try write(first + "{\"request_id\":\"sys\",\"sender\":\"unknown\",\"t\":\"text\",\"v\":\"系统提示\"}\n")
        XCTAssertTrue(try capture(queued: false).shouldGenerate)
    }
    func testVerifiedCompletionRemovesMatchingPointerButNeverNewerRevision() throws {
        try write(first)
        let old = try capture()
        let url = try pointer(history: first)
        try CapturedHistory(root: root).complete(uid: "tb12345", revision: old.customerRevision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let newer = first + first.replacingOccurrences(of: "capture1", with: "capture2")
        try write(newer)
        _ = try pointer(history: newer)
        try CapturedHistory(root: root).complete(uid: "tb12345", revision: old.customerRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testBatchCompletionChecksManyOldRevisionsAgainstCurrentPointerOnce() throws {
        try write(first)
        let current = try capture()
        let url = try pointer(history: first)
        var completed = Set((0..<100).map { "old-\($0)" })
        completed.insert(current.customerRevision)

        try CapturedHistory(root: root).complete(
            uid: "tb12345",
            completedRevisions: completed
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testBatchCompletionKeepsPointerWhenCurrentRevisionIsNotCompleted() throws {
        try write(first)
        let url = try pointer(history: first)

        try CapturedHistory(root: root).complete(
            uid: "tb12345",
            completedRevisions: Set((0..<100).map { "old-\($0)" })
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testCursorSnapshotCompletionRemovesOnlyItsExactCommittedPointer() throws {
        try write(first)
        let pointerURL = try pointer(history: first)
        let frozen = try capture(after: .empty)

        try CapturedHistory(root: root).complete(
            uid: "tb12345",
            revision: try XCTUnwrap(frozen.endCursor).digest
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: pointerURL.path))
    }
    func testNoPointerDoesNotRegenerateImportedHistory() throws {
        try write(first)
        XCTAssertFalse(try capture(queued: false).shouldGenerate)
    }
    func testRejectsUnsafeUIDAndEscapingImagePath() throws {
        XCTAssertThrowsError(try CapturedHistory(root: root).snapshot(uid: "../elsewhere", latestSpeaker: "customer", newlyQueued: true))
        try write("{\"request_id\":\"c1\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"../../outside.jpg\"}\n")
        XCTAssertThrowsError(try capture())
    }
    func testChangedTimestampWithIdenticalTextAndChangedReadStatusIsNewEvent() throws {
        try write(first)
        let before = try capture()
        let next = first.replacingOccurrences(of: "capture1", with: "capture2")
            .replacingOccurrences(of: "11:00:00", with: "11:00:01").replacingOccurrences(of: "未读", with: "已读")
        try write(first + next)
        XCTAssertNotEqual(before.customerRevision, try capture().customerRevision)
    }
    func testSameSecondSameContentAcrossExporterBatchesIgnoresReadStatusChange() throws {
        try write(first)
        let completed = try capture()
        let newer = first + first.replacingOccurrences(of: "capture1", with: "capture2")
            .replacingOccurrences(of: "未读", with: "已读")
        try write(newer)

        let observed = try capture()

        XCTAssertEqual(observed.customerRevision, completed.customerRevision)
    }
    func testSameSecondSameContentReadToUnreadIsANewCustomerEvent() throws {
        let read = first.replacingOccurrences(of: "未读", with: "已读")
        try write(read)
        let before = try capture()
        let repeatedUnread = first.replacingOccurrences(of: "capture1", with: "capture2")
        try write(read + repeatedUnread)

        let after = try capture()

        XCTAssertNotEqual(after.customerRevision, before.customerRevision)
        XCTAssertEqual(try CapturedHistory(root: root).currentCursor(uid: "tb12345").count, 2)
    }
    func testReadStatusChangeOnSameStoredEventIdentityDoesNotRegenerate() throws {
        try write(first)
        let completed = try capture()
        try write(first.replacingOccurrences(of: "未读", with: "已读"))
        let observed = try capture(queued: false)
        XCTAssertEqual(observed.customerRevision, completed.customerRevision)
        XCTAssertFalse(observed.shouldGenerate)
    }
    func testUnresolvableCommittedPointerFailsVisiblyAndIsNotDeleted() throws {
        try write(first)
        let pointer = try pointer(history: "missing history\n")
        XCTAssertThrowsError(try capture(queued: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.path))
    }
    func testMissingCurrentSpeakerCannotAuthorizeReplyFromOldHistoryAlone() throws {
        try write(first)
        let pending = try pointer(history: first)
        XCTAssertThrowsError(try capture(nil, queued: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }
    func testCompletionDefersWhileExporterOwnsLockAndRetriesLater() throws {
        try write(first)
        let revision = try capture().customerRevision
        let pending = try pointer(history: first)
        let fd = root.appendingPathComponent(".export.lock").path.withCString { Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertNoThrow(try CapturedHistory(root: root).complete(uid: "tb12345", revision: revision))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        _ = flock(fd, LOCK_UN)
        try CapturedHistory(root: root).complete(uid: "tb12345", revision: revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
}
