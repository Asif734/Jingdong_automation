import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class VideoTransferFaultInjectionTests: XCTestCase {
    func testSystemTimeoutFallsThroughToAlternateSuccessWithoutFallback() async throws {
        let scenario = try VideoTransferFaultScenario(
            system: [.failure(.connectTimeout)],
            alternate: [.success(.validVideo)]
        )
        defer { scenario.remove() }

        await scenario.submit(messageID: "video-1")

        let events = await scenario.events.snapshot()
        XCTAssertEqual(events.downloadedHashes.count, 1)
        XCTAssertEqual(events.fallbackHashes.count, 0)
    }

    func testImmediateTotalFailureSchedulesRecoveryAndOneFallback() async throws {
        let scenario = try VideoTransferFaultScenario(
            system: [.failure(.connectTimeout)],
            alternate: [.failure(.connectionReset)]
        )
        defer { scenario.remove() }

        await scenario.submit(messageID: "video-1")
        await scenario.submit(messageID: "video-1")

        let events = await scenario.events.snapshot()
        let key = scenario.key(messageID: "video-1")
        let record = try await scenario.store.record(key)
        XCTAssertEqual(events.fallbackHashes, [key.messageHash])
        XCTAssertEqual(record?.phase, .waitingForRetry)
        XCTAssertEqual(record?.scheduledRetryIndex, 1)
    }

    func testDelayedRetryWithFreshAddressCanLaterSucceed() async throws {
        let clock = VideoTransferManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let scenario = try VideoTransferFaultScenario(
            clock: clock,
            system: [.failure(.connectTimeout), .success(.validVideo)],
            alternate: [.failure(.connectionReset)]
        )
        defer { scenario.remove() }
        await scenario.submit(messageID: "video-1")
        clock.advance(by: 61)

        await scenario.coordinator.resume()
        let key = scenario.key(messageID: "video-1")
        try await scenario.store.releaseLease(key)
        await scenario.submit(messageID: "video-1")

        let events = await scenario.events.snapshot()
        let finalRecord = try await scenario.store.record(key)
        XCTAssertEqual(events.freshAddressHashes, [key.messageHash])
        XCTAssertEqual(events.downloadedHashes, [key.messageHash])
        XCTAssertEqual(finalRecord?.phase, .downloaded)
    }

    func testRelaunchRecoversWaitingRecordWithoutRawAddress() async throws {
        let clock = VideoTransferManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let scenario = try VideoTransferFaultScenario(
            clock: clock,
            system: [.failure(.connectTimeout)],
            alternate: [.failure(.connectionReset)]
        )
        defer { scenario.remove() }
        await scenario.submit(messageID: "video-1")
        clock.advance(by: 61)
        let relaunchedEvents = VideoTransferFaultEvents()
        let relaunched = await scenario.makeCoordinator(events: relaunchedEvents)

        await relaunched.resume()

        let events = await relaunchedEvents.snapshot()
        XCTAssertEqual(events.fallbackHashes.count, 1)
        XCTAssertEqual(events.freshAddressHashes.count, 1)
        let stateText = try String(contentsOf: scenario.stateURL, encoding: .utf8)
        XCTAssertFalse(stateText.contains("auth_key"))
        XCTAssertFalse(stateText.contains("cloudvideocdn"))
    }

    func testCorruptMP4BecomesTerminalAndDoesNotLoop() async throws {
        let scenario = try VideoTransferFaultScenario(
            system: [.success(.corruptVideo)],
            alternate: []
        )
        defer { scenario.remove() }

        await scenario.submit(messageID: "video-1")
        await scenario.coordinator.resume()

        let key = scenario.key(messageID: "video-1")
        let record = try await scenario.store.record(key)
        let events = await scenario.events.snapshot()
        XCTAssertEqual(record?.phase, .terminalFailure)
        XCTAssertEqual(record?.failure, .invalidVideo)
        XCTAssertEqual(events.fallbackHashes, [key.messageHash])
        XCTAssertTrue(events.freshAddressHashes.isEmpty)
    }

    func testTwoVideosCompleteIndependently() async throws {
        let scenario = try VideoTransferFaultScenario(
            system: [.success(.validVideo), .success(.validVideo)],
            alternate: []
        )
        defer { scenario.remove() }

        async let first: Void = scenario.submit(messageID: "video-1")
        async let second: Void = scenario.submit(messageID: "video-2")
        _ = await (first, second)

        let events = await scenario.events.snapshot()
        XCTAssertEqual(Set(events.downloadedHashes), Set([
            scenario.key(messageID: "video-1").messageHash,
            scenario.key(messageID: "video-2").messageHash
        ]))
        XCTAssertTrue(events.fallbackHashes.isEmpty)
    }
}

private enum FaultFixtureData: Sendable {
    case validVideo
    case corruptVideo

    var data: Data {
        switch self {
        case .validVideo: return Data("valid-mp4-fixture".utf8)
        case .corruptVideo: return Data("corrupt".utf8)
        }
    }
}

private enum FaultDownloadStep: Sendable {
    case success(FaultFixtureData)
    case failure(VideoTransferFailureCategory)
}

private final class VideoTransferManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private actor FaultSystemDownloader: VideoDownloadAttempting {
    private var steps: [FaultDownloadStep]
    init(_ steps: [FaultDownloadStep]) { self.steps = steps }

    func download(_ source: URL, to destination: URL) async throws -> VideoDownloadAttemptResult {
        guard !steps.isEmpty else {
            throw VideoTransferAttemptError(
                category: .connectTimeout,
                isRetryable: true,
                sanitizedDescription: "script exhausted"
            )
        }
        switch steps.removeFirst() {
        case .success(let fixture):
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fixture.data.write(to: destination, options: .atomic)
            return VideoDownloadAttemptResult(
                statusCode: 200, elapsedMilliseconds: 1, bytes: Int64(fixture.data.count)
            )
        case .failure(let category):
            throw VideoTransferAttemptError(
                category: category,
                isRetryable: true,
                sanitizedDescription: "scripted system failure"
            )
        }
    }
}

private struct FaultRouteProvider: AlternateVideoRouteProviding {
    func candidates(for approvedHost: String) async throws -> [AlternateVideoRoute] {
        [AlternateVideoRoute(address: "1.1.1.1", poolID: "fixture", family: .ipv4)]
    }
}

private actor FaultAlternateDownloader: AlternateRouteDownloading {
    private var steps: [FaultDownloadStep]
    init(_ steps: [FaultDownloadStep]) { self.steps = steps }

    func downloadFirstValid(
        source: URL,
        candidates: [AlternateVideoRoute],
        destination: URL
    ) async throws -> AlternateRouteReceipt {
        guard !steps.isEmpty else {
            throw VideoTransferAttemptError(
                category: .connectionReset,
                isRetryable: true,
                sanitizedDescription: "alternate script exhausted"
            )
        }
        switch steps.removeFirst() {
        case .success(let fixture):
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fixture.data.write(to: destination, options: .atomic)
            return AlternateRouteReceipt(
                route: candidates[0],
                result: VideoDownloadAttemptResult(
                    statusCode: 200, elapsedMilliseconds: 1, bytes: Int64(fixture.data.count)
                ),
                fileURL: destination
            )
        case .failure(let category):
            throw VideoTransferAttemptError(
                category: category,
                isRetryable: true,
                sanitizedDescription: "scripted alternate failure"
            )
        }
    }
}

private actor VideoTransferFaultEvents {
    struct Snapshot {
        let downloadedHashes: [String]
        let fallbackHashes: [String]
        let freshAddressHashes: [String]
    }
    private var downloadedHashes: [String] = []
    private var fallbackHashes: [String] = []
    private var freshAddressHashes: [String] = []

    func receive(_ event: VideoTransferEvent) {
        switch event {
        case .downloaded(let receipt): downloadedHashes.append(receipt.messageHash)
        case .immediateRoutesExhausted(let notice): fallbackHashes.append(notice.messageHash)
        case .freshAddressNeeded(let request): freshAddressHashes.append(request.messageHash)
        case .stateChanged: break
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            downloadedHashes: downloadedHashes,
            fallbackHashes: fallbackHashes,
            freshAddressHashes: freshAddressHashes
        )
    }
}

private final class VideoTransferFaultScenario: @unchecked Sendable {
    let root: URL
    let stateURL: URL
    let store: DurableVideoTransferStore
    let coordinator: VideoTransferCoordinator
    let events: VideoTransferFaultEvents
    private let clock: VideoTransferManualClock
    private let system: FaultSystemDownloader
    private let alternate: FaultAlternateDownloader
    private let customerUID = "buyer-123"
    private let observerLock = NSLock()
    private var observerInstalled = false

    init(
        clock: VideoTransferManualClock = VideoTransferManualClock(Date(timeIntervalSince1970: 1_800_000_000)),
        system: [FaultDownloadStep],
        alternate: [FaultDownloadStep]
    ) throws {
        self.clock = clock
        self.system = FaultSystemDownloader(system)
        self.alternate = FaultAlternateDownloader(alternate)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DurableVideoTransferStore(url: stateURL, now: { clock.now() })
        events = VideoTransferFaultEvents()
        coordinator = VideoTransferCoordinator(
            store: store,
            systemDownloader: self.system,
            routeProvider: FaultRouteProvider(),
            alternateDownloader: self.alternate,
            inspect: Self.inspector,
            outputDirectory: root.appendingPathComponent("downloads"),
            now: { clock.now() },
            jitter: { _ in 0 },
            sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }
        )
    }

    func makeCoordinator(events: VideoTransferFaultEvents) async -> VideoTransferCoordinator {
        let value = VideoTransferCoordinator(
            store: store,
            systemDownloader: system,
            routeProvider: FaultRouteProvider(),
            alternateDownloader: alternate,
            inspect: Self.inspector,
            outputDirectory: root.appendingPathComponent("downloads"),
            now: { [clock] in clock.now() },
            jitter: { _ in 0 },
            sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }
        )
        await value.observe { [events] event in await events.receive(event) }
        return value
    }

    func key(messageID: String) -> VideoTransferKey {
        VideoTransferIdentity.key(customerUID: customerUID, messageID: messageID)
    }

    func submit(messageID: String) async {
        await ensureObserver()
        await coordinator.submitCapturedAddress(
            key: key(messageID: messageID),
            source: URL(string: "https://msg2.cloudvideocdn.taobao.com/video.mp4?auth_key=SECRET")!,
            customerUID: customerUID
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func ensureObserver() async {
        let shouldInstall = observerLock.withLock { () -> Bool in
            guard !observerInstalled else { return false }
            observerInstalled = true
            return true
        }
        if shouldInstall {
            await coordinator.observe { [events] event in await events.receive(event) }
        }
    }

    private static let inspector: @Sendable (URL) async throws -> VideoTransferInspection = { url in
        let data = try Data(contentsOf: url)
        guard data.starts(with: Data("valid-mp4".utf8)) else {
            throw VideoTransferAttemptError(
                category: .invalidVideo,
                isRetryable: false,
                sanitizedDescription: "fixture is not a valid MP4"
            )
        }
        return VideoTransferInspection(
            bytes: Int64(data.count), sha256: "fixture-sha", durationSeconds: 1,
            width: 10, height: 10, videoCodec: "H.264", audioCodec: nil
        )
    }
}
