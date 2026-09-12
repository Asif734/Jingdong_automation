import CoreGraphics
import XCTest
import UnreadCore
@testable import AutoReplyApp

final class IdentityCalibrationTests: XCTestCase {
    func testFullContainerUIDWinsOverNicknameAndOCR() {
        let policy = ConversationIdentityPolicy.availableSources(
            containerTitle: true,
            childNickname: true,
            header: true,
            ocr: true
        )

        XCTAssertEqual(policy.orderedSources.first, .containerTitle)
        XCTAssertEqual(policy.orderedSources.last, .ocrNickname)
    }

    func testCalibrationUsesOnlySourcesObservedOnThisMachine() {
        let snapshot = CalibrationSnapshot(
            macOSBuild: "25G83",
            architecture: "arm64",
            qianniuVersion: "9.97.74",
            qianniuBuild: "1",
            qianniuRuntimeArchitecture: "arm64",
            displays: [CalibrationDisplay(relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 2)],
            windows: [],
            nodes: [
                CalibrationAXNode(id: 1, parentID: nil, role: "AXGroup", actionNames: [], labelCategory: "identity-like", relativeFrame: .zero, hasValue: true)
            ]
        )

        let policy = IdentityCalibration.calibrate(snapshot: snapshot, ocrAvailable: true)

        XCTAssertEqual(policy.orderedSources, [.containerTitle, .uniquePrefix, .ocrNickname])
    }
}
