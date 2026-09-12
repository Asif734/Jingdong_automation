import XCTest
@testable import GrozziieModelTesterCore

final class CodexInstallationTests: XCTestCase {
    func testPrefersChatGPTAppBeforeOtherCandidates() {
        let existing = Set([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
        ])
        let result = CodexInstallationLocator.resolve(
            isExecutable: { existing.contains($0.path) },
            pathLookup: { URL(fileURLWithPath: "/custom/bin/codex") }
        )
        XCTAssertEqual(result?.path, "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    func testUsesPathLookupAfterKnownLocations() {
        let result = CodexInstallationLocator.resolve(
            isExecutable: { $0.path == "/custom/bin/codex" },
            pathLookup: { URL(fileURLWithPath: "/custom/bin/codex") }
        )
        XCTAssertEqual(result?.path, "/custom/bin/codex")
    }

    func testReturnsNilWhenNoExecutableExists() {
        XCTAssertNil(CodexInstallationLocator.resolve(
            isExecutable: { _ in false },
            pathLookup: { nil }
        ))
    }

    func testCandidateLocationsIncludeSystemAndUserApplications() {
        let paths = CodexInstallationLocator.candidateLocations(
            homeDirectory: URL(fileURLWithPath: "/Users/colleague")
        ).map(\.path)

        XCTAssertTrue(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/Users/colleague/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/codex"))
    }

    func testProductionModelConfigurationIsExact() {
        XCTAssertEqual(ModelConfiguration.production.model, "gpt-5.6-sol")
        XCTAssertEqual(ModelConfiguration.production.reasoningEffort, "medium")
        XCTAssertEqual(ModelConfiguration.production.displayName, "GPT-5.6 Sol · 中")
    }
}
