import XCTest
import AppKit
import QianniuOCRAppSupport
@testable import AutoReplyApp

/// Opt-in field test for the real Qianniu transfer popup. It is skipped during
/// normal CI because a successful run transfers the selected test customer.
@MainActor
final class LiveTransferGroupSmokeTests: XCTestCase {
    func testTransfersSelectedCustomerToFirstAvailableGroup() async throws {
        guard ProcessInfo.processInfo.environment["QIANNIU_LIVE_TRANSFER_SMOKE"] == "1" else {
            throw XCTSkip("Set QIANNIU_LIVE_TRANSFER_SMOKE=1 for the explicit field test")
        }
        let uid = try XCTUnwrap(ProcessInfo.processInfo.environment["QIANNIU_LIVE_TRANSFER_UID"])
        let root = RecordStorageLocation().runtimeRoot
        let schema = root.appendingPathComponent("运行状态/automatic-output.schema.json")
        let profileURL = root.appendingPathComponent("运行状态/自动配置/machine-compatibility.json")
        let profile = try JSONDecoder().decode(
            MachineCompatibilityProfile.self,
            from: Data(contentsOf: profileURL)
        )
        let ui = LiveNativeUI(
            root: root,
            safety: NativeSafety(schemaPath: schema.path),
            runtimeAdapter: AdaptiveRuntimeAdapter(profile: profile)
        )
        let lease = ui.leaseRegistry.acquire(uid: uid)

        try await ui.open(uid: uid, lease: lease)
        let openedUID = try await ui.header(lease: lease)
        XCTAssertEqual(openedUID, uid)
        try await ui.openTransferMenu(uid: uid, lease: lease)
    }

    func testRecognizesRealTransferPopupScreenshot() async throws {
        guard let path = ProcessInfo.processInfo.environment["QIANNIU_TRANSFER_POPUP_SCREENSHOT"] else {
            throw XCTSkip("Set QIANNIU_TRANSFER_POPUP_SCREENSHOT for the real-popup OCR test")
        }
        let image = try XCTUnwrap(NSImage(contentsOfFile: path))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let lines = try await LiveOCRRunner().recognizeText(in: cgImage)
        let points = TransferGroupCandidateSelection.clickPoints(
            lines: lines,
            imageSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
        print("TRANSFER_OCR_LINES=\(lines.map { $0.text })")
        print("TRANSFER_GROUP_POINTS=\(points)")
        XCTAssertFalse(points.isEmpty)
    }
}
