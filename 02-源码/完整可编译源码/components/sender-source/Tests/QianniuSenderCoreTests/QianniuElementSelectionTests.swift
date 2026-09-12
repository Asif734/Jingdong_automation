import CoreGraphics
import XCTest
@testable import QianniuSenderCore

final class QianniuElementSelectionTests: XCTestCase {
    func testComposerPolicyRestrictsInputToCalibratedRelativeRegion() {
        let chat = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let policy = ComposerSelectionPolicy(
            acceptedRoles: ["AXTextArea"],
            relativeRegion: CGRect(x: 0.10, y: 0.70, width: 0.80, height: 0.28),
            fallback: SendFallbackPolicy(relativeClickPoint: nil)
        )
        let expected = node(1, role: "AXTextArea", frame: CGRect(x: 250, y: 670, width: 650, height: 120))
        let outside = node(2, role: "AXTextArea", frame: CGRect(x: 250, y: 200, width: 650, height: 120))

        XCTAssertEqual(
            QianniuElementSelection.messageInput(nodes: [outside, expected], chatRegion: chat, policy: policy)?.id,
            1
        )
    }

    func testSearchFieldSelectionSurvivesWindowTranslationAndScaling() throws {
        let baseWindow = CGRect(x: 100, y: 50, width: 1600, height: 1000)
        let baseNodes = [
            node(1, role: "AXTextField", description: "联系人、订单号、聊天记录", frame: CGRect(x: 190, y: 180, width: 260, height: 42)),
            node(2, role: "AXTextField", description: "商品ID/标题/编码", frame: CGRect(x: 1200, y: 420, width: 300, height: 36)),
        ]
        let movedWindow = CGRect(x: 420, y: 200, width: 1280, height: 800)
        let movedNodes = [
            node(1, role: "AXTextField", description: "联系人、订单号、聊天记录", frame: CGRect(x: 492, y: 304, width: 208, height: 34)),
            node(2, role: "AXTextField", description: "商品ID/标题/编码", frame: CGRect(x: 1300, y: 496, width: 240, height: 29)),
        ]

        XCTAssertEqual(QianniuElementSelection.searchField(nodes: baseNodes, window: baseWindow)?.id, 1)
        XCTAssertEqual(QianniuElementSelection.searchField(nodes: movedNodes, window: movedWindow)?.id, 1)
    }

    func testChatHeaderRequiresExactUIDInHeaderRegion() {
        let chat = CGRect(x: 450, y: 100, width: 650, height: 850)
        let nodes = [
            node(1, role: "AXStaticText", value: "stoneshishininger", frame: CGRect(x: 470, y: 130, width: 240, height: 38)),
            node(2, role: "AXStaticText", value: "stoneshishininger", frame: CGRect(x: 600, y: 500, width: 240, height: 30)),
            node(3, role: "AXStaticText", value: "stoneshishininger-plus", frame: CGRect(x: 470, y: 135, width: 260, height: 30)),
        ]

        XCTAssertEqual(QianniuElementSelection.chatHeader(uid: "stoneshishininger", nodes: nodes, chatRegion: chat)?.id, 1)
        XCTAssertNil(QianniuElementSelection.chatHeader(uid: "missing", nodes: nodes, chatRegion: chat))
    }

    func testChatHeaderMatchAcceptsOnlyLongTruncatedPrefixInHeaderRegion() {
        let chat = CGRect(x: 430, y: 33, width: 635, height: 888)
        let nodes = [
            node(1, role: "AXStaticText", value: "stoneshishinin...", frame: CGRect(x: 457, y: 150, width: 190, height: 35)),
            node(2, role: "AXStaticText", value: "stones...", frame: CGRect(x: 457, y: 500, width: 120, height: 30)),
        ]

        XCTAssertTrue(QianniuElementSelection.chatHeaderMatches(uid: "stoneshishininger", nodes: nodes, chatRegion: chat))
        XCTAssertFalse(QianniuElementSelection.chatHeaderMatches(uid: "stoneshishixxxx", nodes: nodes, chatRegion: chat))
    }

    func testChatHeaderMatchAcceptsAccountScopedShortEnglishAndChinesePrefixes() {
        let chat = CGRect(x: 430, y: 33, width: 635, height: 888)

        func matches(_ visible: String, expected: String) -> Bool {
            QianniuElementSelection.chatHeaderMatches(
                uid: expected,
                nodes: [node(1, role: "AXStaticText", value: visible,
                             frame: CGRect(x: 457, y: 120, width: 190, height: 35))],
                chatRegion: chat
            )
        }

        XCTAssertTrue(matches("stonesh...", expected: "stoneshininger"))
        XCTAssertTrue(matches("STON ...", expected: "stoneshininger"), "case, spaces and compatibility forms are normalized")
        XCTAssertTrue(matches("易美…", expected: "易美得旗舰店"))
        XCTAssertFalse(matches("sto...", expected: "stoneshininger"), "Latin/digit prefixes require at least four characters")
        XCTAssertFalse(matches("易…", expected: "易美得旗舰店"), "Chinese prefixes require at least two characters")
        XCTAssertFalse(matches("shining...", expected: "stoneshininger"), "mid-string fragments are not identities")
    }

    func testChatIdentityAllowsExactHeaderAfterSubmittedSearchButProtectsTruncatedHeader() {
        let window = CGRect(x: 100, y: 50, width: 1300, height: 900)
        let chat = CGRect(x: 430, y: 50, width: 635, height: 900)
        let emptySearchAndExactHeader = [
            node(1, role: "AXTextField", description: "联系人、订单号、聊天记录", value: "", frame: CGRect(x: 180, y: 180, width: 250, height: 40)),
            node(2, role: "AXStaticText", value: "tb263147182", frame: CGRect(x: 470, y: 140, width: 180, height: 35)),
        ]
        let exactSearchAndTruncatedHeader = [
            node(3, role: "AXTextField", description: "联系人、订单号、聊天记录", value: "stoneshishininger", frame: CGRect(x: 180, y: 180, width: 250, height: 40)),
            node(4, role: "AXStaticText", value: "stoneshishinin...", frame: CGRect(x: 470, y: 140, width: 180, height: 35)),
        ]

        XCTAssertTrue(QianniuElementSelection.chatIdentityMatches(
            uid: "tb263147182", nodes: emptySearchAndExactHeader, window: window, chatRegion: chat
        ))
        XCTAssertTrue(QianniuElementSelection.chatIdentityMatches(
            uid: "stoneshishininger", nodes: exactSearchAndTruncatedHeader, window: window, chatRegion: chat
        ))
        XCTAssertFalse(QianniuElementSelection.chatIdentityMatches(
            uid: "stoneshishininger",
            nodes: [emptySearchAndExactHeader[0], exactSearchAndTruncatedHeader[1]],
            window: window,
            chatRegion: chat
        ))
    }

    func testChatIdentityUsesBoundChineseNicknameOnlyWithExactSubmittedUID() {
        let window = CGRect(x: 100, y: 50, width: 1300, height: 900)
        let chat = CGRect(x: 430, y: 50, width: 635, height: 900)
        let nodes = [
            node(1, role: "AXTextField", description: "联系人、订单号、聊天记录", value: "tb235692326486", frame: CGRect(x: 180, y: 180, width: 250, height: 40)),
            node(2, role: "AXStaticText", value: "优满仓进出口农货", frame: CGRect(x: 470, y: 140, width: 220, height: 35)),
        ]
        XCTAssertTrue(QianniuElementSelection.chatIdentityMatches(
            uid: "tb235692326486", nickname: "优满仓进出口农资", nodes: nodes, window: window, chatRegion: chat
        ))
        XCTAssertFalse(QianniuElementSelection.chatIdentityMatches(
            uid: "tb235692326486", nickname: "其他农资店", nodes: nodes, window: window, chatRegion: chat
        ))
        let wrongSearch = [node(1, role: "AXTextField", description: "联系人、订单号、聊天记录", value: "another-user", frame: CGRect(x: 180, y: 180, width: 250, height: 40)), nodes[1]]
        XCTAssertFalse(QianniuElementSelection.chatIdentityMatches(
            uid: "tb235692326486", nickname: "优满仓进出口农资", nodes: wrongSearch, window: window, chatRegion: chat
        ))
    }

    func testRoutedConversationAllowsExactUIDSearchWithComposerWhenHeaderNicknameIsUnknown() {
        let window = CGRect(x: 100, y: 50, width: 1300, height: 900)
        let chat = CGRect(x: 430, y: 50, width: 635, height: 900)
        let nodes = [
            node(1, role: "AXTextField", description: "联系人、订单号、聊天记录", value: "tb235692326486", frame: CGRect(x: 180, y: 180, width: 250, height: 40)),
            node(2, role: "AXStaticText", value: "完全不同的中文昵称", frame: CGRect(x: 470, y: 140, width: 220, height: 35)),
            node(3, role: "AXTextArea", value: "", frame: CGRect(x: 470, y: 760, width: 500, height: 140)),
        ]

        XCTAssertTrue(QianniuElementSelection.routedConversationMatches(
            uid: "tb235692326486", nodes: nodes, window: window, chatRegion: chat
        ))
        XCTAssertFalse(QianniuElementSelection.routedConversationMatches(
            uid: "another-user", nodes: nodes, window: window, chatRegion: chat
        ))
    }

    func testRoutedConversationAssessmentSeparatesWrongFromUnknown() {
        let window = CGRect(x: 100, y: 50, width: 1300, height: 900)
        let chat = CGRect(x: 430, y: 50, width: 635, height: 900)
        let input = node(3, role: "AXTextArea", value: "", frame: CGRect(x: 470, y: 760, width: 500, height: 140))
        let expectedSearch = node(1, role: "AXTextField", description: "联系人、订单号、聊天记录",
                                  value: "stoneshininger", frame: CGRect(x: 180, y: 180, width: 250, height: 40))
        let wrongSearch = node(1, role: "AXTextField", description: "联系人、订单号、聊天记录",
                               value: "another-user", frame: CGRect(x: 180, y: 180, width: 250, height: 40))

        XCTAssertEqual(QianniuElementSelection.routedConversationAssessment(
            uid: "stoneshininger", nodes: [expectedSearch, input], window: window, chatRegion: chat
        ), .confirmedCorrect)
        XCTAssertEqual(QianniuElementSelection.routedConversationAssessment(
            uid: "stoneshininger", nodes: [wrongSearch, input], window: window, chatRegion: chat
        ), .confirmedWrong("联系人搜索框显示了其他客户"))
        XCTAssertEqual(QianniuElementSelection.routedConversationAssessment(
            uid: "stoneshininger", nodes: [input], window: window, chatRegion: chat
        ), .unknown("当前会话身份不可读"))
    }

    func testMessageInputAndSendButtonMustBeUniqueAndNearChatBottom() {
        let chat = CGRect(x: 450, y: 100, width: 650, height: 850)
        let input = node(10, role: "AXTextArea", value: "", frame: CGRect(x: 470, y: 760, width: 500, height: 140))
        let nodes = [
            input,
            node(11, role: "AXTextField", value: "", frame: CGRect(x: 1200, y: 760, width: 300, height: 40)),
            node(12, role: "AXMenuButton", title: "发送", frame: CGRect(x: 990, y: 900, width: 90, height: 36)),
            node(13, role: "AXButton", title: "发送宝贝", frame: CGRect(x: 1200, y: 650, width: 100, height: 36)),
        ]

        let selectedInput = QianniuElementSelection.messageInput(nodes: nodes, chatRegion: chat)
        XCTAssertEqual(selectedInput?.id, 10)
        XCTAssertEqual(QianniuElementSelection.sendButton(nodes: nodes, input: input)?.id, 12)

        let ambiguous = nodes + [node(14, role: "AXTextArea", value: "", frame: input.frame)]
        XCTAssertNil(QianniuElementSelection.messageInput(nodes: ambiguous, chatRegion: chat))
    }

    func testActionableSendMenuButtonCannotFallBackToCoordinateClick() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let send = node(
            12,
            role: "AXMenuButton",
            title: "发送",
            frame: CGRect(x: 990, y: 820, width: 90, height: 36)
        )

        XCTAssertNil(QianniuElementSelection.interactionPoint(for: send, inside: window))
    }

    func testSendTriggerUsesOneReturnKeyForQianniuMenuButton() {
        let menuButton = node(
            12,
            role: "AXMenuButton",
            title: "发送",
            frame: CGRect(x: 990, y: 820, width: 90, height: 36)
        )
        let ordinaryButton = node(
            13,
            role: "AXButton",
            title: "发送",
            frame: CGRect(x: 990, y: 820, width: 90, height: 36)
        )

        XCTAssertEqual(QianniuElementSelection.sendTrigger(for: menuButton), .returnKeyOnce)
        XCTAssertEqual(QianniuElementSelection.sendTrigger(for: ordinaryButton), .accessibilityPress)
    }

    func testSearchResultUsesExactUIDInLeftConversationColumnAndDynamicCenter() {
        let window = CGRect(x: 133, y: 33, width: 1310, height: 888)
        let nodes = [
            node(1, role: "AXTextField", value: "stoneshishininger", frame: CGRect(x: 217, y: 185, width: 200, height: 30)),
            node(2, role: "AXGroup", value: "stoneshishininger", frame: CGRect(x: 197, y: 400, width: 240, height: 52)),
            node(3, role: "AXStaticText", value: "stoneshishininger", frame: CGRect(x: 700, y: 200, width: 200, height: 30)),
        ]

        let selected = QianniuElementSelection.searchResult(uid: "stoneshishininger", nodes: nodes, window: window)
        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected.flatMap { QianniuElementSelection.interactionPoint(for: $0, inside: window) }, CGPoint(x: 317, y: 426))
        XCTAssertNil(QianniuElementSelection.searchResult(uid: "stone", nodes: nodes, window: window))
    }

    func testSearchResultNeverTreatsPopulatedSearchFieldAsConversationResult() {
        let window = CGRect(x: 133, y: 33, width: 1310, height: 888)
        let populatedSearchField = node(
            1,
            role: "AXTextField",
            value: "tb263147182",
            frame: CGRect(x: 217, y: 185, width: 200, height: 30)
        )

        XCTAssertNil(
            QianniuElementSelection.searchResult(
                uid: "tb263147182",
                nodes: [populatedSearchField],
                window: window
            )
        )
    }

    func testSearchResultCanRouteBetweenFullAndTruncatedVisibleIdentity() {
        let window = CGRect(x: 133, y: 33, width: 1310, height: 888)
        let fullRow = node(1, role: "AXGroup", value: "stoneshininger",
                           frame: CGRect(x: 197, y: 400, width: 240, height: 52))
        let truncatedRow = node(2, role: "AXGroup", value: "stonesh...",
                                frame: CGRect(x: 197, y: 460, width: 240, height: 52))

        XCTAssertEqual(QianniuElementSelection.searchResult(uid: "stonesh...", nodes: [fullRow], window: window)?.id, 1)
        XCTAssertEqual(QianniuElementSelection.searchResult(uid: "stoneshininger", nodes: [truncatedRow], window: window)?.id, 2)
        XCTAssertNil(QianniuElementSelection.searchResult(uid: "shining...", nodes: [fullRow], window: window))
    }

    func testBlockingSendWarningRequiresTheQianniuRepeatMessageDialog() {
        let frame = CGRect(x: 200, y: 200, width: 500, height: 300)
        let warning = [
            node(1, role: "AXStaticText", value: "已向该消费者发送重复消息2次，继续发送可能引起消费者反感或差评，建议修改后发送", frame: frame),
            node(2, role: "AXButton", title: "返回修改", frame: CGRect(x: 300, y: 420, width: 100, height: 40)),
            node(3, role: "AXButton", title: "继续发送", frame: CGRect(x: 500, y: 420, width: 100, height: 40)),
        ]
        let ordinaryChat = [
            node(4, role: "AXStaticText", value: "客户说：继续发送图片", frame: frame),
            node(5, role: "AXButton", title: "返回", frame: CGRect(x: 300, y: 420, width: 100, height: 40)),
        ]

        XCTAssertTrue(QianniuElementSelection.hasBlockingRepeatMessageWarning(nodes: warning))
        XCTAssertFalse(QianniuElementSelection.hasBlockingRepeatMessageWarning(nodes: ordinaryChat))
        XCTAssertEqual(QianniuElementSelection.continueSendButtonForRepeatWarning(nodes: warning)?.id, 3)
        XCTAssertNil(QianniuElementSelection.continueSendButtonForRepeatWarning(nodes: ordinaryChat))
        XCTAssertEqual(QianniuElementSelection.repeatWarningWindowIndex(windowNodes: [ordinaryChat, warning]), 1)
    }

    func testVisibleRepeatWarningWindowUsesQianniuPIDAndServiceAttitudeTitle() {
        let windows = [
            SenderVisibleWindow(ownerPID: 900, title: "加普威旗舰店:小丹-接待中心"),
            SenderVisibleWindow(ownerPID: 901, title: "加普威旗舰店:小丹-服务态度提醒"),
            SenderVisibleWindow(ownerPID: 900, title: "加普威旗舰店:小丹-服务态度提醒"),
        ]

        XCTAssertEqual(
            QianniuElementSelection.repeatWarningWindow(windows: windows, qianniuPID: 900),
            windows[2]
        )
        XCTAssertNil(QianniuElementSelection.repeatWarningWindow(windows: windows, qianniuPID: 999))
        XCTAssertNil(QianniuElementSelection.repeatWarningWindow(
            windows: [SenderVisibleWindow(ownerPID: 900, title: "普通提醒")],
            qianniuPID: 900
        ))
    }

    func testRepeatWarningContinuePointMovesWithTheWarningWindow() {
        let first = SenderVisibleWindow(
            ownerPID: 900,
            title: "加普威旗舰店:小丹-服务态度提醒",
            frame: CGRect(x: 580, y: 360, width: 410, height: 230)
        )
        let moved = SenderVisibleWindow(
            ownerPID: 900,
            title: first.title,
            frame: CGRect(x: 180, y: 90, width: 410, height: 230)
        )

        let firstPoint = QianniuElementSelection.continueSendPointForRepeatWarning(window: first)
        let movedPoint = QianniuElementSelection.continueSendPointForRepeatWarning(window: moved)
        XCTAssertEqual(firstPoint, CGPoint(x: 916.2, y: 548.6))
        XCTAssertEqual(movedPoint, CGPoint(x: 516.2, y: 278.6))
        XCTAssertNil(QianniuElementSelection.continueSendPointForRepeatWarning(
            window: SenderVisibleWindow(ownerPID: 900, title: "普通窗口", frame: first.frame)
        ))
    }

    func testSendSuccessRequiresFiveConsecutiveClearChecksAndWarningResetsProgress() {
        var stability = SendVerificationStability(requiredConsecutiveChecks: 5)

        for _ in 0..<4 {
            XCTAssertFalse(stability.record(clearSuccessCandidate: true, warningVisible: false))
        }
        XCTAssertFalse(stability.record(clearSuccessCandidate: false, warningVisible: true))
        for _ in 0..<4 {
            XCTAssertFalse(stability.record(clearSuccessCandidate: true, warningVisible: false))
        }
        XCTAssertTrue(stability.record(clearSuccessCandidate: true, warningVisible: false))
    }

    private func node(
        _ id: Int,
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        frame: CGRect,
        enabled: Bool = true
    ) -> SenderAXNode {
        SenderAXNode(
            id: id,
            parentID: nil,
            role: role,
            title: title,
            description: description,
            value: value,
            frame: frame,
            isEnabled: enabled
        )
    }
}
