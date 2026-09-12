import XCTest
@testable import AutoReplyApp

final class AutoconfigurationStoreTests: XCTestCase {
    func testCandidateBecomesCurrentOnlyAfterValidation() throws {
        let root = temporaryDirectory()
        let store = AtomicJSONStore<OperatorConfig>(root: root, stem: "operator")
        let value = OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)

        try store.saveCandidate(value) { $0.serviceAliases == ["小甘"] }

        XCTAssertEqual(try store.load(), value)
        XCTAssertEqual(try store.loadLastKnownGood(), value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.candidateURL.path))
    }

    func testRejectedCandidatePreservesLastKnownGood() throws {
        let root = temporaryDirectory()
        let store = AtomicJSONStore<OperatorConfig>(root: root, stem: "operator")
        let good = OperatorConfig(serviceAliases: ["苏苏"], autoStartWhenReady: true)
        try store.saveCandidate(good) { _ in true }

        XCTAssertThrowsError(try store.saveCandidate(
            OperatorConfig(serviceAliases: [], autoStartWhenReady: true),
            validate: { !$0.serviceAliases.isEmpty }
        ))

        XCTAssertEqual(try store.load(), good)
        XCTAssertEqual(try store.loadLastKnownGood(), good)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.candidateURL.path))
    }

    func testCompatibilityProfileEncodingContainsNoCustomerFields() throws {
        let data = try JSONEncoder().encode(MachineCompatibilityProfile.empty)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("customerUID"))
        XCTAssertFalse(text.contains("customerNickname"))
        XCTAssertFalse(text.contains("screenshot"))
    }

    func testCurrentProfileExposesVideoTransferCapabilities() {
        var capabilities = MachineCompatibilityProfile.empty.capabilities
        capabilities["videoDownloadSystem"] = CapabilityStatus(
            level: .verified, strategy: "urlsession", detail: "fixture"
        )
        capabilities["videoDownloadAlternate"] = CapabilityStatus(
            level: .verified, strategy: "curl-resolve", detail: "fixture"
        )
        let profile = MachineCompatibilityProfile(
            profileID: UUID(), fingerprintDigest: "fixture", capabilities: capabilities,
            readOnlyPassedAt: nil, endToEndPassedAt: nil
        )

        XCTAssertEqual(profile.schemaVersion, 4)
        XCTAssertTrue(profile.systemVideoDownloadAvailable)
        XCTAssertTrue(profile.alternateVideoRouteAvailable)
        XCTAssertEqual(profile.videoTransferMode, "system+alternate")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoconfiguration-store-tests-(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
