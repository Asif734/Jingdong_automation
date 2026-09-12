import XCTest
@testable import AutoReplyApp

final class CustomerNicknameRegistryTests: XCTestCase {
    func testFirstNicknamePersistsAndRenameRequiresTwoMatchingObservations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nickname-registry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("identity-map.json")
        var registry = CustomerNicknameRegistry(url: url)

        try registry.observe(scope: "加普威旗舰店:小丹", uid: "tb235692326486", nickname: "优满仓进出口农资")
        XCTAssertEqual(registry.nickname(scope: "加普威旗舰店:小丹", uid: "tb235692326486"), "优满仓进出口农资")

        try registry.observe(scope: "加普威旗舰店:小丹", uid: "tb235692326486", nickname: "优满仓新名称")
        XCTAssertEqual(registry.nickname(scope: "加普威旗舰店:小丹", uid: "tb235692326486"), "优满仓进出口农资")
        try registry.observe(scope: "加普威旗舰店:小丹", uid: "tb235692326486", nickname: "优满仓新名称")
        XCTAssertEqual(registry.nickname(scope: "加普威旗舰店:小丹", uid: "tb235692326486"), "优满仓新名称")

        let restored = CustomerNicknameRegistry(url: url)
        XCTAssertEqual(restored.nickname(scope: "加普威旗舰店:小丹", uid: "tb235692326486"), "优满仓新名称")
        XCTAssertNil(restored.nickname(scope: "格志旗舰店:小丹", uid: "tb235692326486"))
    }

    func testEnglishNicknamePersistsInsideOnlyItsReceptionAccountScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nickname-registry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = CustomerNicknameRegistry(url: root.appendingPathComponent("identity-map.json"))

        try registry.observe(scope: "加普威旗舰店:苏苏", uid: "stonesh...", nickname: "stoneshininger")
        try registry.observe(scope: "加普威旗舰店:苏苏", uid: "truncated...", nickname: "truncated...")

        XCTAssertEqual(registry.nickname(scope: "加普威旗舰店:苏苏", uid: "stonesh..."), "stoneshininger")
        XCTAssertNil(registry.nickname(scope: "加普威旗舰店:小丹", uid: "stonesh..."))
        XCTAssertNil(registry.nickname(scope: "加普威旗舰店:苏苏", uid: "truncated..."), "truncated text is never persisted as a full identity")
    }
}
