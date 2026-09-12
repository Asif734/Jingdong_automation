import XCTest
import QianniuOCRAppSupport
@testable import AutoReplyApp

final class QianniuMediaLogResolverTests: XCTestCase {
    private var root: URL!
    private var logURL: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QianniuMediaLogResolverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        logURL = root.appendingPathComponent("app.log")
        storeURL = root.appendingPathComponent("processed-events.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: logURL)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testExactVideoMessageIDIsIgnored() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        try append(customerLine(id: "VIDEO.PNM", uid: "buyer-a", date: now))
        try append("messageType=105 messageId=VIDEO.PNM MESSAGETEMPLATETYPE_VIDEO")
        let recorder = VideoDetectionRecorder()
        let resolver = QianniuMediaLogResolver(
            logURLs: [logURL], processedStoreURL: storeURL,
            onVideoDetected: { await recorder.record($0) }
        )

        let result = await resolver.resolve(customerUID: "buyer-a", now: now)
        let detected = await recorder.messageIDs

        XCTAssertEqual(result, .ignoreVideo(messageID: "VIDEO.PNM"))
        XCTAssertEqual(detected, ["VIDEO.PNM"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path),
                       "video discovery must not be marked processed before transfer completion")
    }

    func testDownloadingVideoResolvesAsInFlightInsteadOfOpeningAgain() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_050)
        try append(customerLine(id: "VIDEO.ACTIVE", uid: "buyer-a", date: now))
        try append("messageType=105 messageId=VIDEO.ACTIVE")
        let transferStore = DurableVideoTransferStore(url: root.appendingPathComponent("transfer-state.json"))
        let key = VideoTransferIdentity.key(customerUID: "buyer-a", messageID: "VIDEO.ACTIVE")
        _ = try await transferStore.beginOrRead(key: key, customerUID: "buyer-a")
        try await transferStore.transition(key, to: .downloading)
        let resolver = QianniuMediaLogResolver(
            logURLs: [logURL],
            processedStoreURL: storeURL,
            videoTransferStore: transferStore
        )

        let result = await resolver.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(result, .videoInFlight(messageID: "VIDEO.ACTIVE"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func test101TemplateFallsBackToTraditionalImageFlowWithoutBecomingTypeEvidence() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_100)
        try append(customerLine(id: "IMAGE.PNM", uid: "buyer-a", date: now))
        try append("messageType:101 messageId=IMAGE.PNM MESSAGETEMPLATETYPE_IMAGETEXT")
        let recorder = VideoDetectionRecorder()
        let resolver = QianniuMediaLogResolver(
            logURLs: [logURL], processedStoreURL: storeURL,
            onVideoDetected: { await recorder.record($0) }
        )

        let result = await resolver.resolve(customerUID: "buyer-a", now: now)
        let detected = await recorder.messageIDs

        XCTAssertEqual(result, .copyImage(messageID: nil))
        XCTAssertEqual(detected, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func test105VideoWinsEvenWhenSameMessageAlsoUses101ImageTextTemplate() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_200)
        try append(customerLine(id: "CONFLICT.PNM", uid: "buyer-a", date: now))
        try append("messageType=101 messageId=CONFLICT.PNM")
        try append("messageType=105 messageId=CONFLICT.PNM")
        let resolver = QianniuMediaLogResolver(logURLs: [logURL], processedStoreURL: storeURL)

        let result = await resolver.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(result, .ignoreVideo(messageID: "CONFLICT.PNM"))
    }

    func testDifferentCustomerOrDifferentMessageIDCannotSuppressImage() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_300)
        try append(customerLine(id: "OTHER.PNM", uid: "buyer-b", date: now))
        try append("messageType=105 messageId=UNRELATED.PNM")
        let resolver = QianniuMediaLogResolver(logURLs: [logURL], processedStoreURL: storeURL)

        let result = await resolver.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(result, .copyImage(messageID: nil))
    }

    func testNewerUnresolvedEventBlocksOlderProcessedVideoFromSuppressingNewImage() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_350)
        try append(customerLine(id: "OLD-VIDEO.PNM", uid: "buyer-a", date: now.addingTimeInterval(-5)))
        try append("messageType=105 messageId=OLD-VIDEO.PNM")
        let resolver = QianniuMediaLogResolver(logURLs: [logURL], processedStoreURL: storeURL)
        let old = await resolver.resolve(customerUID: "buyer-a", now: now.addingTimeInterval(-5))
        XCTAssertEqual(old, .ignoreVideo(messageID: "OLD-VIDEO.PNM"))

        try append(customerLine(id: "NEW-NOT-YET-TYPED.PNM", uid: "buyer-a", date: now))
        let result = await resolver.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(result, .copyImage(messageID: nil))
    }

    func testDurableTransferStateKeepsSameVisibleVideoInFlightAfterResolverRestart() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_400)
        try append(customerLine(id: "ONCE.PNM", uid: "buyer-a", date: now))
        try append("messageType=105 messageId=ONCE.PNM")
        let transferStore = DurableVideoTransferStore(url: root.appendingPathComponent("transfer-state.json"))
        let first = QianniuMediaLogResolver(
            logURLs: [logURL], processedStoreURL: storeURL, videoTransferStore: transferStore
        )
        let firstResult = await first.resolve(customerUID: "buyer-a", now: now)
        XCTAssertEqual(firstResult, .ignoreVideo(messageID: "ONCE.PNM"))
        let key = VideoTransferIdentity.key(customerUID: "buyer-a", messageID: "ONCE.PNM")
        try await transferStore.transition(key, to: .downloading)

        let restarted = QianniuMediaLogResolver(
            logURLs: [logURL], processedStoreURL: storeURL, videoTransferStore: transferStore
        )
        let second = await restarted.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(second, .videoInFlight(messageID: "ONCE.PNM"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testIncompleteLogLineIsNotParsedUntilNewlineArrives() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_500)
        let line = customerLine(id: "PARTIAL.PNM", uid: "buyer-a", date: now)
        let midpoint = line.index(line.startIndex, offsetBy: line.count / 2)
        try appendRaw(String(line[..<midpoint]))
        let resolver = QianniuMediaLogResolver(logURLs: [logURL], processedStoreURL: storeURL)
        let incomplete = await resolver.resolve(customerUID: "buyer-a", now: now)
        XCTAssertEqual(incomplete, .copyImage(messageID: nil))

        try appendRaw(String(line[midpoint...]) + "\nmessageType=105 messageId=PARTIAL.PNM\n")
        let complete = await resolver.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(complete, .ignoreVideo(messageID: "PARTIAL.PNM"))
    }

    func testRecentTailRecoveryRejoinsVideoHintLostBetweenIncrementalScans() async throws {
        let now = Date(timeIntervalSince1970: 1_788_000_600)
        try append("messageType=105 messageId=LATE.PNM MESSAGETEMPLATETYPE_VIDEO")
        let resolver = QianniuMediaLogResolver(logURLs: [logURL], processedStoreURL: storeURL)

        let beforeCustomerEvent = await resolver.resolve(customerUID: "buyer-a", now: now)
        XCTAssertEqual(beforeCustomerEvent, .copyImage(messageID: nil))

        try append(customerLine(id: "LATE.PNM", uid: "buyer-a", date: now))
        let afterCustomerEvent = await resolver.resolve(customerUID: "buyer-a", now: now)

        XCTAssertEqual(afterCustomerEvent, .ignoreVideo(messageID: "LATE.PNM"))
    }

    private func customerLine(id: String, uid: String, date: Date) -> String {
        let milliseconds = Int(date.timeIntervalSince1970 * 1_000)
        return "[CHAT 测试店铺:客服#3#1][onEventNotify][ jsonStr=[{\"cid\":{\"nick\":\"\(uid)\"},\"newmsgs\":[{\"mcode\":{\"messageId\":\"\(id)\"},\"sendTime\":\(milliseconds),\"fromId\":{\"nick\":\"\(uid)\"},\"toId\":{\"nick\":\"测试店铺:客服\"}}]}],strEvent=im.singlemsg.onShopRobotReceriveNewMsgs"
    }

    private func append(_ line: String) throws { try appendRaw(line + "\n") }

    private func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

private actor VideoDetectionRecorder {
    private(set) var messageIDs: [String] = []
    func record(_ messageID: String) { messageIDs.append(messageID) }
}
