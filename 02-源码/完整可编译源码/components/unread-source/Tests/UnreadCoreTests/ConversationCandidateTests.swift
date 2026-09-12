import CoreGraphics
import XCTest
@testable import UnreadCore

final class ConversationCandidateTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1287, height: 768)

    func testColleagueABlankSectionHeaderIsNotAConversationCandidate() throws {
        let candidates = try ConversationLocator.candidates(nodes: colleagueANodes(), window: window)
        let dotted = RedDotDetector.targets(
            image: imageWithDots([(99, 420)]),
            window: window,
            candidates: candidates
        )

        XCTAssertEqual(candidates.map(\.nodeID), [11, 12])
        XCTAssertEqual(dotted.compactMap(\.identity.resolved), ["tb263147182"])
    }

    func testColleagueBInterleavedBlankSectionHeadersAreNotConversationCandidates() throws {
        let candidates = try ConversationLocator.candidates(nodes: colleagueBNodes(), window: window)

        XCTAssertEqual(candidates.map(\.nodeID), [11, 13])
        XCTAssertEqual(candidates.compactMap(\.identity.resolved), ["tb263147182", "易美得旗舰店"])
    }

    func testRedPixelsOverBlankSectionHeaderCannotCreatePendingIdentity() throws {
        let candidates = try ConversationLocator.candidates(nodes: colleagueANodes(), window: window)
        let dotted = RedDotDetector.targets(
            image: imageWithDots([(89, 385), (99, 420)]),
            window: window,
            candidates: candidates
        )

        XCTAssertEqual(dotted.map(\.nodeID), [11])
        XCTAssertEqual(dotted.compactMap(\.identity.resolved), ["tb263147182"])
    }

    func testNormalHeightUnresolvedRowRemainsCandidate() throws {
        var nodes = colleagueANodes()
        nodes[4] = AXNode(id: 10, parent: 3, role: "AXGroup",
                         frame: CGRect(x: 64, y: 373, width: 202, height: 52))

        let candidates = try ConversationLocator.candidates(nodes: nodes, window: window)

        XCTAssertEqual(candidates.map(\.nodeID), [10, 11, 12])
        XCTAssertNil(candidates[0].identity.resolved)
    }

    func testBlankRowsAreNotDiscardedWithoutAResolvedSiblingHeightReference() throws {
        var nodes = colleagueANodes()
        nodes.removeLast(2)

        let candidates = try ConversationLocator.candidates(nodes: nodes, window: window)

        XCTAssertEqual(candidates.map(\.nodeID), [10])
        XCTAssertNil(candidates[0].identity.resolved)
    }

    func testDuplicateIdentityOnlyUnresolvesThoseRows() throws {
        var nodes = colleagueANodes()
        nodes[6] = AXNode(id: 12, parent: 3, role: "AXGroup", title: "tb263147182",
                         frame: CGRect(x: 64, y: 459, width: 202, height: 52))
        nodes.append(AXNode(id: 13, parent: 3, role: "AXGroup", title: "independent-customer",
                            frame: CGRect(x: 64, y: 511, width: 202, height: 52)))

        let candidates = try ConversationLocator.candidates(nodes: nodes, window: window)

        XCTAssertNil(candidates[0].identity.resolved)
        XCTAssertNil(candidates[1].identity.resolved)
        XCTAssertEqual(candidates[2].identity.resolved, "independent-customer")
    }

    func testRedDotFreshnessIgnoresUnrelatedCandidateAndNodeIDChanges() {
        let dotted = ConversationCandidate(
            nodeID: 91,
            frame: CGRect(x: 64, y: 407, width: 202, height: 52),
            identity: .full(uid: "tb263147182", nickname: nil)
        )
        let captured = SceneSnapshot(
            windowID: 336,
            frame: window,
            candidates: [
                ConversationCandidate(nodeID: 90, frame: CGRect(x: 64, y: 373, width: 202, height: 34),
                                      identity: .unresolved(labels: [])),
                dotted
            ]
        )
        let fresh = SceneSnapshot(
            windowID: 336,
            frame: window,
            candidates: [
                ConversationCandidate(nodeID: 117, frame: CGRect(x: 64, y: 407, width: 202, height: 52),
                                      identity: .full(uid: "tb263147182", nickname: nil))
            ]
        )

        let confirmed = SceneFreshness.confirmed(dotted: [dotted], captured: captured, fresh: fresh)
        XCTAssertEqual(confirmed?.compactMap(\.identity.resolved), ["tb263147182"])
    }

    func testRedDotFreshnessRejectsMovedWindowOrMissingTarget() {
        let dotted = ConversationCandidate(
            nodeID: 11,
            frame: CGRect(x: 64, y: 407, width: 202, height: 52),
            identity: .full(uid: "tb263147182", nickname: nil)
        )
        let captured = SceneSnapshot(windowID: 336, frame: window, candidates: [dotted])
        let moved = SceneSnapshot(windowID: 336, frame: window.offsetBy(dx: 10, dy: 0), candidates: [dotted])
        let missing = SceneSnapshot(windowID: 336, frame: window, candidates: [])

        XCTAssertNil(SceneFreshness.confirmed(dotted: [dotted], captured: captured, fresh: moved))
        XCTAssertEqual(SceneFreshness.confirmed(dotted: [dotted], captured: captured, fresh: missing), [])
    }

    private func colleagueANodes() -> [AXNode] {
        [
            AXNode(id: 0, role: "AXWindow", frame: window),
            AXNode(id: 1, parent: 0, role: "AXGroup", frame: CGRect(x: 58, y: 170, width: 212, height: 590)),
            AXNode(id: 2, parent: 1, role: "AXCheckBox", title: "正在接待买家列表", frame: CGRect(x: 74, y: 240, width: 100, height: 30)),
            AXNode(id: 3, parent: 1, role: "AXGroup", frame: CGRect(x: 64, y: 280, width: 202, height: 480)),
            AXNode(id: 10, parent: 3, role: "AXGroup", frame: CGRect(x: 64, y: 373, width: 202, height: 34)),
            AXNode(id: 11, parent: 3, role: "AXGroup", title: "tb263147182",
                   frame: CGRect(x: 64, y: 407, width: 202, height: 52)),
            AXNode(id: 12, parent: 3, role: "AXGroup", title: "stoneshishininger",
                   frame: CGRect(x: 64, y: 459, width: 202, height: 52))
        ]
    }

    private func colleagueBNodes() -> [AXNode] {
        [
            AXNode(id: 0, role: "AXWindow", frame: window),
            AXNode(id: 1, parent: 0, role: "AXGroup", frame: CGRect(x: 58, y: 170, width: 212, height: 590)),
            AXNode(id: 2, parent: 1, role: "AXCheckBox", title: "正在接待买家列表", frame: CGRect(x: 74, y: 240, width: 100, height: 30)),
            AXNode(id: 3, parent: 1, role: "AXGroup", frame: CGRect(x: 64, y: 280, width: 202, height: 480)),
            AXNode(id: 10, parent: 3, role: "AXGroup", frame: CGRect(x: 64, y: 382, width: 202, height: 34)),
            AXNode(id: 11, parent: 3, role: "AXGroup", title: "tb263147182",
                   frame: CGRect(x: 64, y: 416, width: 202, height: 52)),
            AXNode(id: 12, parent: 3, role: "AXGroup", frame: CGRect(x: 64, y: 468, width: 202, height: 34)),
            AXNode(id: 13, parent: 3, role: "AXGroup", title: "易美得旗舰店",
                   frame: CGRect(x: 64, y: 502, width: 202, height: 52))
        ]
    }

    private func imageWithDots(_ dots: [(Int, Int)]) -> PixelImage {
        let width = Int(window.width), height = Int(window.height)
        var rgba = Array(repeating: UInt8(255), count: width * height * 4)
        for (cx, cy) in dots {
            for y in (cy - 3)...(cy + 3) {
                for x in (cx - 3)...(cx + 3) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= 9 {
                    let index = (y * width + x) * 4
                    rgba[index] = 235
                    rgba[index + 1] = 30
                    rgba[index + 2] = 45
                    rgba[index + 3] = 255
                }
            }
        }
        return PixelImage(width: width, height: height, rgba: rgba)
    }
}
