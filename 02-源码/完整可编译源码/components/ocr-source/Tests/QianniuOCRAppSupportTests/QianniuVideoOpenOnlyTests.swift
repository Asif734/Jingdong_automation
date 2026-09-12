import CoreGraphics
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class QianniuVideoOpenOnlyTests: XCTestCase {
    func testDownloadingVideoDoesNotReopenOrClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DurableVideoTransferStore(url: directory.appendingPathComponent("state.json"))
        let key = VideoTransferIdentity.key(customerUID: "buyer-a", messageID: "VIDEO.IN-FLIGHT")
        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")
        try await store.transition(key, to: .downloading)
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            transferState: store,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.IN-FLIGHT",
            customerUID: "buyer-a",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .inFlight)
        XCTAssertTrue(environment.clickedPoints.isEmpty)
    }

    func testDueDurableRetryCanReopenDespiteLegacyOpenedMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DurableVideoTransferStore(
            url: directory.appendingPathComponent("state.json"),
            now: { now }
        )
        let key = VideoTransferIdentity.key(customerUID: "buyer-a", messageID: "VIDEO.RETRY")
        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")
        try await store.scheduleRetry(
            key,
            failure: .connectTimeout,
            nextAttemptAt: now.addingTimeInterval(-1),
            needsFreshAddress: true
        )
        let attempts = InMemoryVideoAttemptStore()
        try await attempts.mark(.opened, for: "VIDEO.RETRY")
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: attempts,
            transferState: store,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        _ = await opener.open(
            messageID: "VIDEO.RETRY",
            customerUID: "buyer-a",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(environment.clickedPoints.count, 1)
    }

    func testTargetSelectionUsesBottomMostCustomerMediaAndTracksPanelMovement() throws {
        let selected = try XCTUnwrap(VideoTargetSelection.target(
            boxes: [
                CGRect(x: 40, y: 80, width: 180, height: 110),
                CGRect(x: 420, y: 410, width: 160, height: 100),
                CGRect(x: 50, y: 330, width: 200, height: 130),
            ],
            imageSize: CGSize(width: 600, height: 700),
            panelFrame: CGRect(x: 100, y: 200, width: 600, height: 700)
        ))

        XCTAssertEqual(selected.sourceBox, CGRect(x: 50, y: 330, width: 200, height: 130))
        XCTAssertEqual(selected.screenRect, CGRect(x: 150, y: 530, width: 200, height: 130))
    }

    func testTargetSelectionRejectsFullHeightLeftEdgeArtifactsWhenRealMediaExists() throws {
        let selected = try XCTUnwrap(VideoTargetSelection.target(
            boxes: [
                CGRect(x: 0, y: 120, width: 731, height: 357),
                CGRect(x: 0, y: 493, width: 737, height: 271),
                CGRect(x: 0, y: 276, width: 270, height: 492),
                CGRect(x: 287, y: 214, width: 270, height: 215),
            ],
            imageSize: CGSize(width: 1166, height: 768),
            panelFrame: CGRect(x: 0, y: 0, width: 1166, height: 768)
        ))

        XCTAssertEqual(selected.sourceBox, CGRect(x: 287, y: 214, width: 270, height: 215))
    }

    func testPanelWidePlayButtonCanBeClickedOutsideFragmentedVideoCandidate() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, _, _ in CGPoint(x: 260, y: 430) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.PANEL-WIDE-PLAY-BUTTON",
            boxes: [CGRect(x: 250, y: 20, width: 130, height: 168)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(environment.clickedPoints, [CGPoint(x: 260, y: 430)])
    }

    func testOpenerClicksOnceAndRequiresNewQianniuPlayerWindow() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true)
        let attempts = InMemoryVideoAttemptStore()
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: attempts,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.105",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(environment.clickedPoints.count, 1)
        XCTAssertEqual(environment.movedPoints.count, 1)
        let openedStatus = try await attempts.status(for: "VIDEO.105")
        XCTAssertEqual(openedStatus, .opened)
    }

    func testTransientPlayTriangleDisappearanceDoesNotCountAsOpenedPlayer() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: false)
        let attempts = InMemoryVideoAttemptStore()
        var locatorCalls = 0
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: attempts,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 2,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in
                locatorCalls += 1
                return locatorCalls == 1 ? CGPoint(x: target.midX, y: target.midY) : nil
            }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.INLINE",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        guard case .uncertainAfterClick = outcome else {
            return XCTFail("a disappearing triangle is not proof that the player window opened")
        }
        XCTAssertEqual(environment.clickedPoints.count, 6)
        let storedStatus = try await attempts.status(for: "VIDEO.INLINE")
        XCTAssertEqual(storedStatus, .attempted)
    }

    func testOneMissingPlayTriangleFrameDoesNotCreateAFalseInlineOpen() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: false)
        var locatorCalls = 0
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 2,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in
                locatorCalls += 1
                return locatorCalls == 2 ? nil : CGPoint(x: target.midX, y: target.midY)
            }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.TRANSIENT",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        guard case .uncertainAfterClick = outcome else {
            return XCTFail("one transient missing frame is not proof that inline playback started")
        }
        XCTAssertEqual(environment.clickedPoints.count, 6)
    }

    func testOpenerArmsTransferBeforeClickAndStartsItExactlyOnceAfterClick() async throws {
        let events = OrderedVideoEvents()
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true, events: events)
        let transfer = RecordingArmedVideoTransfer(events: events)
        let transfers = RecordingVideoTransferArmer(transfer: transfer, events: events)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            videoTransfers: transfers,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) },
            onProgress: { events.values.append("phase:\($0.rawValue)") }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.DOWNLOAD",
            customerUID: "buyer-a",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(
            events.values,
            [
                "phase:opening",
                "arm:VIDEO.DOWNLOAD:buyer-a",
                "start",
                "click",
                "phase:download-requested",
                "phase:closing-player",
                "dismiss",
                "phase:resumed-scanning",
            ]
        )
        XCTAssertEqual(transfers.armCount, 1)
        XCTAssertEqual(transfer.startCount, 1)
    }

    func testPlayerStaysOpenUntilDurableDownloadActuallyStarts() async throws {
        let events = OrderedVideoEvents()
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true, events: events)
        let transfer = RecordingArmedVideoTransfer(events: events)
        let transfers = RecordingVideoTransferArmer(transfer: transfer, events: events)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DurableVideoTransferStore(url: directory.appendingPathComponent("state.json"))
        let key = VideoTransferIdentity.key(
            customerUID: "buyer-a",
            messageID: "VIDEO.CLOSE-AFTER-DOWNLOAD-START"
        )
        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")
        var polls = 0
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            videoTransfers: transfers,
            transferState: store,
            hoverDelay: {},
            pollDelay: {
                polls += 1
                if polls == 2 {
                    events.values.append("download-started")
                    try? await store.transition(key, to: .downloading)
                }
            },
            maximumPlayerPolls: 3,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.CLOSE-AFTER-DOWNLOAD-START",
            customerUID: "buyer-a",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(
            events.values,
            [
                "arm:VIDEO.CLOSE-AFTER-DOWNLOAD-START:buyer-a",
                "start",
                "click",
                "download-started",
                "dismiss"
            ]
        )
        XCTAssertEqual(environment.dismissCount, 1)
    }

    func testMissingDownloadStartDoesNotPretendSuccessOrClosePlayerEarly() async throws {
        let events = OrderedVideoEvents()
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true, events: events)
        let transfer = RecordingArmedVideoTransfer(events: events)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DurableVideoTransferStore(url: directory.appendingPathComponent("state.json"))
        let key = VideoTransferIdentity.key(customerUID: "buyer-a", messageID: "VIDEO.NO-DOWNLOAD-START")
        _ = try await store.beginOrRead(key: key, customerUID: "buyer-a")
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            videoTransfers: RecordingVideoTransferArmer(transfer: transfer, events: events),
            transferState: store,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 3,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.NO-DOWNLOAD-START",
            customerUID: "buyer-a",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        guard case .uncertainAfterClick = outcome else {
            return XCTFail("missing download start must not be reported as opened")
        }
        XCTAssertEqual(environment.dismissCount, 0)
        XCTAssertFalse(events.values.contains("dismiss"))
    }

    func testOpenerRelocatesUntilPlayerAppearsWithinSixAttempts() async throws {
        let environment = FakeVideoEnvironment(
            addPlayerAfterClick: true,
            playerAppearsAfterClickCount: 3
        )
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 3,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.THIRD-CLICK",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(environment.clickedPoints.count, 3)
        XCTAssertEqual(environment.movedPoints.count, 3)
    }

    func testFailedBeforeClickDoesNotArmOrStartVideoTransfer() async throws {
        let events = OrderedVideoEvents()
        let transfer = RecordingArmedVideoTransfer(events: events)
        let transfers = RecordingVideoTransferArmer(transfer: transfer, events: events)
        let opener = QianniuVideoOpener(
            environment: FakeVideoEnvironment(addPlayerAfterClick: false, events: events),
            attempts: InMemoryVideoAttemptStore(),
            videoTransfers: transfers,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, _, _ in nil }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.NO-CLICK",
            boxes: [],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        guard case .failedBeforeClick = outcome else { return XCTFail("video must fail before click") }
        XCTAssertEqual(transfers.armCount, 0)
        XCTAssertEqual(transfer.startCount, 0)
    }

    func testMissingPlayTriangleTriesVisibleMediaCenterUpwardUntilPlayerOpens() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true, playerAppearsAfterClickCount: 3)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 6,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, _, _ in nil }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.NO-TRIANGLE",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(environment.clickedPoints.count, 3)
        guard environment.clickedPoints.count == 3 else { return }
        XCTAssertEqual(Set(environment.clickedPoints.map(\.x)).count, 1)
        XCTAssertGreaterThan(environment.clickedPoints[0].y, environment.clickedPoints[1].y)
        XCTAssertGreaterThan(environment.clickedPoints[1].y, environment.clickedPoints[2].y)
    }

    func testMissingPlayTriangleSearchesAbovePartialMediaDetection() async throws {
        let environment = FakeVideoEnvironment(
            addPlayerAfterClick: true,
            playerOpensWhen: { point in point.y < 390 }
        )
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 6,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, _, _ in nil }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.PARTIAL-PORTRAIT",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertTrue(environment.clickedPoints.contains { $0.y < 390 })
    }

    func testFailedDetectedTriangleClickFallsBackToUpwardSweep() async throws {
        let environment = FakeVideoEnvironment(
            addPlayerAfterClick: true,
            playerOpensWhen: { point in point.y < 390 }
        )
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 6,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.TRIANGLE-FIRST-CLICK-MISSED",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(environment.clickedPoints.first?.y, 460)
        XCTAssertTrue(environment.clickedPoints.dropFirst().contains { $0.y < 390 })
    }

    func testRefreshMissKeepsRecentInitialVideoTargetAndClicksFallback() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: true)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 2,
            targetRefresher: { _, _, _ in nil },
            playPointLocator: { _, _, _ in nil }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.REFRESH-MISS",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(environment.clickedPoints.count, 1)
    }

    func testPostClickUncertaintyIsNeverClickedAgain() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: false)
        let attempts = InMemoryVideoAttemptStore()
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: attempts,
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let first = await opener.open(
            messageID: "VIDEO.105",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )
        let second = await opener.open(
            messageID: "VIDEO.105",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        guard case .uncertainAfterClick = first else { return XCTFail("first click must be uncertain") }
        XCTAssertEqual(second, .alreadyAttempted)
        XCTAssertEqual(environment.clickedPoints.count, 6)
        let attemptedStatus = try await attempts.status(for: "VIDEO.105")
        XCTAssertEqual(attemptedStatus, .attempted)
    }

    func testExistingPlayerDoesNotCountAsSuccessfulNewOpen() async throws {
        let environment = FakeVideoEnvironment(addPlayerAfterClick: false, includeExistingPlayer: true)
        let opener = QianniuVideoOpener(
            environment: environment,
            attempts: InMemoryVideoAttemptStore(),
            hoverDelay: {},
            pollDelay: {},
            maximumPlayerPolls: 1,
            targetRefresher: { _, target, _ in target },
            playPointLocator: { _, target, _ in CGPoint(x: target.midX, y: target.midY) }
        )

        let outcome = await opener.open(
            messageID: "VIDEO.OTHER",
            boxes: [CGRect(x: 30, y: 300, width: 200, height: 120)],
            panel: panel,
            imageSize: CGSize(width: 600, height: 700)
        )

        guard case .uncertainAfterClick = outcome else { return XCTFail("an old player is not proof of this click") }
        XCTAssertEqual(environment.dismissCount, 0)
    }

    func testTriangleLocatorRejectsBrightRectangleThatIsNotAPlayIcon() throws {
        var bytes = [UInt8](repeating: 20, count: 400 * 300 * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        for y in 140...160 {
            for x in 190...210 {
                let offset = (y * 400 + x) * 4
                bytes[offset] = 255
                bytes[offset + 1] = 255
                bytes[offset + 2] = 255
            }
        }
        let image = try makeImage(width: 400, height: 300, bytes: &bytes)

        XCTAssertNil(VideoPlayTriangleLocator.point(
            image: image,
            target: CGRect(x: 50, y: 50, width: 300, height: 200),
            panelFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        ))
    }

    func testTriangleLocatorFindsCenteredPlayTriangle() throws {
        var bytes = [UInt8](repeating: 20, count: 400 * 300 * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        for dy in -12...12 {
            let width = 12 - abs(dy)
            for x in (205 - width)...205 {
                let y = 150 + dy
                let offset = (y * 400 + x) * 4
                bytes[offset] = 255
                bytes[offset + 1] = 255
                bytes[offset + 2] = 255
            }
        }
        let image = try makeImage(width: 400, height: 300, bytes: &bytes)

        let point = try XCTUnwrap(VideoPlayTriangleLocator.point(
            image: image,
            target: CGRect(x: 50, y: 50, width: 300, height: 200),
            panelFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        ))
        XCTAssertEqual(point.x, 199, accuracy: 2)
        XCTAssertEqual(point.y, 150, accuracy: 2)
    }

    func testPlayButtonCascadeUsesOpenCVPointBeforeLegacyFallback() {
        var fallbackCalls = 0
        let point = PlayButtonLocatorCascade.point(
            openCV: { CGPoint(x: 123, y: 456) },
            legacy: {
                fallbackCalls += 1
                return CGPoint(x: 9, y: 9)
            }
        )

        XCTAssertEqual(point, CGPoint(x: 123, y: 456))
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testPlayButtonCascadeFallsBackWhenOpenCVCannotConfirm() {
        let point = PlayButtonLocatorCascade.point(
            openCV: { nil },
            legacy: { CGPoint(x: 19, y: 29) }
        )

        XCTAssertEqual(point, CGPoint(x: 19, y: 29))
    }

    func testPersistentAttemptStorePreventsClickAfterRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("video-attempts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = PersistentVideoAttemptStore(url: url)
        try await first.mark(.attempted, for: "VIDEO.RELAUNCH")

        let relaunched = PersistentVideoAttemptStore(url: url)

        let status = try await relaunched.status(for: "VIDEO.RELAUNCH")
        XCTAssertEqual(status, .attempted)

        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(persisted.contains("VIDEO.RELAUNCH"))
    }

    func testPersistentAttemptStoreMigratesLegacyRawMessageIDWithoutReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("video-attempts.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"schemaVersion":1,"values":{"LEGACY.VIDEO.ID":"opened"}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let store = PersistentVideoAttemptStore(url: url)
        let status = try await store.status(for: "LEGACY.VIDEO.ID")
        XCTAssertEqual(status, .opened)

        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(persisted.contains("LEGACY.VIDEO.ID"))
    }

    private var panel: LocatedPanel {
        LocatedPanel(
            ownerPID: 42,
            windowTitle: "接待中心",
            windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            panelFrame: CGRect(x: 100, y: 100, width: 600, height: 700)
        )
    }
}

@MainActor
private final class FakeVideoEnvironment: VideoOpenEnvironment {
    private let addPlayerAfterClick: Bool
    private let playerAppearsAfterClickCount: Int
    private let includeExistingPlayer: Bool
    private let playerOpensWhen: ((CGPoint) -> Bool)?
    var movedPoints: [CGPoint] = []
    var clickedPoints: [CGPoint] = []
    var dismissCount = 0
    private let events: OrderedVideoEvents?

    init(
        addPlayerAfterClick: Bool,
        playerAppearsAfterClickCount: Int = 1,
        includeExistingPlayer: Bool = false,
        playerOpensWhen: ((CGPoint) -> Bool)? = nil,
        events: OrderedVideoEvents? = nil
    ) {
        self.addPlayerAfterClick = addPlayerAfterClick
        self.playerAppearsAfterClickCount = max(1, playerAppearsAfterClickCount)
        self.includeExistingPlayer = includeExistingPlayer
        self.playerOpensWhen = playerOpensWhen
        self.events = events
    }

    func activateOwner(panel: LocatedPanel) async -> Bool { true }
    func capture(panel: LocatedPanel) async throws -> CGImage { try makeBlankImage(width: 600, height: 700) }
    func move(to point: CGPoint) async { movedPoints.append(point) }
    func click(at point: CGPoint) async {
        clickedPoints.append(point)
        events?.values.append("click")
    }
    func dismissPlayer(panel: LocatedPanel) async {
        dismissCount += 1
        events?.values.append("dismiss")
    }
    func windows(ownerPID: Int32) async throws -> [VideoWindowDescriptor] {
        var result = [VideoWindowDescriptor(id: 1, title: "接待中心", frame: panelFrame)]
        if includeExistingPlayer {
            result.append(VideoWindowDescriptor(id: 2, title: "视频播放", frame: playerFrame))
        }
        let pointTriggered = playerOpensWhen.map { predicate in clickedPoints.contains(where: predicate) } ?? true
        if addPlayerAfterClick, clickedPoints.count >= playerAppearsAfterClickCount, pointTriggered {
            result.append(VideoWindowDescriptor(id: 3, title: "视频播放", frame: playerFrame))
        }
        return result
    }

    private let panelFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let playerFrame = CGRect(x: 200, y: 150, width: 640, height: 480)
}

@MainActor
private final class OrderedVideoEvents {
    var values: [String] = []
}

@MainActor
private final class RecordingArmedVideoTransfer: ArmedVideoTransfer {
    private let events: OrderedVideoEvents
    private(set) var startCount = 0

    init(events: OrderedVideoEvents) {
        self.events = events
    }

    func start() {
        startCount += 1
        events.values.append("start")
    }

}

@MainActor
private final class RecordingVideoTransferArmer: VideoTransferArming {
    private let transfer: RecordingArmedVideoTransfer
    private let events: OrderedVideoEvents
    private(set) var armCount = 0

    init(transfer: RecordingArmedVideoTransfer, events: OrderedVideoEvents) {
        self.transfer = transfer
        self.events = events
    }

    func arm(messageID: String, customerUID: String) -> (any ArmedVideoTransfer)? {
        armCount += 1
        events.values.append("arm:\(messageID):\(customerUID)")
        return transfer
    }
}

private func makeBlankImage(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try XCTUnwrap(context.makeImage())
}

private func makeImage(width: Int, height: Int, bytes: inout [UInt8]) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try XCTUnwrap(context.makeImage())
}
