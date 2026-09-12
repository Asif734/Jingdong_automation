import Foundation
import XCTest
@testable import AutoReplyApp

final class CompatibilityFixtureReplayTests: XCTestCase {
    func testAllCompatibilityFixturesProduceExpectedProfiles() throws {
        for fixture in try CompatibilityFixture.loadAll() {
            let profile = try AdaptiveCalibrationEngine.calibrate(snapshot: fixture.snapshot)
            XCTAssertEqual(
                profile.capabilities["receptionWindow"]?.strategy,
                fixture.expected.windowStrategy,
                fixture.name
            )
            XCTAssertEqual(
                profile.capabilities["conversationList"]?.level.rawValue,
                fixture.expected.conversationListLevel,
                fixture.name
            )
            XCTAssertEqual(
                profile.identityPolicy?.orderedSources.map(\.rawValue),
                fixture.expected.identitySources,
                fixture.name
            )
            XCTAssertEqual(profile.sendPolicy?.rawValue, fixture.expected.sendPolicy, fixture.name)
            XCTAssertNotNil(profile.capabilities["videoDownloadSystem"], fixture.name)
            XCTAssertNotNil(profile.capabilities["videoDownloadAlternate"], fixture.name)
            let containsBlankHeader = fixture.snapshot.nodes.contains {
                $0.role == "AXGroup" && $0.labelCategory == "blank"
                    && $0.relativeFrame.height > 0 && $0.relativeFrame.height < 0.05
            }
            XCTAssertEqual(containsBlankHeader, fixture.expected.containsBlankSectionHeader, fixture.name)
            if let ratio = fixture.expected.blankSectionHeaderMaximumRatio {
                let actual = try XCTUnwrap(
                    profile.conversationListPolicy?.sectionHeaderMaximumHeightRatio,
                    fixture.name
                )
                XCTAssertEqual(
                    actual,
                    CGFloat(ratio),
                    accuracy: 0.001,
                    fixture.name
                )
            }
        }
    }

    func testColleagueB40ControlFixtureProducesRunnableProfile() throws {
        let profile = try AdaptiveCalibrationEngine.calibrate(
            snapshot: .colleagueB40Controls(exactSendLabel: true)
        )

        XCTAssertEqual(profile.sendPolicy, .accessibilityPress)
        XCTAssertFalse(profile.requiresFullAdaptiveCalibration)
    }
}

private struct CompatibilityFixture {
    let name: String
    let snapshot: CalibrationSnapshot
    let expected: Expected

    struct SnapshotFile: Decodable {
        let schemaVersion: Int
        let snapshot: CalibrationSnapshot
    }

    struct ExpectedFile: Decodable {
        let schemaVersion: Int
        let expected: Expected
    }

    struct Expected: Decodable {
        let windowStrategy: String
        let conversationListLevel: String
        let identitySources: [String]
        let sendPolicy: String
        let blankSectionHeaderMaximumRatio: Double?
        let containsBlankSectionHeader: Bool
    }

    static func loadAll() throws -> [CompatibilityFixture] {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = tests.appendingPathComponent("Fixtures/Compatibility", isDirectory: true)
        return try ["current", "colleague-a", "colleague-b"].map { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(
                SnapshotFile.self,
                from: Data(contentsOf: directory.appendingPathComponent("snapshot.json"))
            )
            let expected = try decoder.decode(
                ExpectedFile.self,
                from: Data(contentsOf: directory.appendingPathComponent("expected-profile.json"))
            )
            guard snapshot.schemaVersion == 1, expected.schemaVersion == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return CompatibilityFixture(name: name, snapshot: snapshot.snapshot, expected: expected.expected)
        }
    }
}
