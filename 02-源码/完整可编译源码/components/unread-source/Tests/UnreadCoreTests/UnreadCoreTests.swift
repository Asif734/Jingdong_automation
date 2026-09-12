import CoreGraphics
import ImageIO
import XCTest
@testable import UnreadCore

final class UnreadCoreTests: XCTestCase {
    let window = CGRect(x: 0, y: 0, width: 1287, height: 768)
    func row(_ uid: String, _ y: CGFloat, id: Int = 10) -> ConversationRow {
        ConversationRow(nodeID: id, uid: uid, frame: CGRect(x: 64, y: y, width: 202, height: 44))
    }
    // Catches ignoring pixels, treating a global badge/timer as the row dot, or an inverted image.
    func testRealScreenshotRedDotOnly() throws {
        let image = try fixture("2026-08-26-105614-red-dot.jpeg")
        XCTAssertEqual(RedDotDetector.targets(image: image, window: window, rows: [row("tb263147182", 282), row("stoneshishininger", 330, id: 11)]).map(\.uid), ["tb263147182"])
    }
    func testRealNoDotAvatarAndGlobalBadgeAreExcluded() throws {
        let image = try fixture("2026-08-26-105941-no-red-dot.jpeg")
        XCTAssertEqual(RedDotDetector.targets(image: image, window: window, rows: [row("tb263147182", 282), row("stoneshishininger", 330, id: 11)]).map(\.uid), [])
    }
    // Catches fixed row number, fixed screen coordinates, and failure to map retina pixels.
    func testDotsOnRowsOneFiveTenAtTranslatedAndDoubleScale() {
        for scale in [1, 2] {
            for target in [0, 4, 9] {
                let origin = CGPoint(x: 700, y: 100)
                let frame = CGRect(origin: origin, size: window.size)
                let rows = (0..<10).map { i in ConversationRow(nodeID: i, uid: i == target ? "stoneshishininger" : "user-\(i)", frame: CGRect(x: 764, y: 250 + i * 44, width: 202, height: 44)) }
                let image = synthetic(scale: scale, dots: [(99, 160 + target * 44)])
                XCTAssertEqual(RedDotDetector.targets(image: image, window: frame, rows: rows).map(\.uid), ["stoneshishininger"])
            }
        }
    }
    func testMultipleDotsSortByScreenPositionNotArrayOrder() {
        let rows = [row("bottom", 546), row("top", 150), row("middle", 326)]
        XCTAssertEqual(RedDotDetector.targets(image: synthetic(dots: [(99, 160), (99, 336), (99, 556)]), window: window, rows: rows).map(\.uid), ["top", "middle", "bottom"])
    }
    func testAvatarTimerGlobalBadgeAndOversizeRedAreaExcluded() {
        var image = synthetic(dots: [(238, 160), (97, 185), (38, 186)])
        paint(&image, x: 82, y: 160, radius: 13) // orange/red avatar, not a small isolated corner dot
        XCTAssertTrue(RedDotDetector.targets(image: image, window: window, rows: [row("alice", 150)]).isEmpty)
    }
    func testCurrentQianniuDotAtTopEdgeOfTallerRowIsDetected() {
        let currentRow = ConversationRow(
            nodeID: 10,
            uid: "tb263147182",
            frame: CGRect(x: 64, y: 539, width: 240, height: 52)
        )
        let image = synthetic(dots: [(111, 543)])

        XCTAssertEqual(
            RedDotDetector.targets(image: image, window: window, rows: [currentRow]).map(\.uid),
            ["tb263147182"]
        )
    }
    // Catches UID-prefix assumptions, truncation acceptance, or arbitrary AXGroup classification.
    func testStructuralRowsPreserveFullArbitraryUID() throws {
        XCTAssertEqual(try ConversationLocator.rows(nodes: nodes(), window: window).map(\.uid), ["stoneshishininger", "中文-user.@_verylongidentity"])
    }
    func testRowsBindChineseNicknameToUnderlyingUIDAndCanFallBackToNickname() throws {
        var data = nodes()
        data.append(AXNode(id: 50, parent: 10, role: "AXStaticText", value: "优满仓进出口农资",
                           frame: CGRect(x: 112, y: 287, width: 135, height: 18)))
        data.append(AXNode(id: 51, parent: 11, role: "AXStaticText", value: "农机老李",
                           frame: CGRect(x: 112, y: 335, width: 90, height: 18)))
        data = data.map { node in
            if node.id == 10 { return AXNode(id: 10, parent: 3, role: "AXGroup", title: "tb235692326486", frame: node.frame) }
            if node.id == 11 { return AXNode(id: 11, parent: 3, role: "AXGroup", frame: node.frame) }
            return node
        }

        let rows = try ConversationLocator.rows(nodes: data, window: window)
        XCTAssertEqual(rows[0].uid, "tb235692326486")
        XCTAssertEqual(rows[0].nickname, "优满仓进出口农资")
        XCTAssertEqual(rows[1].uid, "农机老李")
        XCTAssertEqual(rows[1].nickname, "农机老李")
    }
    func testForcedNoStructuralUIDModeRoutesByVisibleNicknameOnly() throws {
        var data = nodes().map { node in
            node.id == 10
                ? AXNode(id: 10, parent: 3, role: "AXGroup", title: "tb999999", frame: node.frame)
                : node
        }
        data.append(AXNode(id: 50, parent: 10, role: "AXStaticText", value: "stoneshininger",
                           frame: CGRect(x: 112, y: 287, width: 125, height: 18)))

        let normal = try ConversationLocator.rows(nodes: data, window: window)
        let withoutStructuralUID = try ConversationLocator.rows(
            nodes: data,
            window: window,
            preferStructuralUID: false
        )

        XCTAssertEqual(normal[0].uid, "tb999999")
        XCTAssertEqual(normal.count, 2)
        XCTAssertEqual(withoutStructuralUID.count, 1)
        XCTAssertEqual(withoutStructuralUID[0].uid, "stoneshininger")
        XCTAssertEqual(withoutStructuralUID[0].nickname, "stoneshininger")
    }
    func testForcedNoStructuralUIDModeUsesFullRowLabelWhenQianniuSuppressesNicknameChildren() throws {
        let rows = try ConversationLocator.rows(
            nodes: nodes(),
            window: window,
            preferStructuralUID: false
        )

        XCTAssertEqual(rows.map(\.uid), ["stoneshishininger", "中文-user.@_verylongidentity"])
        XCTAssertEqual(rows.map(\.nickname), ["stoneshishininger", "中文-user.@_verylongidentity"])
    }
    func testRowsCanFallBackToFullEnglishNicknameWithoutUsingEnglishPreview() throws {
        var data = nodes().map { node in
            node.id == 10 ? AXNode(id: 10, parent: 3, role: "AXGroup", frame: node.frame) : node
        }
        data.append(AXNode(id: 50, parent: 10, role: "AXStaticText", value: "stoneshininger",
                           frame: CGRect(x: 112, y: 287, width: 125, height: 18)))
        data.append(AXNode(id: 51, parent: 10, role: "AXStaticText", value: "please help with my printer",
                           frame: CGRect(x: 112, y: 310, width: 145, height: 15)))

        let rows = try ConversationLocator.rows(nodes: data, window: window)

        XCTAssertEqual(rows[0].uid, "stoneshininger")
        XCTAssertEqual(rows[0].nickname, "stoneshininger")
    }
    func testEnglishNicknameFallbackAcceptsUsableTruncationButRejectsTooShortAndAmbiguousTopLabels() throws {
        var usable = nodes().map { node in
            node.id == 10 ? AXNode(id: 10, parent: 3, role: "AXGroup", frame: node.frame) : node
        }
        usable.append(AXNode(id: 50, parent: 10, role: "AXStaticText", value: "stonesh...",
                             frame: CGRect(x: 112, y: 287, width: 125, height: 18)))
        let rows = try ConversationLocator.rows(nodes: usable, window: window)
        XCTAssertEqual(rows[0].uid, "stonesh...")
        XCTAssertEqual(rows[0].nickname, "stonesh...")

        for labels in [["sto..."], ["stoneshininger", "another-user"]] {
            var data = nodes().map { node in
                node.id == 10 ? AXNode(id: 10, parent: 3, role: "AXGroup", frame: node.frame) : node
            }
            for (offset, label) in labels.enumerated() {
                data.append(AXNode(id: 50 + offset, parent: 10, role: "AXStaticText", value: label,
                                   frame: CGRect(x: 112, y: 287, width: 125, height: 18)))
            }
            let candidates = try ConversationLocator.candidates(nodes: data, window: window)
            XCTAssertNil(candidates.first?.identity.resolved)
            XCTAssertEqual(candidates.dropFirst().compactMap(\.identity.resolved), ["中文-user.@_verylongidentity"])
        }
    }
    func testEnglishNicknameFallbackIgnoresTopTimerAndStatusLabels() throws {
        var data = nodes().map { node in
            node.id == 10 ? AXNode(id: 10, parent: 3, role: "AXGroup", frame: node.frame) : node
        }
        data.append(AXNode(id: 50, parent: 10, role: "AXStaticText", value: "stoneshininger",
                           frame: CGRect(x: 112, y: 287, width: 125, height: 18)))
        data.append(AXNode(id: 51, parent: 10, role: "AXStaticText", value: "4秒",
                           frame: CGRect(x: 225, y: 287, width: 30, height: 18)))
        data.append(AXNode(id: 52, parent: 10, role: "AXStaticText", value: "未读",
                           frame: CGRect(x: 225, y: 287, width: 30, height: 18)))

        let rows = try ConversationLocator.rows(nodes: data, window: window)

        XCTAssertEqual(rows[0].uid, "stoneshininger")
    }
    func testOnlyTopNicknameRegionIsEligibleForSelectiveAXReading() {
        let row = AXNode(id: 10, role: "AXGroup", frame: CGRect(x: 64, y: 282, width: 202, height: 44))
        let nickname = AXNode(id: 50, parent: 10, role: "AXStaticText", frame: CGRect(x: 112, y: 287, width: 125, height: 18))
        let preview = AXNode(id: 51, parent: 10, role: "AXStaticText", frame: CGRect(x: 112, y: 310, width: 145, height: 15))
        let farRightControl = AXNode(id: 52, parent: 10, role: "AXStaticText", frame: CGRect(x: 230, y: 287, width: 30, height: 18))

        XCTAssertTrue(ConversationLocator.isPotentialNicknameNode(nickname, in: row))
        XCTAssertFalse(ConversationLocator.isPotentialNicknameNode(preview, in: row))
        XCTAssertFalse(ConversationLocator.isPotentialNicknameNode(farRightControl, in: row))
    }
    // Catches treating arbitrary preview text as an image or taking `[图片]`
    // from outside the exact conversation row.
    func testOnlyExactImageMarkerDescendantMarksThatConversationRow() throws {
        var data = nodes()
        data.append(AXNode(id: 40, parent: 10, role: "AXStaticText", value: "[图片]",
                           frame: CGRect(x: 115, y: 310, width: 48, height: 15)))
        data.append(AXNode(id: 41, parent: 11, role: "AXStaticText", value: "[图片]处理中",
                           frame: CGRect(x: 115, y: 358, width: 90, height: 15)))
        data.append(AXNode(id: 42, parent: 20, role: "AXStaticText", value: "[图片]",
                           frame: CGRect(x: 315, y: 115, width: 48, height: 15)))

        let rows = try ConversationLocator.rows(nodes: data, window: window)

        XCTAssertEqual(rows.map(\.uid), ["stoneshishininger", "中文-user.@_verylongidentity"])
        XCTAssertEqual(rows.map(\.latestPreviewIsImage), [true, false])
    }
    // The current chat's display title must not gate discovery of unrelated left-list users.
    func testUsableTruncatedCurrentTitleCanVerifyWithoutBlockingLeftList() throws {
        let data = nodes().map { node in
            node.id == 21 ? AXNode(id: node.id, parent: node.parent, role: node.role, value: "stoneshishinin...", frame: node.frame) : node
        }
        XCTAssertEqual(try ConversationLocator.rows(nodes: data, window: window).map(\.uid), ["stoneshishininger", "中文-user.@_verylongidentity"])
        XCTAssertEqual(ConversationLocator.header(nodes: data, window: window), "stoneshishinin...")
    }
    func testLeftListWorksWithoutChatHeaderAndAfterWindowMoves() throws {
        let offset = CGSize(width: 540, height: 170)
        let data = nodes().filter { $0.id < 20 }.map { node in
            AXNode(id: node.id, parent: node.parent, role: node.role, title: node.title, value: node.value, description: node.description, frame: node.frame.offsetBy(dx: offset.width, dy: offset.height))
        }
        let rows = try ConversationLocator.rows(nodes: data, window: window.offsetBy(dx: offset.width, dy: offset.height))
        XCTAssertEqual(rows.map(\.uid), ["stoneshishininger", "中文-user.@_verylongidentity"])
        XCTAssertEqual(rows.first?.frame.minX, 604)
    }
    func testMissingStructuralAnchorIsExplicitFailure() {
        XCTAssertThrowsError(try ConversationLocator.rows(nodes: nodes().filter { $0.id != 2 }, window: window))
    }
    func testTruncatedAndAmbiguousUIDsAreIsolatedPerRow() throws {
        var data = nodes()
        data.append(AXNode(id: 12, parent: 3, role: "AXGroup", title: "truncated...", frame: CGRect(x: 64, y: 400, width: 202, height: 44)))
        data.append(AXNode(id: 13, parent: 3, role: "AXGroup", title: "alice", description: "bob", frame: CGRect(x: 64, y: 450, width: 202, height: 44)))
        let candidates = try ConversationLocator.candidates(nodes: data, window: window)
        XCTAssertEqual(candidates[2].identity.resolved, "truncated...")
        XCTAssertNil(candidates[3].identity.resolved)
        XCTAssertEqual(candidates.prefix(2).compactMap(\.identity.resolved), ["stoneshishininger", "中文-user.@_verylongidentity"])
    }
    // Dot detection happens before identity admission, so an uncertain row cannot
    // hide unrelated valid customers or be reported as "no unread".
    func testMixedValidAndAmbiguousRowWithOnlyDotOnAmbiguousRowIsReturnedUnresolved() {
        let data = nodes().map { node in
            node.id == 11 ? AXNode(id: 11, parent: 3, role: "AXGroup", title: "alice", description: "bob", frame: node.frame) : node
        }
        assertUnresolvedListDot(nodes: data, dotY: 340, rowY: 330)
    }
    func testMixedValidAndUsableTruncatedRowCanBeDetected() throws {
        let data = nodes().map { node in
            node.id == 11 ? AXNode(id: 11, parent: 3, role: "AXGroup", title: "truncated...", frame: node.frame) : node
        }
        let rows = try ConversationLocator.rows(nodes: data, window: window)
        XCTAssertEqual(rows.map(\.uid), ["stoneshishininger", "truncated..."])
        XCTAssertEqual(RedDotDetector.targets(image: synthetic(dots: [(99, 340)]), window: window, rows: rows).map(\.uid), ["truncated..."])
    }
    func testMixedValidAndDuplicateRowsWithOnlyDotOnDuplicateRowIsReturnedUnresolved() {
        var data = nodes()
        data.append(AXNode(id: 12, parent: 3, role: "AXGroup", title: "中文-user.@_verylongidentity", frame: CGRect(x: 64, y: 400, width: 202, height: 44)))
        assertUnresolvedListDot(nodes: data, dotY: 410, rowY: 400)
    }
    private func assertUnresolvedListDot(nodes: [AXNode], dotY: Int, rowY: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let image = synthetic(dots: [(99, dotY)])
        XCTAssertEqual(RedDotDetector.targets(image: image, window: window, rows: [row("fixture-target", rowY)]).map(\.uid), ["fixture-target"], file: file, line: line)
        do {
            let targets = RedDotDetector.targets(image: image, window: window,
                                                  candidates: try ConversationLocator.candidates(nodes: nodes, window: window))
            XCTAssertEqual(targets.count, 1, file: file, line: line)
            XCTAssertNil(targets.first?.identity.resolved, file: file, line: line)
        } catch {
            XCTFail("candidate discovery must isolate the malformed row: \(error)", file: file, line: line)
        }
    }
    func testFreshUIDFollowsReorderAndDisappearanceIsSafe() {
        XCTAssertEqual(ConversationLocator.fresh(uid: "alice", rows: [row("bob", 250), row("alice", 650)])?.frame.minY, 650)
        XCTAssertNil(ConversationLocator.fresh(uid: "missing", rows: [row("alice", 250)]))
        XCTAssertNil(ConversationLocator.fresh(uid: "alice", rows: [row("alice", 250), row("alice", 300)]))
    }
    func testOnlyAmbiguousRowsMustNotClaimNoUnread() {
        let data = nodes().map { node in
            if node.id == 11 { return AXNode(id: 11, parent: 3, role: "AXGroup", title: "stoneshishininger", frame: node.frame) }
            return node
        }
        XCTAssertThrowsError(try ConversationLocator.rows(nodes: data, window: window))
    }
    func testChildOutsideItsListContainerIsExcluded() throws {
        var data = nodes()
        data.append(AXNode(id: 12, parent: 3, role: "AXGroup", title: "outside", frame: CGRect(x: 0, y: 400, width: 202, height: 44)))
        XCTAssertEqual(try ConversationLocator.rows(nodes: data, window: window).map(\.uid), ["stoneshishininger", "中文-user.@_verylongidentity"])
    }
    func testHeaderVerificationRequiresExactFullIdentity() {
        XCTAssertTrue(ConversationLocator.verified(expected: "alice", actual: "alice"))
        XCTAssertFalse(ConversationLocator.verified(expected: "alice", actual: "bob"))
        XCTAssertTrue(ConversationLocator.verified(expected: "stoneshininger", actual: "stonesh..."))
        XCTAssertTrue(ConversationLocator.verified(expected: "stonesh...", actual: "stoneshininger"))
        XCTAssertTrue(ConversationLocator.verified(expected: "易美…", actual: "易美得旗舰店"))
        XCTAssertFalse(ConversationLocator.verified(expected: "stoneshininger", actual: "sto..."))
        XCTAssertFalse(ConversationLocator.verified(expected: "stoneshininger", actual: "shining..."))
        XCTAssertFalse(ConversationLocator.verified(expected: "", actual: ""))
        XCTAssertEqual(ConversationLocator.header(nodes: nodes(), window: window), "alice")
    }
    func nodes() -> [AXNode] {
        [AXNode(id: 0, role: "AXWindow", frame: window),
         AXNode(id: 1, parent: 0, role: "AXGroup", frame: CGRect(x: 58, y: 170, width: 212, height: 590)),
         AXNode(id: 2, parent: 1, role: "AXCheckBox", title: "正在接待买家列表", frame: CGRect(x: 74, y: 240, width: 100, height: 30)),
         AXNode(id: 3, parent: 1, role: "AXGroup", frame: CGRect(x: 64, y: 280, width: 202, height: 480)),
         AXNode(id: 10, parent: 3, role: "AXGroup", title: "stoneshishininger", frame: CGRect(x: 64, y: 282, width: 202, height: 44)),
         AXNode(id: 11, parent: 3, role: "AXGroup", title: "中文-user.@_verylongidentity", frame: CGRect(x: 64, y: 330, width: 202, height: 44)),
         AXNode(id: 20, parent: 0, role: "AXGroup", frame: CGRect(x: 270, y: 86, width: 580, height: 42)),
         AXNode(id: 21, parent: 20, role: "AXStaticText", value: "alice", frame: CGRect(x: 315, y: 96, width: 150, height: 22)),
         AXNode(id: 22, parent: 20, role: "AXButton", title: "转发当前用户", frame: CGRect(x: 750, y: 96, width: 24, height: 22)),
         AXNode(id: 23, parent: 20, role: "AXButton", title: "新建任务", frame: CGRect(x: 786, y: 96, width: 24, height: 22)),
         AXNode(id: 30, parent: 0, role: "AXGroup", title: "unrelated", frame: CGRect(x: 64, y: 500, width: 202, height: 44))]
    }
    func fixture(_ name: String) throws -> PixelImage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("evidence/\(name)") as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return PixelImage(width: cg.width, height: cg.height, rgba: bytes)
    }
    func synthetic(scale: Int = 1, dots: [(Int, Int)]) -> PixelImage {
        var image = PixelImage(width: 1287 * scale, height: 768 * scale, rgba: [UInt8](repeating: 255, count: 1287 * 768 * scale * scale * 4))
        for (x, y) in dots { paint(&image, x: x * scale, y: y * scale, radius: 3 * scale) }
        return image
    }
    func paint(_ image: inout PixelImage, x: Int, y: Int, radius: Int) {
        var pixels = image.rgba
        for py in max(0, y - radius)...min(image.height - 1, y + radius) {
            for px in max(0, x - radius)...min(image.width - 1, x + radius) where (px-x)*(px-x)+(py-y)*(py-y) <= radius*radius {
                let i = (py * image.width + px) * 4
                pixels[i] = 245; pixels[i+1] = 20; pixels[i+2] = 25
            }
        }
        image = PixelImage(width: image.width, height: image.height, rgba: pixels)
    }
}
