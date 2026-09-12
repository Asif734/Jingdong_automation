import Foundation
import XCTest
@testable import QianniuSenderCore

final class QianniuSendTransactionTests: XCTestCase {
    func testSenderPreservesVideoURLExactly() async {
        let text = "安装视频：https://kb.example.com/video/m880.mp4?lang=zh-CN"
        let session = FakeSession(uidChecks: ["test-user", "test-user"], verification: true)

        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "test-user", text: text, attemptMarkerURL: nil
        )

        XCTAssertEqual(outcome, .sent)
        let events = await session.events()
        XCTAssertTrue(events.contains("input:\(text)"))
        XCTAssertTrue(events.contains("verify:\(text)"))
    }

    func testDelayedConfirmationSucceedsWithoutPressingSendAgain() async {
        let session = FakeSession(uidChecks: ["tb263147182", "tb263147182"], verification: false, delayedVerification: true)
        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: nil
        )
        XCTAssertEqual(outcome, .sent)
        let events = await session.events()
        XCTAssertEqual(events.filter { $0 == "press" }.count, 1)
        XCTAssertEqual(events.last, "recheck:hello")
    }

    func testStillUnconfirmedAfterReadOnlyRecheckNeverResends() async {
        let session = FakeSession(uidChecks: ["tb263147182", "tb263147182"], verification: false)
        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: nil
        )
        guard case .uncertainAfterSend = outcome else { return XCTFail("expected uncertainAfterSend") }
        let events = await session.events()
        XCTAssertEqual(events.filter { $0 == "press" }.count, 1)
        XCTAssertEqual(events.last, "recheck:hello")
    }

    func testReadOnlyRecheckErrorRemainsUncertainWithoutResending() async {
        let session = FakeSession(uidChecks: ["tb263147182", "tb263147182"], verification: false, recheckThrows: true)
        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: nil
        )
        guard case .uncertainAfterSend = outcome else { return XCTFail("expected uncertainAfterSend") }
        let events = await session.events()
        XCTAssertEqual(events.filter { $0 == "press" }.count, 1)
        XCTAssertEqual(events.last, "recheck:hello")
    }

    func testSuccessfulSendEnsuresForegroundAtFinalBoundaryAndRechecksUIDBeforeAttemptMarker() async {
        let session = FakeSession(
            uidChecks: ["stoneshishininger", "stoneshishininger", "stoneshishininger"],
            verification: true,
            frontmostBeforeSend: false
        )
        let transaction = QianniuSendTransaction(session: session)
        let marker = temporaryMarker()

        let outcome = await transaction.send(uid: "stoneshishininger", text: "测试-123", attemptMarkerURL: marker)

        XCTAssertEqual(outcome, .sent)
        let events = await session.events()
        XCTAssertEqual(events, [
            "activate", "search:stoneshishininger", "open:stoneshishininger",
            "identity", "input:测试-123", "identity", "input-check", "frontmost", "activate",
            "identity", "input-check",
            "marker", "press", "verify:测试-123"
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUIDChangeWhileRestoringForegroundFailsBeforeAttemptMarkerOrSend() async {
        let session = FakeSession(
            uidChecks: ["tb263147182", "tb263147182", "other-user"],
            verification: true,
            frontmostBeforeSend: false
        )
        let marker = temporaryMarker()

        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: marker
        )

        guard case .failedBeforeSend = outcome else { return XCTFail("expected failedBeforeSend") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let didPress = await session.didPress()
        XCTAssertFalse(didPress)
    }

    func testAlreadyFrontmostDoesNotActivateAgainAtFinalSendBoundary() async {
        let session = FakeSession(
            uidChecks: ["tb263147182", "tb263147182"],
            verification: true,
            frontmostBeforeSend: true
        )

        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: nil
        )

        XCTAssertEqual(outcome, .sent)
        let events = await session.events()
        XCTAssertEqual(events.filter { $0 == "activate" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "frontmost" }.count, 1)
    }

    func testUIDMismatchBeforeTypingFailsWithoutAttemptMarker() async {
        let session = FakeSession(uidChecks: ["wrong-user"], verification: true)
        let transaction = QianniuSendTransaction(session: session)
        let marker = temporaryMarker()

        let outcome = await transaction.send(uid: "tb263147182", text: "hello", attemptMarkerURL: marker)

        guard case .failedBeforeSend = outcome else { return XCTFail("expected failedBeforeSend") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let didPress = await session.didPress()
        XCTAssertFalse(didPress)
    }

    func testUIDChangeAfterTypingFailsBeforePress() async {
        let session = FakeSession(uidChecks: ["tb263147182", "other-user"], verification: true)
        let transaction = QianniuSendTransaction(session: session)
        let marker = temporaryMarker()

        let outcome = await transaction.send(uid: "tb263147182", text: "hello", attemptMarkerURL: marker)

        guard case .failedBeforeSend = outcome else { return XCTFail("expected failedBeforeSend") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let didPress = await session.didPress()
        XCTAssertFalse(didPress)
    }

    func testFailureAfterPressIsUncertain() async {
        let session = FakeSession(uidChecks: ["tb263147182", "tb263147182"], verification: false)
        let transaction = QianniuSendTransaction(session: session)
        let marker = temporaryMarker()

        let outcome = await transaction.send(uid: "tb263147182", text: "hello", attemptMarkerURL: marker)

        guard case .uncertainAfterSend = outcome else { return XCTFail("expected uncertainAfterSend") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let didPress = await session.didPress()
        XCTAssertTrue(didPress)
    }

    func testAttemptMarkerContainsHashAndInvocationCommitButNotReplyText() async throws {
        let marker = temporaryMarker()
        let session = FakeSession(uidChecks: ["tb263147182", "tb263147182"], verification: true)

        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "tb263147182", text: "private reply body", attemptMarkerURL: marker
        )

        XCTAssertEqual(outcome, .sent)
        let data = try Data(contentsOf: marker)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(raw.contains("private reply body"))
        XCTAssertEqual(object["uid"] as? String, "tb263147182")
        XCTAssertEqual(object["send_was_invoked"] as? Bool, true)
        XCTAssertEqual((object["text_sha256"] as? String)?.count, 64)
        XCTAssertNotNil(object["task_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(object["operation_id"] as? String)))
    }

    func testPressDeadlineIsUncertainAndPressIsNeverRetried() async {
        let session = FakeSession(
            uidChecks: ["tb263147182", "tb263147182"],
            verification: true,
            pressDelay: .seconds(10)
        )
        let transaction = QianniuSendTransaction(
            session: session,
            deadlines: SendTransactionDeadlines(press: .milliseconds(30), verification: .seconds(1))
        )

        let outcome = await transaction.send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: temporaryMarker()
        )

        guard case .uncertainAfterSend(let reason) = outcome else {
            return XCTFail("expected uncertainAfterSend")
        }
        XCTAssertTrue(reason.contains("超时"))
        let pressCount = await session.pressCount()
        XCTAssertEqual(pressCount, 1)
    }

    func testVerificationDeadlineIsUncertainAndNeverPressesAgain() async {
        let session = FakeSession(
            uidChecks: ["tb263147182", "tb263147182"],
            verification: true,
            verificationDelay: .seconds(10)
        )
        let transaction = QianniuSendTransaction(
            session: session,
            deadlines: SendTransactionDeadlines(press: .seconds(1), verification: .milliseconds(30))
        )

        let outcome = await transaction.send(
            uid: "tb263147182", text: "hello", attemptMarkerURL: temporaryMarker()
        )

        guard case .uncertainAfterSend(let reason) = outcome else {
            return XCTFail("expected uncertainAfterSend")
        }
        XCTAssertTrue(reason.contains("发送后确认超时"))
        let pressCount = await session.pressCount()
        XCTAssertEqual(pressCount, 1)
    }

    func testUnknownEvidenceRechecksThreeTimesThenSendsOnce() async {
        let unknown = SendEvidenceAssessment.unknown("AX 暂时不可读")
        let session = FakeSession(
            uidChecks: [],
            verification: true,
            identityAssessments: [unknown, unknown, unknown, unknown, unknown],
            inputAssessments: [unknown, unknown, unknown, unknown]
        )

        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "customer", text: "reply", attemptMarkerURL: temporaryMarker()
        )

        XCTAssertEqual(outcome, .sent)
        let pressCount = await session.pressCount()
        let unknownWaitCount = await session.unknownWaitCount()
        XCTAssertEqual(pressCount, 1)
        XCTAssertEqual(unknownWaitCount, 3)
    }

    func testConfirmedWrongNeverWritesMarkerOrPressesSend() async {
        let marker = temporaryMarker()
        let session = FakeSession(
            uidChecks: [],
            verification: true,
            identityAssessments: [.confirmedWrong("另一个客户")]
        )

        let outcome = await QianniuSendTransaction(session: session).send(
            uid: "customer", text: "reply", attemptMarkerURL: marker
        )

        guard case .failedBeforeSend = outcome else { return XCTFail("expected failedBeforeSend") }
        let pressCount = await session.pressCount()
        XCTAssertEqual(pressCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private func temporaryMarker() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("attempt.json")
    }
}

private actor FakeSession: QianniuSendingSession {
    private var uidChecks: [String]
    private let verification: Bool
    private let delayedVerification: Bool
    private let recheckThrows: Bool
    private let frontmostBeforeSend: Bool
    private let pressDelay: Duration?
    private let verificationDelay: Duration?
    private var recorded: [String] = []
    private var pressed = false
    private var identityAssessments: [SendEvidenceAssessment]
    private var inputAssessments: [SendEvidenceAssessment]
    private var unknownWaits = 0

    init(
        uidChecks: [String],
        verification: Bool,
        delayedVerification: Bool = false,
        recheckThrows: Bool = false,
        frontmostBeforeSend: Bool = true,
        pressDelay: Duration? = nil,
        verificationDelay: Duration? = nil,
        identityAssessments: [SendEvidenceAssessment] = [],
        inputAssessments: [SendEvidenceAssessment] = []
    ) {
        self.uidChecks = uidChecks
        self.verification = verification
        self.delayedVerification = delayedVerification
        self.recheckThrows = recheckThrows
        self.frontmostBeforeSend = frontmostBeforeSend
        self.pressDelay = pressDelay
        self.verificationDelay = verificationDelay
        self.identityAssessments = identityAssessments
        self.inputAssessments = inputAssessments
    }

    func activate() async throws { recorded.append("activate") }
    func isFrontmost() async throws -> Bool {
        recorded.append("frontmost")
        return frontmostBeforeSend
    }
    func searchAndOpen(uid: String) async throws {
        recorded.append("search:\(uid)")
        recorded.append("open:\(uid)")
    }
    func currentChatAssessment(expectedUID: String) async throws -> SendEvidenceAssessment {
        recorded.append("identity")
        if !identityAssessments.isEmpty { return identityAssessments.removeFirst() }
        let actual = uidChecks.removeFirst()
        return actual == expectedUID ? .confirmedCorrect : .confirmedWrong("UID mismatch")
    }
    func setMessageInput(_ text: String) async throws { recorded.append("input:\(text)") }
    func messageInputAssessment(expectedText: String) async throws -> SendEvidenceAssessment {
        recorded.append("input-check")
        return inputAssessments.isEmpty ? .confirmedCorrect : inputAssessments.removeFirst()
    }
    func waitBeforeUnknownRecheck() async { unknownWaits += 1; recorded.append("unknown-wait") }
    func recordMarkerWasWritten() async { recorded.append("marker") }
    func pressSend() async throws {
        pressed = true
        recorded.append("press")
        if let pressDelay { try await Task.sleep(for: pressDelay) }
    }
    func verifySent(text: String) async throws -> Bool {
        recorded.append("verify:\(text)")
        if let verificationDelay { try await Task.sleep(for: verificationDelay) }
        return verification
    }
    func events() -> [String] { recorded }
    func recheckSent(text: String) async throws -> Bool {
        recorded.append("recheck:\(text)")
        if recheckThrows { throw CocoaError(.fileReadUnknown) }
        return delayedVerification
    }
    func didPress() -> Bool { pressed }
    func pressCount() -> Int { recorded.filter { $0 == "press" }.count }
    func unknownWaitCount() -> Int { unknownWaits }
}
