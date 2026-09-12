import CoreGraphics
import Foundation
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

final class CustomerRequestPackageExporterTests: XCTestCase {
    func testBoundedLocalFileReaderTimesOutWithoutWaitingForHungCopyProcess() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-reader-source-\(UUID().uuidString)")
        try Data("history".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let reader = BoundedLocalFileReader(
            timeout: 0.1,
            readOperation: { url in
                Thread.sleep(forTimeInterval: 0.5)
                return try Data(contentsOf: url)
            }
        )
        let startedAt = Date()

        do {
            _ = try await reader.read(source)
            XCTFail("A blocked file copy must time out")
        } catch CustomerRequestExportError.historyReadTimedOut {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        }
    }

    func testDroppedLeadingXiaoServiceReplyIsPersistedButDoesNotQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-dropped-xiao-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "加普威旗舰店:丹2026-8-2815:18:02", box: CGRect(x: 280, y: 40, width: 210, height: 20)),
                OCRLine(text: "转人工已读", box: CGRect(x: 390, y: 70, width: 90, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        )

        let queue = try await CustomerRequestPackageExporter(rootDirectory: root)
            .export(result: result, serviceAliases: ["小丹", "小秦"])
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.jsonl"),
            encoding: .utf8
        )

        XCTAssertNil(queue)
        XCTAssertTrue(history.contains("\"sender\":\"service\""))
        XCTAssertTrue(history.contains("\"v\":\"转人工\""))
    }

    func testCollapsedCustomerArrowQueuesBeforeConfiguredServiceAlias() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-collapsed-customer-arrow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = OCRRunResult(
            lines: [
                OCRLine(
                    text: "stoneshishininger>加普威旗舰店:小丹2026-8-2815:18:02",
                    box: CGRect(x: 20, y: 40, width: 390, height: 20)
                ),
                OCRLine(text: "客户确实要求转人工", box: CGRect(x: 20, y: 70, width: 160, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "stoneshishininger",
                axSessionList: "stoneshishininger",
                ocr: nil
            )
        )

        let queue = try await CustomerRequestPackageExporter(rootDirectory: root)
            .export(result: result, serviceAliases: ["小丹", "小秦"])
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/stoneshishininger/history.jsonl"),
            encoding: .utf8
        )

        XCTAssertNotNil(queue)
        XCTAssertTrue(history.contains("\"sender\":\"customer\""))
        XCTAssertTrue(history.contains("\"v\":\"客户确实要求转人工\""))
    }

    func testCustomerBCRefreshQueueEvenWhenServiceAnswerATrailsViewport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-customer-tail-after-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["capture-a", "capture-bc"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-28 09:00:00", box: CGRect(x: 20, y: 40, width: 280, height: 20)),
                OCRLine(text: "A", box: CGRect(x: 20, y: 70, width: 40, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-28 09:00:00", box: CGRect(x: 20, y: 40, width: 280, height: 20)),
                OCRLine(text: "A", box: CGRect(x: 20, y: 70, width: 40, height: 20)),
                OCRLine(text: "alice --> 店铺 2026-8-28 09:00:01", box: CGRect(x: 20, y: 100, width: 280, height: 20)),
                OCRLine(text: "B", box: CGRect(x: 20, y: 130, width: 40, height: 20)),
                OCRLine(text: "alice --> 店铺 2026-8-28 09:00:02", box: CGRect(x: 20, y: 160, width: 280, height: 20)),
                OCRLine(text: "C", box: CGRect(x: 20, y: 190, width: 40, height: 20)),
                OCRLine(text: "加普威旗舰店:小丹 2026-8-28 09:00:03", box: CGRect(x: 280, y: 220, width: 210, height: 20)),
                OCRLine(text: "answer A", box: CGRect(x: 390, y: 250, width: 90, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: identity
        )

        let firstExport = try await exporter.export(result: first)
        let firstQueueURL = try XCTUnwrap(firstExport)
        let firstQueue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: firstQueueURL)) as? [String: Any]
        )
        let firstVersion = try XCTUnwrap(firstQueue["history_version"] as? String)
        let secondExport = try await exporter.export(result: second)
        let secondQueueURL = try XCTUnwrap(secondExport)
        let secondQueue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: secondQueueURL)) as? [String: Any]
        )
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.jsonl"),
            encoding: .utf8
        )

        XCTAssertNotEqual(secondQueue["history_version"] as? String, firstVersion)
        XCTAssertTrue(history.contains("\"v\":\"B\""))
        XCTAssertTrue(history.contains("\"v\":\"C\""))
    }

    func testNewCustomerImageQueuesEvenWhenOldServiceTextFollowsInViewport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-image-before-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeSolidImage(red: 30, green: 120, blue: 210)
        let result = OCRRunResult(
            lines: [
                OCRLine(
                    text: "加普威旗舰店:小丹 2026-8-27 09:55:48",
                    box: CGRect(x: 280, y: 380, width: 210, height: 20)
                ),
                OCRLine(text: "10", box: CGRect(x: 430, y: 410, width: 30, height: 20)),
            ],
            images: [DetectedChatImage(
                box: CGRect(x: 10, y: 20, width: 260, height: 330),
                image: image
            )],
            sourceImageSize: CGSize(width: 500, height: 450),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "tb263147182",
                axSessionList: nil,
                ocr: nil
            )
        )
        let parsed = ParsedChatParser.parse(
            lines: result.lines,
            imageBoxes: result.images.map(\.box),
            imageHeight: result.sourceImageSize.height
        )
        XCTAssertEqual(parsed.messages.first?.type, "image")
        XCTAssertEqual(parsed.messages.first?.sender, "customer")
        XCTAssertEqual(parsed.messages.last?.sender, "service", "Fixture must reproduce the old queue blocker")

        let queue = try await CustomerRequestPackageExporter(rootDirectory: root).export(result: result)

        XCTAssertNotNil(queue, "A newly detected customer image must reach the AI queue")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("待处理/tb263147182.json").path
        ))
    }

    func testHeaderlessImageQueuesAndIdenticalRescanDoesNotQueueAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qianniu-headerless-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeSolidImage(red: 12, green: 80, blue: 180)
        let result = OCRRunResult(lines: [],
            images: [DetectedChatImage(box: CGRect(x: 10, y: 0, width: 260, height: 350), image: image)],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: CustomerIdentityCandidates(axHeader: "tb263147182", axSessionList: nil, ocr: nil))
        let exporter = CustomerRequestPackageExporter(rootDirectory: root)
        let first = try await exporter.export(result: result)
        XCTAssertNotNil(first, "A headerless customer image must reach the real queue")
        let historyURL = root.appendingPathComponent("用户/tb263147182/history.jsonl")
        let firstHistory = try Data(contentsOf: historyURL)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: firstHistory) as? [String: Any])
        XCTAssertEqual(row["sender"] as? String, "customer")
        XCTAssertEqual(row["t"] as? String, "image")
        let path = try XCTUnwrap(row["p"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("用户/tb263147182/" + path).path))
        if let first { try FileManager.default.removeItem(at: first) }
        let second = try await exporter.export(result: result)
        XCTAssertNil(second, "The same scan must retain existing duplicate suppression")
        XCTAssertEqual(try Data(contentsOf: historyURL), firstHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("待处理/tb263147182.json").path))
    }

    func testDifferentHeaderlessImageReplacingVisibleImageQueuesAsNewCustomerMessage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-replaced-headerless-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "tb263147182",
            axSessionList: nil,
            ocr: nil
        )
        func result(image: CGImage) -> OCRRunResult {
            OCRRunResult(
                lines: [],
                images: [DetectedChatImage(
                    box: CGRect(x: 10, y: 0, width: 260, height: 350),
                    image: image
                )],
                sourceImageSize: CGSize(width: 500, height: 400),
                identityCandidates: identity
            )
        }

        let first = try await exporter.export(result: result(
            image: try makeSolidImage(red: 12, green: 80, blue: 180)
        ))
        let firstQueue = try XCTUnwrap(first)
        try FileManager.default.removeItem(at: firstQueue)

        let second = try await exporter.export(result: result(
            image: try makeSolidImage(red: 210, green: 40, blue: 70)
        ))

        XCTAssertNotNil(second, "A different image at the same visible position must be a new customer message")
        let imageDirectory = root.appendingPathComponent("用户/tb263147182/images")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).sorted(),
            ["req-1-1.jpg", "req-2-1.jpg"]
        )
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/tb263147182/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(history.components(separatedBy: "\"t\":\"image\"").count - 1, 2)
    }

    func testScrolledOldCardDoesNotQueueWhenLaterReplyIsOutsideViewport() async throws {
        try await assertCardQueueAfterScroll(laterReply: true, nextTime: "2026-8-25 18:17:03", expectedQueue: false)
    }

    func testSameTimedLinkCardDoesNotQueueWhenTitleOCRChanges() async throws {
        try await assertCardQueueAfterScroll(laterReply: false, nextTime: "2026-8-25 18:17:03", expectedQueue: false)
    }

    func testSameLinkCardAtNewTimeStillQueues() async throws {
        try await assertCardQueueAfterScroll(laterReply: true, nextTime: "2026-8-26 08:00:00", expectedQueue: true)
    }

    func testNewCustomerTextFollowingOldCardStillQueues() async throws {
        try await assertCardQueueAfterScroll(laterReply: true, nextTime: "2026-8-25 18:17:03", newText: true, expectedQueue: true)
    }

    func testUntimestampedNewTextAfterKnownCardStillQueues() async throws {
        try await assertCardQueueAfterScroll(laterReply: false, nextTime: "2026-8-25 18:17:03", newText: true, untimedText: true, expectedQueue: true)
    }

    func testUntimestampedNewTextAfterOldCardStillQueues() async throws {
        try await assertCardQueueAfterScroll(laterReply: true, nextTime: "2026-8-25 18:17:03", newText: true, untimedText: true, expectedQueue: true)
    }

    private func assertCardQueueAfterScroll(
        laterReply: Bool, nextTime: String, newText: Bool = false, untimedText: Bool = false, expectedQueue: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qianniu-card-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let trigger = RecordingQueueTrigger()
        let exporter = CustomerRequestPackageExporter(rootDirectory: root, queueTrigger: trigger)
        func result(title: String, time: String, reply: Bool, newText: Bool = false) -> OCRRunResult {
            var lines = [
                OCRLine(text: "alice --> 店铺 \(time)", box: CGRect(x: 20, y: 70, width: 450, height: 20)),
                OCRLine(text: title, box: CGRect(x: 20, y: 100, width: 160, height: 14)),
                OCRLine(text: "月销182", box: CGRect(x: 20, y: 140, width: 100, height: 14)),
                OCRLine(text: "https://detail.tmall.com/item.htm?id=539699766942", box: CGRect(x: 20, y: 180, width: 180, height: 14)),
                OCRLine(text: "当前用户来自商品详情页", box: CGRect(x: 20, y: 220, width: 180, height: 14)),
            ]
            if reply {
                lines += [
                    OCRLine(text: "加普威旗舰店:小丹 2026-8-25 22:01:45", box: CGRect(x: 280, y: 260, width: 210, height: 20)),
                    OCRLine(text: "您好，请问需要什么帮助？", box: CGRect(x: 290, y: 290, width: 190, height: 20)),
                ]
            }
            if newText {
                if !untimedText {
                    lines.append(OCRLine(text: "alice --> 店铺 2026-8-26 08:01:00", box: CGRect(x: 20, y: 320, width: 300, height: 20)))
                }
                lines += [
                    OCRLine(text: "这个怎么连接手机？", box: CGRect(x: 20, y: 350, width: 150, height: 20)),
                ]
            }
            let parsed = ParsedChatParser.parse(lines: lines, imageBoxes: [], imageHeight: 450)
            XCTAssertTrue(parsed.messages.contains {
                $0.sender == "customer" && $0.type == "link" && $0.value == "https://detail.tmall.com/item.htm?id=539699766942"
            }, "Fixture must preserve the real customer link: \(parsed.messages)")
            return OCRRunResult(lines: lines, sourceImageSize: CGSize(width: 500, height: 450),
                identityCandidates: CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil))
        }
        let firstQueue = try await exporter.export(result: result(title: "蓝牙WIFI针式打印机", time: "2026-8-25 18:17:03", reply: laterReply))
        if let firstQueue { try FileManager.default.removeItem(at: firstQueue) }
        let before = await trigger.count
        let second = try await exporter.export(result: result(title: "蓝牙无线票全新针式打印机手机", time: nextTime, reply: false, newText: newText))
        XCTAssertEqual(second != nil, expectedQueue)
        XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("待处理/alice.json").path), expectedQueue)
        let after = await trigger.count
        XCTAssertEqual(after - before, expectedQueue ? 1 : 0)
        // This fix must not discard OCR evidence or stop updating the readable history.
        let text = try String(contentsOf: root.appendingPathComponent("用户/alice/history.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("蓝牙无线票全新针式打印机手机"))
    }

    func testSameResolvedLinkIsNotAppendedAgainWhenNeighboringOCRChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-link-dedup-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["first", "shifted"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let fullURL = "https://detail.tmall.com/item.htm?id=539699766942&ut_sk=test"
        let identity = CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        func result(neighbor: String) -> OCRRunResult {
            OCRRunResult(
                lines: [
                    OCRLine(text: "alice --> 店铺 2026-8-25 18:17:03", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                    OCRLine(text: neighbor, box: CGRect(x: 20, y: 100, width: 100, height: 20)),
                    OCRLine(text: fullURL, box: CGRect(x: 20, y: 160, width: 300, height: 20)),
                    OCRLine(text: "客服 2026-8-25 18:18:00", box: CGRect(x: 300, y: 200, width: 180, height: 20)),
                    OCRLine(text: "已收到", box: CGRect(x: 400, y: 230, width: 70, height: 20)),
                ],
                sourceImageSize: CGSize(width: 500, height: 350),
                identityCandidates: identity
            )
        }

        _ = try await exporter.export(result: result(neighbor: "商品标题"))
        _ = try await exporter.export(result: result(neighbor: "商品标题OCR变化"))

        let history = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(history.components(separatedBy: fullURL).count - 1, 1)
    }

    func testSameResolvedLinkSentAgainAtNewestPositionIsKept() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-link-repeat-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["first", "second"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let fullURL = "https://detail.tmall.com/item.htm?id=539699766942&ut_sk=test"
        let identity = CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 18:17:03", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: fullURL, box: CGRect(x: 20, y: 100, width: 300, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let repeatedLater = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 19:17:03", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: fullURL, box: CGRect(x: 20, y: 100, width: 300, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        _ = try await exporter.export(result: first)
        _ = try await exporter.export(result: repeatedLater)

        let history = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(history.components(separatedBy: fullURL).count - 1, 2)
    }

    func testFullLinkUpgradeAppendsOnlyTheLinkInsteadOfDuplicatingVisibleHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-link-upgrade-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["legacy", "resolved"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        func result(link: String) -> OCRRunResult {
            OCRRunResult(
                lines: [
                    OCRLine(
                        text: "alice --> 店铺 2026-8-25 18:17:03",
                        box: CGRect(x: 20, y: 70, width: 280, height: 20)
                    ),
                    OCRLine(text: "商品标题", box: CGRect(x: 20, y: 100, width: 80, height: 20)),
                    OCRLine(text: link, box: CGRect(x: 20, y: 160, width: 300, height: 20)),
                ],
                sourceImageSize: CGSize(width: 500, height: 350),
                identityCandidates: identity
            )
        }

        _ = try await exporter.export(
            result: result(link: "https://detail.tmall.com/item.htm?...")
        )
        _ = try await exporter.export(
            result: result(link: "https://detail.tmall.com/item.htm?id=539699766942")
        )

        let history = root.appendingPathComponent("用户/alice/history.jsonl")
        let objects = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["v"] as? String }, [
            "商品标题",
            "https://detail.tmall.com/item.htm?...",
            "https://detail.tmall.com/item.htm?id=539699766942",
        ])
    }

    func testServiceOnlyIncrementUpdatesHistoryWithoutQueuingOrTriggeringAI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-service-only-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let trigger = RecordingQueueTrigger()
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) },
            queueTrigger: trigger
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        let customerOnly = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 80, width: 280, height: 20)),
                OCRLine(text: "你好", box: CGRect(x: 20, y: 110, width: 40, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let withServiceReply = OCRRunResult(
            lines: customerOnly.lines + [
                OCRLine(text: "加普威旗舰店:小丹 2026-8-25 10:00:05", box: CGRect(x: 280, y: 150, width: 210, height: 20)),
                OCRLine(text: "您好", box: CGRect(x: 430, y: 180, width: 40, height: 20)),
                OCRLine(text: "已读", box: CGRect(x: 465, y: 180, width: 28, height: 14)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        let firstExport = try await exporter.export(result: customerOnly)
        let firstQueue = try XCTUnwrap(firstExport)
        try FileManager.default.removeItem(at: firstQueue)
        let secondQueue = try await exporter.export(result: withServiceReply)

        XCTAssertNil(secondQueue)
        let triggerCount = await trigger.count
        XCTAssertEqual(triggerCount, 1)
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(history.contains("\"sender\":\"service\""))
        XCTAssertTrue(history.contains("\"v\":\"您好\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("待处理/alice.json").path))
    }

    func testCodexBatchTriggerLaunchesBundledExecutableDirectly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-direct-launch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("AI客服-Codex批处理.app", isDirectory: true)
        let executable = app.appendingPathComponent(
            "Contents/MacOS/AI客服-Codex批处理",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let recorder = URLLaunchRecorder()
        let trigger = CodexBatchAppTrigger(
            rootDirectory: root,
            batchAppURL: app,
            launchExecutable: { url in await recorder.record(url) }
        )

        await trigger.trigger()

        let launchedURL = await recorder.lastURL
        XCTAssertEqual(launchedURL, executable)
    }

    func testCodexBatchTriggerWritesRunRequestEvenWhenBatchAppIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-run-marker-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let missingApp = root.appendingPathComponent("missing.app")
        let trigger = CodexBatchAppTrigger(rootDirectory: root, batchAppURL: missingApp)

        await trigger.trigger()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("运行状态/needs-run").path
            )
        )
    }

    func testCodexBatchTriggerFallsBackToSuiteComponentWhenSiblingAppIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-suite-fallback-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let missingSibling = applications
            .appendingPathComponent("AI客服-Codex批处理.app", isDirectory: true)
        let suiteApp = applications
            .appendingPathComponent("AI客服三件套.app", isDirectory: true)
        let fallbackExecutable = suiteApp.appendingPathComponent(
            "Contents/Resources/Components/AI客服-Codex批处理.app/Contents/MacOS/AI客服-Codex批处理"
        )
        try FileManager.default.createDirectory(
            at: fallbackExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: fallbackExecutable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fallbackExecutable.path
        )
        let recorder = URLLaunchRecorder()
        let trigger = CodexBatchAppTrigger(
            rootDirectory: root,
            batchAppURL: missingSibling,
            launchExecutable: { url in await recorder.record(url) }
        )

        await trigger.trigger()

        let launchedURL = await recorder.lastURL
        XCTAssertEqual(launchedURL, fallbackExecutable)
    }

    func testNewQueueEntryTriggersBatchOnceAndRepeatedScanDoesNotTriggerAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-trigger-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let trigger = RecordingQueueTrigger()
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) },
            queueTrigger: trigger
        )
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "你好", box: CGRect(x: 20, y: 100, width: 40, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "alice",
                axSessionList: "alice",
                ocr: nil
            )
        )

        _ = try await exporter.export(result: result)
        _ = try await exporter.export(result: result)

        let triggerCount = await trigger.count
        XCTAssertEqual(triggerCount, 1)
    }

    func testNewMessagesUpsertOneQueuePointerForTheUserAndDoNotCreateZip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-pointer-queue-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        var dates = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 60),
        ]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { dates.removeFirst() }
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "第一条", box: CGRect(x: 20, y: 100, width: 60, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "第一条", box: CGRect(x: 20, y: 100, width: 60, height: 20)),
                OCRLine(text: "alice --> 店铺 2026-8-25 10:01:00", box: CGRect(x: 20, y: 130, width: 280, height: 20)),
                OCRLine(text: "第二条", box: CGRect(x: 20, y: 160, width: 60, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        let firstExport = try await exporter.export(result: first)
        let firstQueueURL = try XCTUnwrap(firstExport)
        let firstQueueObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: firstQueueURL)) as? [String: Any]
        )
        let firstHistoryVersion = try XCTUnwrap(firstQueueObject["history_version"] as? String)
        let secondExport = try await exporter.export(result: second)
        let secondQueueURL = try XCTUnwrap(secondExport)

        XCTAssertEqual(firstQueueURL, secondQueueURL)
        XCTAssertEqual(firstQueueURL.lastPathComponent, "alice.json")
        let queueObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: secondQueueURL)) as? [String: Any]
        )
        XCTAssertEqual(queueObject["uid"] as? String, "alice")
        XCTAssertEqual(
            queueObject["user_directory"] as? String,
            root.appendingPathComponent("用户/alice").path
        )
        XCTAssertEqual(queueObject["queued_at"] as? String, "1970-01-01T00:01:00Z")
        let secondHistoryVersion = try XCTUnwrap(queueObject["history_version"] as? String)
        XCTAssertEqual(secondHistoryVersion.count, 64)
        XCTAssertNotEqual(firstHistoryVersion, secondHistoryVersion)
        let pendingFiles = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("待处理").path
        )
        XCTAssertEqual(pendingFiles, ["alice.json"])
        XCTAssertFalse(pendingFiles.contains { $0.hasSuffix(".zip") })
    }

    func testExportUsesAXHeaderWhenOCRDoesNotContainUID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-ax-uid-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "1", box: CGRect(x: 20, y: 100, width: 10, height: 18)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "tb9783153356",
                axSessionList: "tb9783153356",
                ocr: nil
            )
        )
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { "ax-request" },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let exportedURL = try await exporter.export(result: result)
        let queueURL = try XCTUnwrap(exportedURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: queueURL)
            ) as? [String: Any]
        )

        XCTAssertEqual(object["uid"] as? String, "tb9783153356")
        XCTAssertEqual(
            object["user_directory"] as? String,
            root.appendingPathComponent("用户/tb9783153356").path
        )
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/tb9783153356/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(history.contains("\"v\":\"1\""))
    }

    func testExportCreatesQueuePointerAndStoresJPEGInUserDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-package-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeSolidImage(red: 40, green: 120, blue: 200)
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "tb263147182", box: CGRect(x: 10, y: 5, width: 100, height: 20)),
                OCRLine(text: "tb263147182 --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 140, width: 320, height: 20)),
                OCRLine(text: "请问怎么安装？", box: CGRect(x: 20, y: 170, width: 130, height: 20)),
            ],
            images: [DetectedChatImage(box: CGRect(x: 20, y: 60, width: 100, height: 80), image: image)],
            sourceImageSize: CGSize(width: 500, height: 350)
        )
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { "20260810-test-0001" },
            now: { Date(timeIntervalSince1970: 0) }
        )

        let exportedURL = try await exporter.export(result: result)
        let queueURL = try XCTUnwrap(exportedURL)

        XCTAssertEqual(queueURL.lastPathComponent, "tb263147182.json")
        let jsonData = try Data(contentsOf: queueURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )
        XCTAssertEqual(object["uid"] as? String, "tb263147182")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "用户/tb263147182/images/20260810-test-0001-1.jpg"
                ).path
            )
        )
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/tb263147182/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(history.contains("images/20260810-test-0001-1.jpg"))
    }

    func testRepeatedScanDoesNotAppendHistoryOrCreateAnotherQueueEntry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "tb263147182", box: CGRect(x: 10, y: 5, width: 100, height: 20)),
                OCRLine(text: "tb263147182 --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 320, height: 20)),
                OCRLine(text: "你好", box: CGRect(x: 20, y: 100, width: 40, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350)
        )

        let firstExport = try await exporter.export(result: result)
        let firstQueue = try XCTUnwrap(firstExport)
        let repeatedQueue = try await exporter.export(result: result)

        let history = root
            .appendingPathComponent("用户/tb263147182/history.jsonl")
        let lines = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstQueue.path))
        XCTAssertNil(repeatedQueue)
        let queueNames = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("待处理").path
        )
        XCTAssertEqual(queueNames, ["tb263147182.json"])
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(first["sender"] as? String, "customer")
    }

    func testHumanReadableHistoryContainsEachNewMessageOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-readable-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2", "req-3"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "旧消息", box: CGRect(x: 20, y: 100, width: 60, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "旧消息", box: CGRect(x: 20, y: 100, width: 60, height: 20)),
                OCRLine(text: "alice --> 店铺 2026-8-25 10:01:00", box: CGRect(x: 20, y: 130, width: 280, height: 20)),
                OCRLine(text: "新增消息", box: CGRect(x: 20, y: 160, width: 80, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        _ = try await exporter.export(result: first)
        _ = try await exporter.export(result: second)
        _ = try await exporter.export(result: second)

        let readableHistory = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(
            readableHistory,
            "[2026-8-25 10:00:00] 客户\n旧消息\n\n"
                + "[2026-8-25 10:01:00] 客户\n新增消息\n\n"
        )
    }

    func testRepeatedScanRebuildsMissingReadableHistoryFromJSONL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-readable-backfill-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let result = OCRRunResult(
            lines: [OCRLine(text: "已有消息", box: CGRect(x: 20, y: 100, width: 80, height: 20))],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "alice",
                axSessionList: "alice",
                ocr: nil
            )
        )
        let readableHistory = root.appendingPathComponent("用户/alice/history.txt")

        _ = try await exporter.export(result: result)
        try FileManager.default.removeItem(at: readableHistory)
        let repeatedPackage = try await exporter.export(result: result)

        XCTAssertNil(repeatedPackage)
        XCTAssertEqual(
            try String(contentsOf: readableHistory, encoding: .utf8),
            "[1970-01-01T00:00:00Z] 未知\n已有消息\n\n"
        )
    }

    func testSecondScanAppendsOnlyMessagesAfterHistoryOverlapAndRefreshesQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-incremental-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 70, width: 280, height: 20)),
                OCRLine(text: "旧消息", box: CGRect(x: 20, y: 100, width: 60, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "alice",
                axSessionList: "alice",
                ocr: nil
            )
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-25 10:01:00", box: CGRect(x: 20, y: 110, width: 280, height: 20)),
                OCRLine(text: "新增消息", box: CGRect(x: 20, y: 140, width: 80, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "alice",
                axSessionList: "alice",
                ocr: nil
            )
        )

        _ = try await exporter.export(result: first)
        let secondExport = try await exporter.export(result: second)
        let secondQueue = try XCTUnwrap(secondExport)

        let history = root.appendingPathComponent("用户/alice/history.jsonl")
        let historyObjects = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(historyObjects.compactMap { $0["v"] as? String }, ["旧消息", "新增消息"])

        XCTAssertEqual(secondQueue.lastPathComponent, "alice.json")
        let queue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: secondQueue)) as? [String: Any]
        )
        XCTAssertEqual(queue["user_directory"] as? String, root.appendingPathComponent("用户/alice").path)
    }

    func testIncrementalHistoryStoresOnlyNewImagesInUserDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-incremental-image-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let oldImage = try makeSolidImage(red: 20, green: 40, blue: 60)
        let newImage = try makeSolidImage(red: 80, green: 100, blue: 120)
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        let first = OCRRunResult(
            lines: [],
            images: [
                DetectedChatImage(
                    box: CGRect(x: 20, y: 60, width: 100, height: 70),
                    image: oldImage
                ),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [],
            images: [
                DetectedChatImage(
                    box: CGRect(x: 20, y: 60, width: 100, height: 70),
                    image: oldImage
                ),
                DetectedChatImage(
                    box: CGRect(x: 20, y: 160, width: 100, height: 70),
                    image: newImage
                ),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        _ = try await exporter.export(result: first)
        let secondExport = try await exporter.export(result: second)
        let secondQueueURL = try XCTUnwrap(secondExport)

        let storedImages = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("用户/alice/images").path
        ).sorted()
        XCTAssertEqual(storedImages, ["req-1-1.jpg", "req-2-2.jpg"])
        let queue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: secondQueueURL)) as? [String: Any]
        )
        XCTAssertEqual(
            queue["current_customer_image_paths"] as? [String],
            ["images/req-2-2.jpg"],
            "The queue boundary must preserve which image belongs to this customer turn"
        )
    }

    func testNewTextAfterServiceDoesNotRearchiveOldVisibleImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-old-image-before-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let image = try makeSolidImage(red: 20, green: 40, blue: 60)
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        let first = OCRRunResult(
            lines: [
                OCRLine(
                    text: "加普威旗舰店:小丹 2026-8-27 12:00:10",
                    box: CGRect(x: 280, y: 380, width: 210, height: 20)
                ),
                OCRLine(text: "10", box: CGRect(x: 430, y: 410, width: 30, height: 20)),
            ],
            images: [
                DetectedChatImage(
                    box: CGRect(x: 10, y: 20, width: 260, height: 330),
                    image: image
                ),
            ],
            sourceImageSize: CGSize(width: 500, height: 450),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(
                    text: "加普威旗舰店:小丹 2026-8-27 12:04:07",
                    box: CGRect(x: 280, y: 300, width: 210, height: 20)
                ),
                OCRLine(text: "1 已读", box: CGRect(x: 430, y: 330, width: 55, height: 20)),
                OCRLine(
                    text: "alice --> 店铺 2026-8-27 12:43:51",
                    box: CGRect(x: 20, y: 380, width: 300, height: 20)
                ),
                OCRLine(text: "哦哦", box: CGRect(x: 20, y: 410, width: 50, height: 20)),
            ],
            images: [
                DetectedChatImage(
                    box: CGRect(x: 10, y: 20, width: 260, height: 330),
                    image: image
                ),
            ],
            sourceImageSize: CGSize(width: 500, height: 450),
            identityCandidates: identity
        )

        XCTAssertEqual(
            ParsedChatParser.parse(
                lines: first.lines,
                imageBoxes: first.images.map(\.box),
                imageHeight: first.sourceImageSize.height
            ).messages.map { "\($0.sender):\($0.type):\($0.value?.trimmingCharacters(in: .whitespaces) ?? "")" },
            ["customer:image:", "service:text:10"]
        )
        XCTAssertEqual(
            ParsedChatParser.parse(
                lines: second.lines,
                imageBoxes: second.images.map(\.box),
                imageHeight: second.sourceImageSize.height
            ).messages.map { "\($0.sender):\($0.type):\($0.value?.trimmingCharacters(in: .whitespaces) ?? "")" },
            ["customer:image:", "service:text:1", "customer:text:哦哦"]
        )

        let firstQueue = try await exporter.export(result: first)
        if let firstQueue { try FileManager.default.removeItem(at: firstQueue) }
        let secondQueue = try await exporter.export(result: second)

        XCTAssertNotNil(secondQueue, "The new customer text still needs a reply")
        let storedImages = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("用户/alice/images").path
        ).sorted()
        XCTAssertEqual(storedImages, ["req-1-1.jpg"], "The old visible image must not be archived again")
        let history = try String(
            contentsOf: root.appendingPathComponent("用户/alice/history.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(history.components(separatedBy: "\"t\":\"image\"").count - 1, 1)
        XCTAssertTrue(history.contains("\"v\":\"哦哦\""))
    }

    func testImageAndTextAfterServiceKeepNewImageButDropOldVisibleImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-image-text-after-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let oldImage = try makeSolidImage(red: 20, green: 40, blue: 60)
        let newImage = try makeSolidImage(red: 80, green: 100, blue: 120)
        let identity = CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        let oldBox = CGRect(x: 20, y: 100, width: 100, height: 70)
        let newBox = CGRect(x: 20, y: 280, width: 100, height: 70)
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "加普威旗舰店:小丹 2026-8-27 12:00:10", box: CGRect(x: 280, y: 200, width: 210, height: 20)),
                OCRLine(text: "10", box: CGRect(x: 430, y: 230, width: 30, height: 20)),
            ],
            images: [DetectedChatImage(box: oldBox, image: oldImage)],
            sourceImageSize: CGSize(width: 500, height: 450),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "加普威旗舰店:小丹 2026-8-27 12:04:07", box: CGRect(x: 280, y: 200, width: 210, height: 20)),
                OCRLine(text: "1 已读", box: CGRect(x: 430, y: 230, width: 55, height: 20)),
                OCRLine(text: "alice --> 店铺 2026-8-27 12:43:51", box: CGRect(x: 20, y: 350, width: 300, height: 20)),
                OCRLine(text: "图片和文字一起", box: CGRect(x: 20, y: 380, width: 130, height: 20)),
            ],
            images: [
                DetectedChatImage(box: oldBox, image: oldImage),
                DetectedChatImage(box: newBox, image: newImage),
            ],
            sourceImageSize: CGSize(width: 500, height: 450),
            identityCandidates: identity
        )

        XCTAssertEqual(
            ParsedChatParser.parse(
                lines: second.lines,
                imageBoxes: second.images.map(\.box),
                imageHeight: second.sourceImageSize.height
            ).messages.map { "\($0.sender):\($0.type):\($0.path ?? "")" },
            ["customer:image:images/1.jpg", "service:text:", "customer:image:images/2.jpg", "customer:text:"]
        )
        let firstQueue = try await exporter.export(result: first)
        if let firstQueue { try FileManager.default.removeItem(at: firstQueue) }
        let secondExport = try await exporter.export(result: second)
        let secondQueue = try XCTUnwrap(secondExport)

        let storedImages = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("用户/alice/images").path
        ).sorted()
        XCTAssertEqual(storedImages, ["req-1-1.jpg", "req-2-2.jpg"])
        let queue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: secondQueue)) as? [String: Any]
        )
        XCTAssertEqual(queue["current_customer_image_paths"] as? [String], ["images/req-2-2.jpg"])
    }

    func testScrolledWindowUsesHistorySuffixAsOverlap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-scrolled-overlap-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "较早消息", box: CGRect(x: 20, y: 80, width: 80, height: 20)),
                OCRLine(text: "重叠消息", box: CGRect(x: 20, y: 120, width: 80, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "重叠消息", box: CGRect(x: 20, y: 80, width: 80, height: 20)),
                OCRLine(text: "滚动后新增", box: CGRect(x: 20, y: 120, width: 100, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        _ = try await exporter.export(result: first)
        _ = try await exporter.export(result: second)

        let history = root.appendingPathComponent("用户/alice/history.jsonl")
        let values = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> String? in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                return object?["v"] as? String
            }
        XCTAssertEqual(values, ["较早消息", "重叠消息", "滚动后新增"])
    }

    func testSameTextAtDifferentTimestampIsAppendedAsNewMessage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-timestamp-identity-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        func result(timestamp: String) -> OCRRunResult {
            OCRRunResult(
                lines: [
                    OCRLine(
                        text: "alice --> 店铺 2026-8-24 \(timestamp)",
                        box: CGRect(x: 20, y: 80, width: 260, height: 20)
                    ),
                    OCRLine(text: "相同文字", box: CGRect(x: 20, y: 120, width: 80, height: 20)),
                ],
                sourceImageSize: CGSize(width: 500, height: 350),
                identityCandidates: identity
            )
        }

        _ = try await exporter.export(result: result(timestamp: "08:52:01"))
        _ = try await exporter.export(result: result(timestamp: "08:53:01"))

        let history = root.appendingPathComponent("用户/alice/history.jsonl")
        let objects = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["v"] as? String }, ["相同文字", "相同文字"])
        XCTAssertEqual(
            objects.compactMap { $0["timestamp"] as? String },
            ["2026-8-24 08:52:01", "2026-8-24 08:53:01"]
        )
    }

    func testChangedLeadingOCRDoesNotReappendStableTimestampedTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-stable-tail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(
            axHeader: "alice",
            axSessionList: "alice",
            ocr: nil
        )
        func result(leadingText: String) -> OCRRunResult {
            OCRRunResult(
                lines: [
                    OCRLine(
                        text: "alice --> 店铺 2026-8-27 14:00:00",
                        box: CGRect(x: 20, y: 40, width: 300, height: 20)
                    ),
                    OCRLine(text: leadingText, box: CGRect(x: 20, y: 70, width: 120, height: 20)),
                    OCRLine(
                        text: "加普威旗舰店:小丹 2026-8-27 14:11:47",
                        box: CGRect(x: 270, y: 110, width: 210, height: 20)
                    ),
                    OCRLine(
                        text: "图片已收到，请问需要分析什么？",
                        box: CGRect(x: 200, y: 140, width: 280, height: 20)
                    ),
                    OCRLine(
                        text: "alice --> 店铺 2026-8-27 14:11:58",
                        box: CGRect(x: 20, y: 180, width: 300, height: 20)
                    ),
                    OCRLine(text: "分析一下天气现象", box: CGRect(x: 20, y: 210, width: 160, height: 20)),
                ],
                sourceImageSize: CGSize(width: 500, height: 350),
                identityCandidates: identity
            )
        }

        _ = try await exporter.export(result: result(leadingText: "旧引导A"))
        let secondQueue = try await exporter.export(result: result(leadingText: "旧引导B"))

        XCTAssertNil(secondQueue)
        let history = root.appendingPathComponent("用户/alice/history.jsonl")
        let objects = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["v"] as? String }, [
            "旧引导A",
            "图片已收到，请问需要分析什么？",
            "分析一下天气现象",
        ])
    }

    func testStableTimestampedAnchorKeepsLaterNewCustomerMessage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-stable-anchor-new-tail-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = ["req-1", "req-2"]
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { ids.removeFirst() },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let identity = CustomerIdentityCandidates(axHeader: "alice", axSessionList: "alice", ocr: nil)
        let first = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-27 14:11:58", box: CGRect(x: 20, y: 80, width: 300, height: 20)),
                OCRLine(text: "分析一下天气现象", box: CGRect(x: 20, y: 110, width: 160, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )
        let second = OCRRunResult(
            lines: [
                OCRLine(text: "alice --> 店铺 2026-8-27 14:11:58", box: CGRect(x: 20, y: 80, width: 300, height: 20)),
                OCRLine(text: "分析一下天气现象", box: CGRect(x: 20, y: 110, width: 160, height: 20)),
                OCRLine(text: "alice --> 店铺 2026-8-27 14:12:30", box: CGRect(x: 20, y: 150, width: 300, height: 20)),
                OCRLine(text: "再看看这张图", box: CGRect(x: 20, y: 180, width: 120, height: 20)),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: identity
        )

        _ = try await exporter.export(result: first)
        let secondQueue = try await exporter.export(result: second)

        XCTAssertNotNil(secondQueue)
        let history = root.appendingPathComponent("用户/alice/history.jsonl")
        let objects = try String(contentsOf: history, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["v"] as? String }, ["分析一下天气现象", "再看看这张图"])
    }

    func testQueueWriteFailureLeavesNoHistoryOrCustomerImages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-rollback-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeSolidImage(red: 40, green: 120, blue: 200)
        let blockedQueueURL = root.appendingPathComponent("待处理/tb263147182.json")
        try FileManager.default.createDirectory(
            at: blockedQueueURL,
            withIntermediateDirectories: true
        )
        let exporter = CustomerRequestPackageExporter(
            rootDirectory: root,
            requestID: { "failed-request" },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "tb263147182", box: CGRect(x: 10, y: 5, width: 100, height: 20)),
                OCRLine(text: "tb263147182 --> 店铺 2026-8-25 10:00:00", box: CGRect(x: 20, y: 30, width: 320, height: 20)),
            ],
            images: [DetectedChatImage(box: CGRect(x: 20, y: 60, width: 100, height: 80), image: image)],
            sourceImageSize: CGSize(width: 500, height: 350)
        )

        do {
            _ = try await exporter.export(result: result)
            XCTFail("queue write failure should be surfaced")
        } catch {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("用户/tb263147182/history.jsonl").path
                )
            )
            let imageDirectory = root.appendingPathComponent("用户/tb263147182/images")
            let imageNames = (try? FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)) ?? []
            XCTAssertTrue(imageNames.isEmpty, "orphan images: \(imageNames)")
        }
    }

    func testConcurrentExporterInstancesDoNotLoseHistoryLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-concurrency-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let result = OCRRunResult(
                        lines: [
                            OCRLine(
                                text: "并发消息\(index)",
                                box: CGRect(x: 20, y: 100, width: 80, height: 20)
                            ),
                        ],
                        sourceImageSize: CGSize(width: 500, height: 350),
                        identityCandidates: CustomerIdentityCandidates(
                            axHeader: "tb263147182",
                            axSessionList: "tb263147182",
                            ocr: nil
                        )
                    )
                    let exporter = CustomerRequestPackageExporter(
                        rootDirectory: root,
                        requestID: { "concurrent-\(index)" },
                        now: { Date(timeIntervalSince1970: 0) }
                    )
                    _ = try await exporter.export(result: result)
                }
            }
            try await group.waitForAll()
        }

        let history = root.appendingPathComponent("用户/tb263147182/history.jsonl")
        let lines = try String(contentsOf: history, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 8)
    }
}

private actor URLLaunchRecorder {
    private(set) var lastURL: URL?

    func record(_ url: URL) {
        lastURL = url
    }
}

private actor RecordingQueueTrigger: CustomerQueueTriggering {
    private(set) var count = 0

    func trigger() async {
        count += 1
    }
}

private func makeSolidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
    let width = 12
    let height = 10
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        bytes[offset] = red
        bytes[offset + 1] = green
        bytes[offset + 2] = blue
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    return try XCTUnwrap(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
}
