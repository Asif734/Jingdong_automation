import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class ParsedChatTests: XCTestCase {
    func testConfiguredServiceAliasesReplaceFlagshipStoreHeuristic() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "grozziie格志旗舰店 2026-8-27 18:16:05", box: rect(5, 40, 280, 16)),
                OCRLine(text: "Justin", box: rect(5, 68, 70, 18)),
                OCRLine(text: "加普威旗舰店:小秦 2026-8-27 18:17:20", box: rect(360, 100, 300, 16)),
                OCRLine(text: "收到", box: rect(590, 128, 70, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小秦"]
        )

        XCTAssertEqual(result.messages.map(\.sender), ["customer", "service"])
        XCTAssertEqual(result.messages.map(\.value), ["Justin", "收到"])
    }

    func testArrowSenderRemainsCustomerEvenWhenNameMatchesServiceAlias() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "小丹 --> 加普威旗舰店 2026-8-27 18:18:00", box: rect(5, 40, 300, 16)),
                OCRLine(text: "客户昵称刚好同名", box: rect(5, 68, 150, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小秦"]
        )

        XCTAssertEqual(result.messages.first?.sender, "customer")
    }

    func testArrowCustomerIsNotUpgradedByReadReceipt() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "小雷 --> 加普威旗舰店 2026-8-27 18:18:00", box: rect(5, 40, 300, 16)),
                OCRLine(text: "客户消息里也可能碰巧出现状态文字", box: rect(5, 68, 240, 18)),
                OCRLine(text: "已读", box: rect(590, 68, 40, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小雷"]
        )

        XCTAssertEqual(result.messages.first?.sender, "customer")
    }

    func testConfiguredServiceAliasAcceptsOnlyDroppedLeadingXiaoInServiceHeader() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店:丹 2026-8-28 15:18:02", box: rect(360, 100, 300, 16)),
                // Keep the body on the customer side so the assertion proves the
                // configured header, rather than horizontal fallback, owns identity.
                OCRLine(text: "转人工", box: rect(5, 128, 70, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小秦"]
        )

        XCTAssertEqual(result.messages.first?.sender, "service")
    }

    func testConfiguredServiceAliasWithoutColonNeedsReadReceiptToConfirmService() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店小雷 2026-8-27 08:55:06", box: rect(5, 100, 300, 16)),
                OCRLine(text: "这是客服发出的历史回复", box: rect(5, 128, 180, 18)),
                OCRLine(text: "已读", box: rect(590, 128, 40, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小雷"]
        )

        XCTAssertEqual(result.messages.first?.sender, "service")
        XCTAssertEqual(result.messages.first?.readStatus, "已读")
    }

    func testConfiguredServiceAliasWithoutColonIsStillService() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店小雷 2026-8-27 08:55:06", box: rect(5, 100, 300, 16)),
                OCRLine(text: "没有第二项证据时不能猜身份", box: rect(5, 128, 220, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小雷"]
        )

        XCTAssertEqual(result.messages.first?.sender, "service")
    }

    func testUnrecognizedColonHeaderIsCustomer() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店:小开 2026-8-28 15:18:02", box: rect(360, 100, 300, 16)),
                // A sender that is not one of the configured service aliases is a customer.
                OCRLine(text: "这是一条真实客户消息", box: rect(590, 128, 150, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小秦"]
        )

        XCTAssertEqual(result.messages.first?.sender, "customer")
    }

    func testArrowCustomerWinsEvenWhenOCRDropsLeadingXiaoFromConfiguredAlias() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "丹 --> 加普威旗舰店 2026-8-28 15:18:02", box: rect(5, 100, 300, 16)),
                OCRLine(text: "客户确实要求转人工", box: rect(5, 128, 150, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小秦"]
        )

        XCTAssertEqual(result.messages.first?.sender, "customer")
    }

    func testCollapsedCustomerArrowWinsBeforeConfiguredServiceAlias() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(
                    text: "stoneshishininger>加普威旗舰店:小丹 2026-8-28 15:18:02",
                    box: rect(5, 100, 420, 16)
                ),
                OCRLine(text: "这是客户发来的消息", box: rect(5, 128, 150, 18)),
            ],
            imageBoxes: [],
            imageHeight: 400,
            serviceAliases: ["小丹", "小秦"]
        )

        XCTAssertEqual(result.messages.first?.sender, "customer")
    }

    func testImageWithoutAnyOCRHeaderDefaultsToCustomer() {
        let result = ParsedChatParser.parse(lines: [],
            imageBoxes: [CGRect(x: 10, y: 0, width: 260, height: 350)], imageHeight: 400)
        XCTAssertEqual(result.rawOCR, ["[图片]"])
        XCTAssertEqual(result.messages.map(\.sender), ["customer"])
        XCTAssertNil(result.messages.first?.timestamp, "Do not invent a timestamp")
    }

    func testUnknownImageHeaderDefaultsToCustomerWithoutChangingUnknownText() {
        let lines = [
            OCRLine(text: "2026-8-26 17:22:40", box: rect(10, 70, 150, 16)),
        ]
        let image = ParsedChatParser.parse(lines: lines,
            imageBoxes: [rect(10, 100, 260, 200)], imageHeight: 400)
        XCTAssertEqual(image.messages.first?.sender, "customer")
        XCTAssertEqual(image.messages.first?.timestamp, "2026-8-26 17:22:40")
        let text = ParsedChatParser.parse(lines: lines + [OCRLine(text: "普通文字", box: rect(10, 100, 90, 16))],
            imageBoxes: [], imageHeight: 400)
        XCTAssertEqual(text.messages.first?.sender, "unknown")
    }

    func testExplicitServiceImageDoesNotBecomeCustomer() {
        let result = ParsedChatParser.parse(lines: [
            OCRLine(text: "加普威旗舰店:小丹 2026-8-26 17:22:40", box: rect(10, 70, 300, 16)),
        ], imageBoxes: [rect(10, 100, 260, 200)], imageHeight: 400)
        XCTAssertEqual(result.messages.first?.sender, "service")
        XCTAssertEqual(result.messages.first?.type, "image")
    }

    func testCompleteCopiedURLIsEmittedAsLinkMessage() {
        let url = "https://detail.tmall.com/item.htm?id=539699766942&ut_sk=test"
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(
                    text: "tb263147182 -> 加普威旗舰店 2026-8-25 18:17:03",
                    box: CGRect(x: 5, y: 30, width: 260, height: 14)
                ),
                OCRLine(text: url, box: CGRect(x: 5, y: 54, width: 280, height: 14)),
            ],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, "customer")
        XCTAssertEqual(result.messages[0].type, "link")
        XCTAssertEqual(result.messages[0].value, url)
    }

    func testEllipsizedOCRURLKeepsLegacyTextFallback() {
        let visible = "https://detail.tmall.com/item.htm?.."
        let result = ParsedChatParser.parse(
            lines: [OCRLine(text: visible, box: CGRect(x: 5, y: 54, width: 280, height: 14))],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].type, "text")
        XCTAssertEqual(result.messages[0].value, visible)
    }

    func testImageBelowJoinedCustomerIDAndTimestampBelongsToCustomer() {
        let imageBox = CGRect(x: 9, y: 81, width: 262, height: 196)
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(
                    text: "tb2631471822026-8-2517:01:09",
                    box: CGRect(x: 5, y: 54, width: 167, height: 13)
                ),
            ],
            imageBoxes: [imageBox],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].type, "image")
        XCTAssertEqual(result.messages[0].sender, "customer")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-25 17:01:09")
    }

    func testJoinedCustomerIDAndTimestampWithoutFollowingImageKeepsLegacyUnknownSender() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(
                    text: "tb2631471822026-8-2517:01:09",
                    box: CGRect(x: 5, y: 54, width: 167, height: 13)
                ),
                OCRLine(
                    text: "普通文字",
                    box: CGRect(x: 5, y: 81, width: 70, height: 13)
                ),
            ],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].type, "text")
        XCTAssertEqual(result.messages[0].sender, "unknown")
    }

    func testTallImageDoesNotConsumeServiceMessageBelowIt() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(
                    text: "tb263147182 -> 加普威旗舰店 2026-8-25 17:15:51",
                    box: CGRect(x: 5, y: 30, width: 260, height: 14)
                ),
                OCRLine(
                    text: "加普威旗舰店：小丹 2026-8-25 17:15:57",
                    box: CGRect(x: 5, y: 361, width: 191, height: 14)
                ),
                OCRLine(
                    text: "1已读",
                    box: CGRect(x: 4, y: 382, width: 41, height: 14)
                ),
            ],
            imageBoxes: [CGRect(x: 9, y: 49, width: 262, height: 294)],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 2)
        guard result.messages.count == 2 else { return }
        XCTAssertEqual(result.messages[0].type, "image")
        XCTAssertEqual(result.messages[0].sender, "customer")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-25 17:15:51")
        XCTAssertEqual(result.messages[1].type, "text")
        XCTAssertEqual(result.messages[1].sender, "service")
        XCTAssertEqual(result.messages[1].value, "1")
        XCTAssertEqual(result.messages[1].timestamp, "2026-8-25 17:15:57")
    }

    func testTopCroppedTimestampFragmentIsNotCustomerTextBeforeImages() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "1020314/102", box: CGRect(x: 6, y: 47, width: 62, height: 10)),
                OCRLine(text: "2U0-0-∠01/:10:0", box: CGRect(x: 77, y: 47, width: 91, height: 10)),
                OCRLine(text: "tb263147182", box: CGRect(x: 6, y: 284, width: 64, height: 10)),
                OCRLine(text: "2026-8-2517:15:51", box: CGRect(x: 75, y: 282, width: 93, height: 12)),
            ],
            imageBoxes: [
                CGRect(x: 9, y: 308, width: 261, height: 92),
                CGRect(x: 9, y: 70, width: 262, height: 196),
            ],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.messages.allSatisfy { $0.type == "image" })
    }

    func testArrowMetadataUsesLabelBeforeArrowAsSender() {
        for arrow in ["-->", "->", "—>", "→"] {
            let result = ParsedChatParser.parse(
                lines: [
                    OCRLine(
                        text: "stoneshishininger\(arrow)加普威旗舰店:小艳",
                        box: rect(4, 61, 260, 14),
                        confidence: 0.99
                    ),
                    OCRLine(
                        text: "2026-8-2408:52:01",
                        box: rect(270, 61, 140, 14),
                        confidence: 0.98
                    ),
                    OCRLine(
                        text: "请你转给子账号小丹。",
                        box: rect(5, 90, 150, 18),
                        confidence: 0.99
                    ),
                ],
                imageBoxes: [],
                imageHeight: 373
            )

            XCTAssertEqual(result.messages.count, 1, "arrow: \(arrow)")
            XCTAssertEqual(result.messages[0].sender, "customer", "arrow: \(arrow)")
            XCTAssertEqual(result.messages[0].timestamp, "2026-8-24 08:52:01", "arrow: \(arrow)")
            XCTAssertEqual(result.messages[0].value, "请你转给子账号小丹。", "arrow: \(arrow)")
        }
    }

    func testCollapsedArrowGlyphRequiresPlausibleCustomerAccountBeforeStore() {
        func parseSender(_ metadata: String) -> String? {
            ParsedChatParser.parse(
                lines: [
                    OCRLine(text: metadata, box: rect(4, 61, 260, 14), confidence: 0.99),
                    OCRLine(
                        text: "2026-8-2408:52:01",
                        box: rect(270, 61, 140, 14),
                        confidence: 0.98
                    ),
                    OCRLine(text: "消息正文", box: rect(5, 90, 70, 18), confidence: 0.99),
                ],
                imageBoxes: [],
                imageHeight: 373
            ).messages.first?.sender
        }

        XCTAssertEqual(
            parseSender("stoneshishininger>加普威旗舰店:小艳"),
            "customer"
        )
        XCTAssertEqual(
            parseSender("备注>加普威旗舰店:小艳"),
            "service"
        )
    }

    func testRawOCRPreservesEveryOrderedTokenWhileParsedOutputKeepsStandaloneOne() {
        let lines = [
            OCRLine(text: "加普威旗舰店:小丹", box: rect(420, 20, 120, 16), confidence: 0.98),
            OCRLine(text: "2026-8-1021:10:02", box: rect(550, 20, 140, 16), confidence: 0.96),
            OCRLine(text: "1", box: rect(620, 48, 10, 18), confidence: 0.99),
            OCRLine(text: "已读", box: rect(650, 48, 28, 14), confidence: 0.91),
            OCRLine(text: "-", box: rect(120, 360, 5, 6), confidence: 0.20),
            OCRLine(text: ",", box: rect(160, 362, 4, 5), confidence: 0.25),
        ]

        let result = ParsedChatParser.parse(lines: lines, imageBoxes: [], imageHeight: 400)

        XCTAssertEqual(
            result.rawOCR,
            ["加普威旗舰店:小丹", "2026-8-1021:10:02", "1", "已读", "-", ","]
        )
        XCTAssertTrue(result.messages.contains { $0.value == "1" })
        XCTAssertFalse(result.messages.contains { $0.value == "-" || $0.value == "," })
    }

    func testMergesStoreMetadataAndExtractsReadStatusFromFollowingMessage() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店:小丹", box: rect(400, 20, 130, 16), confidence: 0.95),
                OCRLine(text: "2026-8-10", box: rect(540, 20, 80, 16), confidence: 0.95),
                OCRLine(text: "21:10:02", box: rect(625, 20, 65, 16), confidence: 0.95),
                OCRLine(text: "你不是客服已读", box: rect(500, 48, 135, 18), confidence: 0.98),
            ],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, "service")
        XCTAssertEqual(result.messages[0].value, "你不是客服")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-10 21:10:02")
        XCTAssertEqual(result.messages[0].readStatus, "已读")
    }

    func testMergesAlignedWrappedServiceRowsIntoOneMessage() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店:小丹", box: rect(470, 20, 130, 16), confidence: 0.98),
                OCRLine(text: "2026-8-2510:55:19", box: rect(610, 20, 145, 16), confidence: 0.98),
                OCRLine(
                    text: "金属疲劳是指金属材料在反复或交变载荷作用下，即使受力低于其静态强度，也可能逐渐",
                    box: rect(475, 48, 520, 18),
                    confidence: 0.99
                ),
                OCRLine(
                    text: "产生微小裂纹，裂纹不断扩展后最终发生断裂。常见影响因素包括载荷次数和幅度、表面",
                    box: rect(475, 70, 520, 18),
                    confidence: 0.99
                ),
                OCRLine(
                    text: "缺陷、应力集中、腐蚀环境及温度等。已读",
                    box: rect(475, 92, 270, 18),
                    confidence: 0.99
                ),
            ],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, "service")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-25 10:55:19")
        XCTAssertEqual(
            result.messages[0].value,
            "金属疲劳是指金属材料在反复或交变载荷作用下，即使受力低于其静态强度，也可能逐渐产生微小裂纹，裂纹不断扩展后最终发生断裂。常见影响因素包括载荷次数和幅度、表面缺陷、应力集中、腐蚀环境及温度等。"
        )
        XCTAssertEqual(result.messages[0].readStatus, "已读")
    }

    // Coordinates from the 2026-08-26 live TP732 screenshot. The second
    // text box overlaps the first by 2px and starts 2px further left.
    func testLiveOverlappingWrappedRowsKeepTopToBottomOrder() {
        let first = "您好，TP732不支持原生macOS，无法直接连接Mac使用；电脑端仅支"
        for scale: CGFloat in [0.75, 1, 2] {
            for offset: CGFloat in [0, 120] {
                for hasToolbar in [false, true] {
                    func line(_ text: String, _ box: CGRect, _ confidence: Double = 0.99) -> OCRLine {
                        OCRLine(text: text, box: CGRect(
                            x: (box.minX + offset) * scale, y: (box.minY + offset) * scale,
                            width: box.width * scale, height: box.height * scale
                        ), confidence: confidence)
                    }
                    var lines = [
                        line("加普威旗舰店:小丹2026-8-2610:09:36", rect(15, 344, 197, 14)),
                        line(first, rect(14, 366, 376, 14)),
                        line("持Windows。", rect(12, 378, 78, 19)),
                        line("未读", rect(397, 379, 27, 15)),
                    ]
                    if hasToolbar {
                        lines.append(line("…", rect(442, 373, 61, 21), 0.776))
                    }
                    let result = ParsedChatParser.parse(
                        lines: lines.reversed(), imageBoxes: [], imageHeight: (417 + offset) * scale
                    )
                    XCTAssertEqual(result.messages, [ParsedChatMessage(
                        sender: "service", type: "text", value: first + "持Windows。",
                        path: nil, timestamp: "2026-8-26 10:09:36", readStatus: "未读"
                    )], "scale=\(scale), offset=\(offset), toolbar=\(hasToolbar)")
                    XCTAssertEqual(result.rawOCR.count, lines.count)
                }
            }
        }
    }

    func testThreeOverlappingRowsDoNotCascadeIntoOneVisualRow() {
        let result = ParsedChatParser.parse(lines: [
            OCRLine(text: "加普威旗舰店:小丹2026-8-2610:09:36", box: rect(15, 80, 197, 14)),
            OCRLine(text: "第一行", box: rect(15, 110, 180, 19)),
            OCRLine(text: "第二行", box: rect(14, 127, 180, 19)),
            OCRLine(text: "第三行", box: rect(12, 144, 78, 19)),
            OCRLine(text: "已读", box: rect(205, 146, 27, 15)),
            OCRLine(text: "tb263147182", box: rect(15, 200, 85, 14)),
            OCRLine(text: "2026-8-2610:10:00", box: rect(120, 200, 130, 14)),
            OCRLine(text: "下一条", box: rect(15, 227, 60, 18)),
        ], imageBoxes: [], imageHeight: 300)
        XCTAssertEqual(result.messages.map(\.value), ["第一行第二行第三行", "下一条"])
        XCTAssertEqual(result.messages.map(\.sender), ["service", "customer"])
        XCTAssertEqual(result.messages.first?.readStatus, "已读")
    }

    func testReadStatusToolbarFilteringPreservesActualBodySymbols() {
        let result = ParsedChatParser.parse(lines: [
            OCRLine(text: "加普威旗舰店:小丹2026-8-2610:09:36", box: rect(15, 80, 197, 14)),
            OCRLine(text: "1□…?", box: rect(15, 110, 70, 18), confidence: 0.99),
            OCRLine(text: "未读", box: rect(100, 111, 27, 15), confidence: 0.99),
            OCRLine(text: "□…", box: rect(145, 105, 61, 21), confidence: 0.6),
        ], imageBoxes: [], imageHeight: 300)
        XCTAssertEqual(result.messages.map(\.value), ["1□…?"])
        XCTAssertEqual(result.messages.first?.readStatus, "未读")
        XCTAssertTrue(result.rawOCR.contains("□…"))

        let ambiguous = ParsedChatParser.parse(lines: [
            OCRLine(text: "tb263147182", box: rect(15, 80, 85, 14)),
            OCRLine(text: "2026-8-2610:10:00", box: rect(120, 80, 130, 14)),
            OCRLine(text: "符号", box: rect(15, 110, 30, 18), confidence: 0.99),
            OCRLine(text: "□…", box: rect(50, 110, 61, 21), confidence: 0.6),
        ], imageBoxes: [], imageHeight: 300)
        XCTAssertEqual(ambiguous.messages.map(\.value), ["符号□…"])
    }

    func testSmallBaselinePunctuationStaysWithItsText() {
        let result = ParsedChatParser.parse(lines: [
            OCRLine(text: "加普威旗舰店:小丹2026-8-2610:09:36", box: rect(15, 80, 197, 14)),
            OCRLine(text: "您好", box: rect(15, 110, 30, 18), confidence: 0.99),
            OCRLine(text: "。", box: rect(46, 123, 5, 5), confidence: 0.99),
        ], imageBoxes: [], imageHeight: 300)
        XCTAssertEqual(result.messages.map(\.value), ["您好。"])
        XCTAssertEqual(result.messages.map(\.sender), ["service"])
    }

    func testLiteralReadStatusWordsWithAdjacentQuestionMarkAreNotToolbar() {
        let result = ParsedChatParser.parse(lines: [
            OCRLine(text: "加普威旗舰店:小丹2026-8-2610:09:36", box: rect(15, 80, 197, 14)),
            OCRLine(text: "请看", box: rect(15, 110, 30, 18), confidence: 0.99),
            OCRLine(text: "未读", box: rect(47, 111, 27, 15), confidence: 0.99),
            OCRLine(text: "?", box: rect(76, 112, 8, 14), confidence: 0.8),
        ], imageBoxes: [], imageHeight: 300)
        XCTAssertEqual(result.messages.map(\.value), ["请看未读?"])
        XCTAssertNil(result.messages.first?.readStatus)
    }

    func testSmallPunctuationAttachesToNearestWordNotEveryWordInRow() {
        let result = ParsedChatParser.parse(lines: [
            OCRLine(text: "加普威旗舰店:小丹2026-8-2610:09:36", box: rect(15, 80, 197, 14)),
            OCRLine(text: "您好", box: rect(15, 110, 30, 18), confidence: 0.99),
            OCRLine(text: "世界", box: rect(50, 110, 30, 18), confidence: 0.99),
            OCRLine(text: "。", box: rect(81, 123, 5, 5), confidence: 0.99),
            OCRLine(text: "已读", box: rect(100, 111, 27, 15), confidence: 0.99),
        ], imageBoxes: [], imageHeight: 300)
        XCTAssertEqual(result.messages.map(\.value), ["您好世界。"])
        XCTAssertEqual(result.messages.map(\.sender), ["service"])
        XCTAssertEqual(result.messages.first?.readStatus, "已读")
    }

    func testMergesStoreNameAndTimestampAcrossOCRRowsWithoutTurningFragmentsIntoMessages() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "加普威旗舰店:小丹", box: rect(420, 20, 130, 14), confidence: 0.95),
                OCRLine(text: "-", box: rect(560, 22, 5, 6), confidence: 0.3),
                OCRLine(text: "2026-8-1021:10:02", box: rect(520, 42, 145, 14), confidence: 0.96),
                OCRLine(text: ",", box: rect(675, 44, 4, 5), confidence: 0.3),
                OCRLine(text: "你不是客服已读", box: rect(510, 70, 135, 18), confidence: 0.98),
            ],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, "service")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-10 21:10:02")
        XCTAssertEqual(result.messages[0].value, "你不是客服")
        XCTAssertEqual(
            result.rawOCR,
            ["加普威旗舰店:小丹", "-", "2026-8-1021:10:02", ",", "你不是客服已读"]
        )
    }

    func testImageMarkerKeepsVerticalOrderAndRawMarker() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "图片之前", box: rect(20, 20, 80, 18)),
                OCRLine(text: "图片之后", box: rect(20, 240, 80, 18)),
            ],
            imageBoxes: [rect(30, 80, 200, 120)],
            imageHeight: 400
        )

        XCTAssertEqual(result.rawOCR, ["图片之前", "[图片]", "图片之后"])
        XCTAssertEqual(result.messages.map(\.type), ["text", "image", "text"])
        XCTAssertEqual(result.messages[1].path, "images/1.jpg")
    }

    func testAmbiguousShortPunctuationOutsideToolbarIsPreserved() {
        let result = ParsedChatParser.parse(
            lines: [OCRLine(text: "?", box: rect(20, 100, 8, 15), confidence: 0.3)],
            imageBoxes: [],
            imageHeight: 400
        )

        XCTAssertEqual(result.messages.map(\.value), ["?"])
        XCTAssertEqual(result.messages.map(\.sender), ["unknown"])
    }

    func testSkipsHeaderAccountRowButPreservesItInRawOCR() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "tb9783153356", box: rect(33, 15, 101, 16), confidence: 0.99),
                OCRLine(text: "G三", box: rect(394, 12, 96, 24), confidence: 0.58),
                OCRLine(text: "tb9783153356", box: rect(4, 61, 81, 14), confidence: 0.99),
                OCRLine(text: "2026-8-1021:09:49", box: rect(92, 61, 109, 14), confidence: 0.98),
                OCRLine(text: "我是店铺客服。", box: rect(5, 90, 110, 14), confidence: 0.99),
            ],
            imageBoxes: [],
            imageHeight: 373
        )

        XCTAssertEqual(
            result.rawOCR,
            ["tb9783153356", "G三", "tb9783153356", "2026-8-1021:09:49", "我是店铺客服。"]
        )
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, "customer")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-10 21:09:49")
        XCTAssertEqual(result.messages[0].value, "我是店铺客服。")
    }

    func testAcceptsFullWidthTimeColonInServiceMetadata() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(
                    text: "加普威旗舰店：小丹2026-8-1021：10:06",
                    box: rect(5, 187, 218, 14),
                    confidence: 0.95
                ),
                OCRLine(text: "你不是客服已读", box: rect(2, 209, 107, 19), confidence: 0.99),
            ],
            imageBoxes: [],
            imageHeight: 373
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, "service")
        XCTAssertEqual(result.messages[0].timestamp, "2026-8-10 21:10:06")
        XCTAssertEqual(result.messages[0].value, "你不是客服")
        XCTAssertEqual(result.messages[0].readStatus, "已读")
    }

    func testAccountLikeMessageBelowHeaderBandIsNotDiscarded() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "tb12345678", box: rect(20, 120, 90, 18), confidence: 0.99),
            ],
            imageBoxes: [],
            imageHeight: 350
        )

        XCTAssertEqual(result.messages.map(\.value), ["tb12345678"])
    }

    func testOCRNoiseInsideDetectedImageStaysRawButDoesNotBecomeTextMessages() {
        let result = ParsedChatParser.parse(
            lines: [
                OCRLine(text: "H", box: rect(115, 136, 10, 10), confidence: 0.05),
                OCRLine(text: "福", box: rect(117, 202, 20, 22), confidence: 0.05),
                OCRLine(text: "?", box: rect(76, 156, 159, 195), confidence: 0.40),
                OCRLine(text: "图片之后", box: rect(300, 405, 80, 15), confidence: 0.99),
            ],
            imageBoxes: [rect(16, 56, 259, 343)],
            imageHeight: 440
        )

        XCTAssertEqual(result.rawOCR, ["H", "福", "[图片]", "?", "图片之后"])
        XCTAssertEqual(result.messages.map(\.type), ["image", "text"])
        XCTAssertEqual(result.messages.compactMap(\.value), ["图片之后"])
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
