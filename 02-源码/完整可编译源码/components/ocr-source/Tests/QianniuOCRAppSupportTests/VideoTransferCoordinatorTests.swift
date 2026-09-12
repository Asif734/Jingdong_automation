import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class VideoTransferCoordinatorTests: XCTestCase {
    func testSystemDownloadIsValidatedThroughATemporaryMP4URL() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator(
            system: ScriptedSystemDownloader(result: .success(Data("video".utf8))),
            inspect: { url in
                guard url.pathExtension.lowercased() == "mp4" else {
                    throw VideoTransferAttemptError(
                        category: .invalidVideo,
                        isRetryable: false,
                        sanitizedDescription: "AVFoundation requires an MP4 file extension"
                    )
                }
                return VideoTransferInspection(
                    bytes: Int64((try Data(contentsOf: url)).count),
                    sha256: "fixture-sha",
                    durationSeconds: 1,
                    width: 10,
                    height: 10,
                    videoCodec: "H.264",
                    audioCodec: nil
                )
            }
        )

        await coordinator.submitCapturedAddress(
            key: fixture.key,
            source: fixture.signedURL,
            customerUID: fixture.customerUID
        )

        let storedRecord = try await fixture.store.record(fixture.key)
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.phase, .downloaded)
    }

    func testSystemTimeoutThenAlternateSuccessEmitsOneDownloadedEvent() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator(
            system: ScriptedSystemDownloader(result: .failure(.connectTimeout)),
            alternate: ScriptedAlternateDownloader(result: .success(Data("video".utf8)))
        )
        await coordinator.observe { await events.receive($0) }

        await coordinator.submitCapturedAddress(
            key: fixture.key,
            source: fixture.signedURL,
            customerUID: fixture.customerUID
        )

        let downloaded = await events.downloaded
        XCTAssertEqual(downloaded.count, 1)
        XCTAssertEqual(downloaded.first?.customerUID, fixture.customerUID)
        let stored = try await fixture.store.record(fixture.key)
        XCTAssertEqual(stored?.phase, .downloaded)
    }

    func testSuccessfulTransferPublishesAddressDownloadAndCompletionProgress() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator(
            system: ScriptedSystemDownloader(result: .success(Data("video".utf8)))
        )
        await coordinator.observe { await events.receive($0) }

        await coordinator.submitCapturedAddress(
            key: fixture.key,
            source: fixture.signedURL,
            customerUID: fixture.customerUID
        )

        let phases = await events.statusPhases
        XCTAssertEqual(phases, [.addressCaptured, .downloading, .downloaded])
    }

    func testImmediateExhaustionEmitsOneFallbackAndSchedulesSixtySecondRetry() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator(
            system: ScriptedSystemDownloader(result: .failure(.connectTimeout)),
            alternate: ScriptedAlternateDownloader(result: .failure(.connectionReset))
        )
        await coordinator.observe { await events.receive($0) }

        await coordinator.submitCapturedAddress(
            key: fixture.key,
            source: fixture.signedURL,
            customerUID: fixture.customerUID
        )

        let exhaustedCount = await events.exhaustedCount
        XCTAssertEqual(exhaustedCount, 1)
        let stored = try await fixture.store.record(fixture.key)
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.phase, .waitingForRetry)
        XCTAssertEqual(record.nextAttemptAt, fixture.now.addingTimeInterval(60))
        XCTAssertTrue(record.needsFreshAddress)
    }

    func testDueRetryWithoutInMemoryURLRequestsOneFreshAddressCapture() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try await fixture.seedWaiting(customerUID: fixture.customerUID, fallbackAdmitted: true)
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator()
        await coordinator.observe { await events.receive($0) }

        await coordinator.resume()
        await coordinator.resume()

        let freshAddressUIDs = await events.freshAddressUIDs
        XCTAssertEqual(freshAddressUIDs, [fixture.customerUID])
    }

    func testUnboundLegacyRetryNeverRequestsUIUntilMatchingUIDIsBound() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try await fixture.seedWaiting(customerUID: nil, fallbackAdmitted: true)
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator()
        await coordinator.observe { await events.receive($0) }

        await coordinator.resume()
        let initiallyRequested = await events.freshAddressUIDs
        XCTAssertTrue(initiallyRequested.isEmpty)
        try await fixture.store.bindCustomerUID(fixture.customerUID, to: fixture.key)
        await coordinator.resume()

        let requested = await events.freshAddressUIDs
        XCTAssertEqual(requested, [fixture.customerUID])
    }

    func testRelaunchReemitsUnadmittedFallbackButNotAfterAdmission() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try await fixture.seedWaiting(customerUID: fixture.customerUID, fallbackAdmitted: false)
        let events = VideoTransferEventRecorder()
        let first = fixture.coordinator()
        await first.observe { await events.receive($0) }

        await first.resume()
        await first.resume()
        let firstCount = await events.exhaustedCount
        XCTAssertEqual(firstCount, 1)

        try await fixture.store.markFallbackAdmitted(fixture.key)
        let second = fixture.coordinator()
        await second.observe { await events.receive($0) }
        await second.resume()
        let secondCount = await events.exhaustedCount
        XCTAssertEqual(secondCount, 1)
    }

    func testDownloadedRecordDoesNotEmitDuplicateCompletionAfterRelaunch() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.beginOrRead(key: fixture.key, customerUID: fixture.customerUID)
        try await fixture.store.transition(fixture.key, to: .downloaded)
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator()
        await coordinator.observe { await events.receive($0) }

        await coordinator.resume()

        let downloaded = await events.downloaded
        let freshAddressUIDs = await events.freshAddressUIDs
        XCTAssertTrue(downloaded.isEmpty)
        XCTAssertTrue(freshAddressUIDs.isEmpty)
    }

    func testTerminalFailureReemitsFallbackAfterRelaunchUntilAdmitted() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.beginOrRead(key: fixture.key, customerUID: fixture.customerUID)
        try await fixture.store.transition(
            fixture.key,
            to: .terminalFailure,
            failure: .invalidVideo
        )
        let events = VideoTransferEventRecorder()
        let coordinator = fixture.coordinator()
        await coordinator.observe { await events.receive($0) }

        await coordinator.resume()

        let count = await events.exhaustedCount
        XCTAssertEqual(count, 1)
    }

    func testInFlightStateTransitionDoesNotReleaseExclusiveLease() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        _ = try await fixture.store.beginOrRead(key: fixture.key, customerUID: fixture.customerUID)
        let firstClaim = try await fixture.store.claimLease(fixture.key, duration: 45)
        XCTAssertTrue(firstClaim)

        try await fixture.store.transition(fixture.key, to: .downloading)

        let secondClaim = try await fixture.store.claimLease(fixture.key, duration: 45)
        XCTAssertFalse(secondClaim)
    }
}

private struct CoordinatorFixture {
    let root: URL
    let store: DurableVideoTransferStore
    let customerUID = "buyer-123"
    let messageID = "video-message-456"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let signedURL: URL

    var key: VideoTransferKey {
        VideoTransferIdentity.key(customerUID: customerUID, messageID: messageID)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        signedURL = try XCTUnwrap(URL(
            string: "https://msg2.cloudvideocdn.taobao.com/video.mp4?auth_key=SECRET"
        ))
        let fixedNow = now
        store = DurableVideoTransferStore(
            url: root.appendingPathComponent("state.json"),
            now: { fixedNow }
        )
    }

    func coordinator(
        system: any VideoDownloadAttempting = ScriptedSystemDownloader(result: .failure(.connectTimeout)),
        alternate: any AlternateRouteDownloading = ScriptedAlternateDownloader(result: .failure(.connectionReset)),
        inspect customInspect: VideoTransferCoordinator.Inspect? = nil
    ) -> VideoTransferCoordinator {
        let inspect: VideoTransferCoordinator.Inspect = customInspect ?? { url in
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw VideoTransferAttemptError(
                    category: .invalidVideo,
                    isRetryable: false,
                    sanitizedDescription: "invalid fixture"
                )
            }
            return VideoTransferInspection(
                bytes: Int64(data.count),
                sha256: "fixture-sha",
                durationSeconds: 1,
                width: 10,
                height: 10,
                videoCodec: "H.264",
                audioCodec: nil
            )
        }
        return VideoTransferCoordinator(
            store: store,
            systemDownloader: system,
            routeProvider: FixedRouteProvider(),
            alternateDownloader: alternate,
            inspect: inspect,
            outputDirectory: root.appendingPathComponent("downloads", isDirectory: true),
            now: { now },
            jitter: { _ in 0 }
        )
    }

    func seedWaiting(customerUID: String?, fallbackAdmitted: Bool) async throws {
        if let customerUID {
            _ = try await store.beginOrRead(key: key, customerUID: customerUID)
        } else {
            let legacyDownloads = root.appendingPathComponent("legacy-downloads.json")
            let legacyProcessed = root.appendingPathComponent("legacy-processed.json")
            let downloads = """
            {"records":[{"messageHash":"\(key.messageHash)","phase":"failed","fileName":null}]}
            """
            let processed = """
            {"entries":[{"messageHash":"\(key.messageHash)","customerHash":"\(key.customerHash)","type":"video"}]}
            """
            try Data(downloads.utf8).write(to: legacyDownloads)
            try Data(processed.utf8).write(to: legacyProcessed)
            try await store.migrateLegacyJournals(
                downloadURL: legacyDownloads,
                processedURL: legacyProcessed
            )
        }
        try await store.scheduleRetry(
            key,
            failure: .connectTimeout,
            nextAttemptAt: now,
            needsFreshAddress: true
        )
        if fallbackAdmitted { try await store.markFallbackAdmitted(key) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ScriptedSystemDownloader: VideoDownloadAttempting {
    enum Result: Sendable {
        case success(Data)
        case failure(VideoTransferFailureCategory)
    }

    let result: Result

    func download(_ source: URL, to destination: URL) async throws -> VideoDownloadAttemptResult {
        switch result {
        case .success(let data):
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return VideoDownloadAttemptResult(statusCode: 200, elapsedMilliseconds: 1, bytes: Int64(data.count))
        case .failure(let category):
            throw VideoTransferAttemptError(
                category: category,
                isRetryable: true,
                sanitizedDescription: "scripted failure"
            )
        }
    }
}

private struct FixedRouteProvider: AlternateVideoRouteProviding {
    func candidates(for approvedHost: String) async throws -> [AlternateVideoRoute] {
        [AlternateVideoRoute(address: "1.1.1.1", poolID: "fixture", family: .ipv4)]
    }
}

private struct ScriptedAlternateDownloader: AlternateRouteDownloading {
    enum Result: Sendable {
        case success(Data)
        case failure(VideoTransferFailureCategory)
    }

    let result: Result

    func downloadFirstValid(
        source: URL,
        candidates: [AlternateVideoRoute],
        destination: URL
    ) async throws -> AlternateRouteReceipt {
        switch result {
        case .success(let data):
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return AlternateRouteReceipt(
                route: candidates[0],
                result: VideoDownloadAttemptResult(
                    statusCode: 200,
                    elapsedMilliseconds: 1,
                    bytes: Int64(data.count)
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

private actor VideoTransferEventRecorder {
    private(set) var downloaded: [DownloadedCustomerVideo] = []
    private(set) var exhaustedCount = 0
    private(set) var freshAddressUIDs: [String] = []
    private(set) var statusPhases: [DurableVideoTransferPhase] = []

    func receive(_ event: VideoTransferEvent) {
        switch event {
        case .downloaded(let receipt): downloaded.append(receipt)
        case .immediateRoutesExhausted: exhaustedCount += 1
        case .freshAddressNeeded(let request): freshAddressUIDs.append(request.customerUID)
        case .stateChanged(let status): statusPhases.append(status.phase)
        }
    }
}
