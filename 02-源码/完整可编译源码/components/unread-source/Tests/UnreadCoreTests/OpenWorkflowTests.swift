import XCTest
import CoreGraphics
@testable import UnreadCore

@MainActor final class OpenWorkflowTests: XCTestCase {
    // Cross-customer handoff must wait for the new header, not accept the old chat.
    func testCrossCustomerClickWaitsForTargetHeaderBeforeHandoff() async throws {
        let session = FixtureSession()
        session.headersBeforeReady = ["tb263147182", "tb263147182"]
        var handedOff: [String] = []
        let result = try await OpenWorkflow.run(session: session, afterVerified: { uid in
            XCTAssertEqual(session.clicks, 1)
            XCTAssertEqual(session.headerReads, 3)
            handedOff.append(uid)
        })
        XCTAssertEqual(result.verifiedUID, "stoneshishininger")
        XCTAssertEqual(handedOff, ["stoneshishininger"])
    }
    func testFailedHandoffResumesAfterDotClearsAndSurvivesReload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        let session = FixtureSession(); session.clearDotOnClick = true
        do {
            _ = try await OpenWorkflow.run(session: session, pending: PendingHandoff(url: url), afterVerified: { _ in
                throw AssistantError.unsafe("launch failed before press")
            })
            XCTFail("must report launch failure")
        } catch {}
        var received: [String] = []
        let result = try await OpenWorkflow.run(session: session, pending: PendingHandoff(url: url), afterVerified: { received.append($0) })
        XCTAssertEqual(result.verifiedUID, "stoneshishininger")
        XCTAssertEqual(received, ["stoneshishininger"])
        XCTAssertNil(try PendingHandoff(url: url).load())
    }
    func testUncertainPressNeverAutoRetriesAfterReload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        let pending = PendingHandoff(url: url)
        let session = FixtureSession()
        do {
            _ = try await OpenWorkflow.run(session: session, pending: pending, afterVerified: { uid in
                try pending.save(uid: uid, attempted: true)
                throw AssistantError.unsafe("AX result uncertain")
            })
        } catch {}
        let freshSession = FixtureSession()
        do {
            _ = try await OpenWorkflow.run(session: freshSession, pending: PendingHandoff(url: url), afterVerified: { _ in XCTFail("must not duplicate press") })
            XCTFail("uncertain trigger must remain visible")
        } catch {}
        XCTAssertEqual(freshSession.clicks, 0)
        XCTAssertEqual(try pending.load()?.uid, "stoneshishininger")
        try pending.clear()
    }
    func testPendingWrongCustomerDoesNotTriggerAndRemainsPending() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        let pending = PendingHandoff(url: url)
        try pending.save(uid: "stoneshishininger", attempted: false)
        let session = FixtureSession(); session.hasDot = false; session.actualHeader = "wrong-user"
        do {
            _ = try await OpenWorkflow.run(session: session, pending: pending, afterVerified: { _ in XCTFail("wrong user") })
            XCTFail("must stop")
        } catch {}
        XCTAssertEqual(try pending.load()?.uid, "stoneshishininger")
        try pending.clear()
    }
    func testCaptureTimeoutStopsWithoutLateClick() async throws {
        let session = FixtureSession(); session.stallCapture = true
        let began = Date()
        do {
            _ = try await OpenWorkflow.run(session: session, captureTimeout: .milliseconds(30))
            XCTFail("must timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertEqual(session.clicks, 0)
        let second = FixtureSession()
        do {
            _ = try await OpenWorkflow.run(session: second, captureTimeout: .milliseconds(30))
            XCTFail("must not accumulate requests behind a stuck capture")
        } catch {}
        XCTAssertEqual(second.captures, 0)
        session.resumeCapture()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.clicks, 0, "late capture must never continue the workflow")
    }
    func testBusyPhaseOneStopsBeforeChangingConversation() async {
        let session = FixtureSession()
        do {
            _ = try await OpenWorkflow.run(session: session, beforeClick: {
                throw AssistantError.unsafe("一期版正在识别")
            }, afterVerified: { _ in XCTFail("busy must not trigger") })
            XCTFail("busy must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("一期版正在识别")) }
        XCTAssertEqual(session.clicks, 0)
    }
    // Catch a missing, premature, repeated, or wrong-UID handoff at the external UI boundary.
    func testHandoffRunsOnceAfterClickAndHeaderVerification() async throws {
        let session = FixtureSession()
        var received: [String] = []
        let result = try await OpenWorkflow.run(session: session, afterVerified: { uid in
            XCTAssertEqual(session.clicks, 1)
            XCTAssertGreaterThan(session.headerReads, 0)
            received.append(uid)
        })
        XCTAssertEqual(received, ["stoneshishininger"])
        XCTAssertEqual(result.verifiedUID, "stoneshishininger")
    }
    func testNoDotNeverTriggersPhaseOne() async throws {
        let session = FixtureSession(); session.hasDot = false
        _ = try await OpenWorkflow.run(session: session, afterVerified: { _ in XCTFail("no target must not trigger OCR") })
    }
    func testWrongHeaderNeverTriggersPhaseOne() async {
        let session = FixtureSession(); session.actualHeader = "other-user"
        do {
            _ = try await OpenWorkflow.run(session: session, afterVerified: { _ in XCTFail("wrong user must not trigger OCR") })
            XCTFail("must stop")
        } catch {}
    }
    func testHandoffFailurePropagatesWithoutRetryingClickOrTrigger() async {
        let session = FixtureSession()
        var triggers = 0
        do {
            _ = try await OpenWorkflow.run(session: session, afterVerified: { _ in
                triggers += 1
                throw AssistantError.unsafe("一期版正忙")
            })
            XCTFail("failed handoff must not report success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("一期版正忙")) }
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(session.clicks, 1)
    }
    // A real workflow with fake external AX/capture boundaries: no live UI is executed.
    // These catch stale clicks, skipped permission checks, and false success after a mismatched header.
    func testOpensSameFullUIDAfterReorderingAndVerifiesHeader() async throws {
        let session = FixtureSession()
        session.reorderOnActivation = true
        let result = try await OpenWorkflow.run(session: session)
        XCTAssertEqual(result.found, ["stoneshishininger"])
        XCTAssertEqual(result.verifiedUID, "stoneshishininger")
        XCTAssertEqual(session.clicked?.frame.minY, 650)
        XCTAssertEqual(session.clicks, 1)
    }
    func testPermissionFailureNeverCapturesOrClicks() async {
        let session = FixtureSession(); session.denied = true
        do { _ = try await OpenWorkflow.run(session: session); XCTFail("must throw") } catch {}
        XCTAssertEqual(session.captures, 0); XCTAssertEqual(session.clicks, 0)
    }
    func testListChangesDuringCaptureNeverClick() async {
        let session = FixtureSession(); session.moveDuringCapture = true
        do { _ = try await OpenWorkflow.run(session: session); XCTFail("must throw") } catch {}
        XCTAssertEqual(session.clicks, 0)
    }
    func testDisappearingDotAfterActivationNeverClick() async {
        let session = FixtureSession(); session.removeDotOnActivation = true
        do { _ = try await OpenWorkflow.run(session: session); XCTFail("must throw") } catch {}
        XCTAssertEqual(session.clicks, 0)
    }
    func testHeaderMismatchDoesNotReportOpenedOrClickAnotherRow() async {
        let session = FixtureSession(); session.actualHeader = "bob"
        do { _ = try await OpenWorkflow.run(session: session); XCTFail("must throw") } catch {}
        XCTAssertEqual(session.clicks, 1)
    }
    func testNoDotReturnsScopedEmptyResultWithoutActivation() async throws {
        let session = FixtureSession(); session.hasDot = false
        let result = try await OpenWorkflow.run(session: session)
        XCTAssertNil(result.verifiedUID); XCTAssertTrue(result.found.isEmpty)
        XCTAssertFalse(session.activated); XCTAssertEqual(session.clicks, 0)
    }
}

@MainActor private final class FixtureSession: UnreadSession {
    var denied = false, moveDuringCapture = false, reorderOnActivation = false, removeDotOnActivation = false
    var hasDot = true, activated = false
    var clearDotOnClick = false, stallCapture = false
    var captureContinuation: CheckedContinuation<PixelImage, Never>?
    var captures = 0, clicks = 0, headerReads = 0
    var y: CGFloat = 250
    var actualHeader = "stoneshishininger"
    var headersBeforeReady: [String] = []
    var clicked: ConversationRow?
    let window = CGRect(x: 0, y: 0, width: 1287, height: 768)
    func check() throws { if denied { throw AssistantError.unsafe("permission") } }
    func snapshot() throws -> SceneSnapshot {
        SceneSnapshot(windowID: 1, frame: window, rows: [ConversationRow(nodeID: 1, uid: "stoneshishininger", frame: CGRect(x: 64, y: y, width: 202, height: 44))])
    }
    func capture(_ snapshot: SceneSnapshot) async throws -> PixelImage {
        captures += 1
        if stallCapture { return await withCheckedContinuation { captureContinuation = $0 } }
        let image = UnreadCoreTests().synthetic(dots: hasDot ? [(99, Int(y)+10)] : [])
        if moveDuringCapture { y += 44 }
        return image
    }
    func activate() throws {
        activated = true
        if reorderOnActivation { y = 650 }
        if removeDotOnActivation { hasDot = false }
    }
    func resumeCapture() { captureContinuation?.resume(returning: UnreadCoreTests().synthetic(dots: [(99, Int(y)+10)])); captureContinuation = nil }
    func click(_ row: ConversationRow, scene: SceneSnapshot) throws { clicks += 1; clicked = row; if clearDotOnClick { hasDot = false } }
    func header() throws -> String? {
        headerReads += 1
        return headersBeforeReady.isEmpty ? actualHeader : headersBeforeReady.removeFirst()
    }
}
