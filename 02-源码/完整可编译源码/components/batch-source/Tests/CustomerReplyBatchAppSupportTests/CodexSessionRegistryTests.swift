import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class CodexSessionRegistryTests: XCTestCase {
    func testSessionNeverExpiresBecauseOfIdleTime() async throws {
        let fixture = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checkpoint = sampleCheckpoint()
        try await fixture.registry.commit(
            uid: "u1", sessionID: "session-a", checkpoint: checkpoint,
            promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )

        let afterOneHour = try await fixture.registry.plan(
            uid: "u1", promptVersion: "p1", knowledgeBaseVersion: "k1",
            at: now.addingTimeInterval(3_600)
        )
        let afterTenYears = try await fixture.registry.plan(
            uid: "u1", promptVersion: "p1", knowledgeBaseVersion: "k1",
            at: now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        )

        XCTAssertEqual(afterOneHour.sessionID, "session-a")
        XCTAssertEqual(afterTenYears.sessionID, "session-a")
        XCTAssertEqual(afterTenYears.checkpoint, checkpoint)
        XCTAssertFalse(afterTenYears.requiresCreation)
    }

    func testPromptOrKnowledgeBaseVersionChangeRequiresCreation() async throws {
        let fixture = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.registry.commit(
            uid: "prompt-user", sessionID: "session-a", checkpoint: sampleCheckpoint("a"),
            promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )
        try await fixture.registry.commit(
            uid: "knowledge-user", sessionID: "session-b", checkpoint: sampleCheckpoint("b"),
            promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )

        let promptChanged = try await fixture.registry.plan(
            uid: "prompt-user", promptVersion: "p2", knowledgeBaseVersion: "k1", at: now
        )
        let knowledgeChanged = try await fixture.registry.plan(
            uid: "knowledge-user", promptVersion: "p1", knowledgeBaseVersion: "k2", at: now
        )

        XCTAssertTrue(promptChanged.requiresCreation)
        XCTAssertTrue(knowledgeChanged.requiresCreation)
    }

    func testBindingsPersistByExactUIDWithOwnerOnlyPermissions() async throws {
        let fixture = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await fixture.registry.commit(
            uid: "user-a", sessionID: "session-a", checkpoint: sampleCheckpoint("a"),
            promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )
        try await fixture.registry.commit(
            uid: "user-b", sessionID: "session-b", checkpoint: sampleCheckpoint("b"),
            promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )

        let reloaded = CodexSessionRegistry(storageURL: fixture.storage)
        let planA = try await reloaded.plan(
            uid: "user-a", promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )
        let planB = try await reloaded.plan(
            uid: "user-b", promptVersion: "p1", knowledgeBaseVersion: "k1", at: now
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storage.path)
        let permissions = (attributes[FileAttributeKey.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(planA.sessionID, "session-a")
        XCTAssertEqual(planB.sessionID, "session-b")
        XCTAssertEqual(permissions, 0o600)
    }

    func testCorruptRegistryCreatesDiagnosticCopyAndNeverGuessesSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("sessions.json")
        try Data("not-json".utf8).write(to: storage)

        let registry = CodexSessionRegistry(storageURL: storage)
        let plan = try await registry.plan(
            uid: "u1", promptVersion: "p1", knowledgeBaseVersion: "k1", at: Date()
        )
        let diagnostics = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("sessions.corrupt-") }

        XCTAssertTrue(plan.requiresCreation)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(try String(contentsOf: diagnostics[0], encoding: .utf8), "not-json")
    }

    private func makeRegistry() throws -> (root: URL, storage: URL, registry: CodexSessionRegistry) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("sessions.json")
        return (root, storage, CodexSessionRegistry(storageURL: storage))
    }

    private func sampleCheckpoint(_ suffix: String = "") -> HistoryCheckpoint {
        HistoryCheckpoint(
            historyByteCount: 4,
            prefixSHA256: "hash\(suffix)",
            attachmentSHA256: ["/image\(suffix).jpg": "image-hash\(suffix)"]
        )
    }
}
