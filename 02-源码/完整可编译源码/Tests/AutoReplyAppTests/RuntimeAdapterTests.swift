import CoreGraphics
import QianniuOCRCore
import QianniuSenderCore
import UnreadCore
import XCTest
@testable import AutoReplyApp

@MainActor
final class RuntimeAdapterTests: XCTestCase {
    func testUnavailableAXCaptureFallsBackWithoutChangingSendStrategy() async throws {
        let adapter = AdaptiveRuntimeAdapter.fixture(
            captureAX: .unavailable,
            captureOCR: .verified,
            sendAX: .verified
        )

        let capture = try await adapter.captureStrategy()
        let send = try await adapter.sendStrategy()
        XCTAssertEqual(capture, .ocr)
        XCTAssertEqual(send, .accessibilityPress)
    }

    func testOneMalformedRowStillReturnsOtherCustomers() async throws {
        let validA = ConversationCandidate(
            nodeID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 52),
            identity: .full(uid: "customer-a", nickname: nil)
        )
        let malformed = ConversationCandidate(
            nodeID: 2,
            frame: CGRect(x: 0, y: 52, width: 100, height: 34),
            identity: .unresolved(labels: [])
        )
        let validB = ConversationCandidate(
            nodeID: 3,
            frame: CGRect(x: 0, y: 86, width: 100, height: 52),
            identity: .full(uid: "customer-b", nickname: nil)
        )
        let adapter = AdaptiveRuntimeAdapter.fixture(candidates: [validA, malformed, validB])

        var identities: [String] = []
        for candidate in try await adapter.discoverCustomers() {
            if let identity = try await adapter.resolveIdentity(for: candidate) {
                identities.append(identity)
            }
        }
        XCTAssertEqual(Set(identities), ["customer-a", "customer-b"])
    }

    func testVersionOneProfileDecodesWithoutInventingTypedPolicies() throws {
        let json = """
        {
          "schemaVersion": 1,
          "profileID": "00000000-0000-0000-0000-000000000001",
          "fingerprintDigest": "legacy",
          "capabilities": {
            "composer": {"level":"verified","strategy":"legacy-static-rules","detail":"ok"}
          }
        }
        """

        let profile = try JSONDecoder().decode(
            MachineCompatibilityProfile.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(profile.schemaVersion, 1)
        XCTAssertEqual(profile.capabilities["composer"]?.level, .verified)
        XCTAssertNil(profile.windowPolicy)
        XCTAssertNil(profile.conversationListPolicy)
        XCTAssertNil(profile.identityPolicy)
        XCTAssertNil(profile.capturePolicy)
        XCTAssertNil(profile.composerPolicy)
        XCTAssertNil(profile.sendPolicy)
        XCTAssertTrue(profile.requiresFullAdaptiveCalibration)
    }
}
