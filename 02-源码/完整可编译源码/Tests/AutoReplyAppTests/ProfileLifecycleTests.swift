import CoreGraphics
import QianniuOCRCore
import QianniuSenderCore
import UnreadCore
import XCTest
@testable import AutoReplyApp

final class ProfileLifecycleTests: XCTestCase {
    func testMatchingFingerprintReusesCurrentProfile() async throws {
        let root = temporaryDirectory()
        let snapshot = CalibrationSnapshot.lifecycleFixture(scale: 2)
        let profile = MachineCompatibilityProfile.lifecycleFixture(snapshot: snapshot)
        let lifecycle = ProfileLifecycle(
            store: AtomicJSONStore(root: root, stem: "machine"),
            current: profile,
            calibrate: { profile }
        )

        let decision = try await lifecycle.validateQuickly(snapshot: snapshot)
        XCTAssertEqual(decision, .reuseCurrent)
    }

    func testDisplayChangeRecalibratesCoordinateCapabilityOnly() async throws {
        let root = temporaryDirectory()
        let original = CalibrationSnapshot.lifecycleFixture(scale: 2)
        let changed = CalibrationSnapshot.lifecycleFixture(scale: 1)
        let lifecycle = ProfileLifecycle(
            store: AtomicJSONStore(root: root, stem: "machine"),
            current: .lifecycleFixture(snapshot: original),
            calibrate: { .lifecycleFixture(snapshot: changed) }
        )

        let decision = try await lifecycle.validateQuickly(snapshot: changed)
        XCTAssertEqual(decision, .recalibrate(capabilities: ["coordinateMapping"]))
    }

    func testTwoFailuresRecalibrateOnlyThatCapability() async throws {
        let root = temporaryDirectory()
        let snapshot = CalibrationSnapshot.lifecycleFixture(scale: 2)
        let lifecycle = ProfileLifecycle(
            store: AtomicJSONStore(root: root, stem: "machine"),
            current: .lifecycleFixture(snapshot: snapshot),
            calibrate: { .lifecycleFixture(snapshot: snapshot) }
        )

        let first = await lifecycle.recordFailure(capability: "composer")
        let second = await lifecycle.recordFailure(capability: "composer")
        XCTAssertEqual(first, .reuseCurrent)
        XCTAssertEqual(second, .recalibrate(capabilities: ["composer"]))
    }

    func testRejectedCandidateKeepsLastKnownGood() async throws {
        let root = temporaryDirectory()
        let snapshot = CalibrationSnapshot.lifecycleFixture(scale: 2)
        let original = MachineCompatibilityProfile.lifecycleFixture(snapshot: snapshot)
        let store = AtomicJSONStore<MachineCompatibilityProfile>(root: root, stem: "machine")
        try store.saveCandidate(original) { _ in true }
        let lifecycle = ProfileLifecycle(
            store: store,
            current: original,
            candidateValidation: { _ in false },
            calibrate: { .lifecycleFixture(snapshot: snapshot) }
        )

        do {
            try await lifecycle.recalibrate(["composer"])
            XCTFail("candidate validation should fail")
        } catch {
            XCTAssertNotNil(error)
        }

        let current = await lifecycle.currentProfile
        XCTAssertEqual(current.profileID, original.profileID)
        XCTAssertEqual(try store.load()?.profileID, original.profileID)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-lifecycle-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private extension CalibrationSnapshot {
    static func lifecycleFixture(scale: Double) -> CalibrationSnapshot {
        CalibrationSnapshot(
            macOSBuild: "25G83",
            architecture: "arm64",
            qianniuVersion: "9.97.74",
            qianniuBuild: "20260812105806",
            qianniuRuntimeArchitecture: "arm64",
            displays: [CalibrationDisplay(relativeFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: scale)],
            windows: [CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 20, y: 40, width: 1200, height: 800),
                captureFrame: CGRect(x: 20, y: 40, width: 1200, height: 800),
                minimized: false,
                focused: true,
                regionCategories: ["conversation-list", "chat", "composer"]
            )],
            nodes: [CalibrationAXNode(
                id: 1,
                parentID: nil,
                role: "AXGroup",
                actionNames: ["AXPress"],
                labelCategory: "identity-like",
                relativeFrame: CGRect(x: 0.02, y: 0.15, width: 0.28, height: 0.065),
                hasValue: true
            )]
        )
    }
}

private extension MachineCompatibilityProfile {
    static func lifecycleFixture(snapshot: CalibrationSnapshot) -> MachineCompatibilityProfile {
        let fingerprint = EnvironmentFingerprint.make(from: snapshot)
        return MachineCompatibilityProfile(
            profileID: UUID(),
            fingerprintDigest: fingerprint.digest,
            capabilities: ["composer": CapabilityStatus(level: .verified, strategy: "ax", detail: "ok")],
            readOnlyPassedAt: Date(),
            endToEndPassedAt: nil,
            environmentFingerprint: fingerprint,
            windowPolicy: WindowSelectionPolicy(
                selectedWindowRole: "reception",
                requiredTitleTokens: ["接待中心"],
                minimumRelativeSize: CGSize(width: 500, height: 300),
                requiredRegions: ["conversation-list", "chat", "composer"],
                coordinateMapping: CoordinateMapping(pointsToPixelsX: 1, pointsToPixelsY: 1, originOffsetX: 0, originOffsetY: 0, maximumResidual: 3)
            ),
            conversationListPolicy: .legacy,
            identityPolicy: .default,
            capturePolicy: CaptureSelectionPolicy(relativeMessageRect: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.7)),
            composerPolicy: ComposerSelectionPolicy(acceptedRoles: ["AXTextArea"], relativeRegion: CGRect(x: 0, y: 0.6, width: 1, height: 0.4), fallback: SendFallbackPolicy(relativeClickPoint: nil)),
            sendPolicy: .returnKeyOnce
        )
    }
}
