import XCTest
@testable import AutoReplyApp

final class LegacyCalibrationProviderTests: XCTestCase {
    func testLegacyProviderMarksExistingPathsWithoutClaimingAdaptiveCalibration() async throws {
        let provider = LegacyCalibrationProvider(probe: FakeLegacyProbe(
            receptionWindow: true,
            conversationList: true,
            composer: true
        ))

        let profile = try await provider.calibrate()

        XCTAssertEqual(profile.capabilities["receptionWindow"]?.level, .verified)
        XCTAssertEqual(profile.capabilities["conversationList"]?.strategy, "legacy-static-rules")
        XCTAssertEqual(profile.capabilities["composer"]?.level, .verified)
        XCTAssertNil(profile.endToEndPassedAt)
        XCTAssertNil(profile.readOnlyPassedAt)
    }

    func testMissingComposerDoesNotEraseOtherCapabilities() async throws {
        let profile = try await LegacyCalibrationProvider(probe: FakeLegacyProbe(
            receptionWindow: true,
            conversationList: true,
            composer: false
        )).calibrate()

        XCTAssertEqual(profile.capabilities["conversationList"]?.level, .verified)
        XCTAssertEqual(profile.capabilities["composer"]?.level, .unavailable)
    }
}

private struct FakeLegacyProbe: LegacyCapabilityProbing {
    let receptionWindow: Bool
    let conversationList: Bool
    let composer: Bool

    func receptionWindowAvailable() async -> Bool { receptionWindow }
    func conversationListAvailable() async -> Bool { conversationList }
    func composerAvailable() async -> Bool { composer }
}
