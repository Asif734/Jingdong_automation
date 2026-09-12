import XCTest
import CoreGraphics
@testable import UnreadCore

final class ProfileIdentityTests: XCTestCase {
    func testTruncatedPrefixIsRejectedWhenTwoVisibleRowsShareIt() {
        let policy = ConversationIdentityPolicy.default

        XCTAssertNil(policy.resolvePrefix(
            "stonesh...",
            visibleIdentities: ["stoneshishininger", "stoneshipping"]
        ))
        XCTAssertEqual(
            policy.resolvePrefix("stonesh...", visibleIdentities: ["stoneshishininger", "another"]),
            "stoneshishininger"
        )
    }

    let reception = "加普威旗舰店:小丹-接待中心"
    let rows = [ConversationRow(nodeID: 1, uid: "stoneshishininger", frame: .zero), ConversationRow(nodeID: 2, uid: "stoneshishinin-other", frame: .zero)]
    func testSamePrefixRowsAreRejectedBecausePostCloseTitleCannotProveContinuity() {
        XCTAssertNil(ConversationLocator.profileUID(profileTitle: "加普威旗舰店:小丹-stoneshishininger的资料", receptionTitle: reception, displayTitle: "stoneshishinin...", rows: rows))
    }
    func testFullProfileIdentityWithUniqueDisplayPrefix() {
        XCTAssertEqual(ConversationLocator.profileUID(profileTitle: "加普威旗舰店:小丹-stoneshishininger的资料", receptionTitle: reception, displayTitle: "stoneshishinin...", rows: [rows[0]]), "stoneshishininger")
    }
    func testArbitraryUnicodeAndHyphenUIDFromProfile() {
        let users = [ConversationRow(nodeID: 1, uid: "客户-A.42", frame: .zero)]
        XCTAssertEqual(ConversationLocator.profileUID(profileTitle: "加普威旗舰店:小丹-客户-A.42的资料", receptionTitle: reception, displayTitle: "客户…", rows: users), "客户-A.42")
    }
    func testFullNicknameUsesBoundNicknameInsteadOfOpeningProfile() {
        let users = [ConversationRow(nodeID: 1, uid: "tb235692326486", frame: .zero)]
        XCTAssertFalse(ConversationLocator.requiresProfileIdentity(displayTitle: "优满仓进出口农资"))
        XCTAssertNil(
            ConversationLocator.profileUID(
                profileTitle: "加普威旗舰店:小丹-tb235692326486的资料",
                receptionTitle: reception,
                displayTitle: "优满仓进出口农资",
                rows: users
            )
        )
    }
    func testWrongStoreTruncatedUnknownOrConflictingProfileIsRejected() {
        for title in ["其他店:小丹-stoneshishininger的资料", "加普威旗舰店:小丹-stoneshishinin...的资料", "加普威旗舰店:小丹-stoneshishinin-unknown的资料", "加普威旗舰店:小丹-stoneshishininger的资料-extra"] {
            XCTAssertNil(ConversationLocator.profileUID(profileTitle: title, receptionTitle: reception, displayTitle: "stoneshishinin...", rows: [rows[0]]))
        }
        XCTAssertNil(ConversationLocator.profileUID(profileTitle: "加普威旗舰店:小丹-stoneshishininger的资料", receptionTitle: reception, displayTitle: "tb263...", rows: [rows[0]]))
        XCTAssertNil(ConversationLocator.profileUID(profileTitle: "加普威旗舰店:小丹-stoneshishininger的资料", receptionTitle: reception, displayTitle: "...", rows: [rows[0]]))
    }
    func testProfileMustResolveExactlyOneFullAXRow() {
        XCTAssertNil(ConversationLocator.profileUID(profileTitle: "加普威旗舰店:小丹-stoneshishininger的资料", receptionTitle: reception, displayTitle: "stoneshishinin...", rows: rows + [rows[0]]))
    }

    func testChineseNicknameFallbackUsesEightyPercentSimilarity() {
        XCTAssertTrue(ConversationLocator.nicknameMatches(expected: "优满仓进出口农资", actual: "优满仓进出口农货"))
        XCTAssertTrue(ConversationLocator.identityMatches(expectedUID: "tb235692326486", expectedNickname: "优满仓进出口农资", actualHeader: "优满仓进出口农货"))
        XCTAssertFalse(ConversationLocator.identityMatches(expectedUID: "tb235692326486", expectedNickname: "优满仓进出口农资", actualHeader: "其他农资店"))
        XCTAssertFalse(ConversationLocator.nicknameMatches(expected: "小丹", actual: "小王"), "short nicknames must not pass on one differing character")
    }

    func testOnlyFullChineseHeaderCanBecomeTaskNickname() {
        XCTAssertEqual(ConversationLocator.chineseNickname(from: "优满仓进出口农资"), "优满仓进出口农资")
        XCTAssertEqual(ConversationLocator.chineseNickname(from: "  有满仓  "), "有满仓")
        XCTAssertNil(ConversationLocator.chineseNickname(from: "tb235692326486"))
        XCTAssertNil(ConversationLocator.chineseNickname(from: "优满仓..."))
        XCTAssertNil(ConversationLocator.chineseNickname(from: ""))
    }

    func testGeneralCustomerNicknameCanPersistEnglishButNeverTruncatedIdentity() {
        XCTAssertEqual(ConversationLocator.customerNickname(from: " stoneshininger "), "stoneshininger")
        XCTAssertEqual(ConversationLocator.customerNickname(from: "易美得旗舰店"), "易美得旗舰店")
        XCTAssertNil(ConversationLocator.customerNickname(from: "stonesh..."))
        XCTAssertNil(ConversationLocator.customerNickname(from: "[图片]"))
    }

    func testSuccessfulUIDNavigationRemainsTheRoutingIdentityWhenHeaderNicknameDiffers() {
        XCTAssertEqual(
            ConversationLocator.routedIdentity(expectedUID: "tb235692326486", openedUID: "tb235692326486"),
            "tb235692326486"
        )
        XCTAssertNil(ConversationLocator.routedIdentity(expectedUID: "tb235692326486", openedUID: "another-user"))
        XCTAssertNil(ConversationLocator.routedIdentity(expectedUID: "", openedUID: ""))
    }
}
