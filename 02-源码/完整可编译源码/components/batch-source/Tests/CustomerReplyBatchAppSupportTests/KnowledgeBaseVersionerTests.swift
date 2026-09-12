import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class KnowledgeBaseVersionerTests: XCTestCase {
    func testVersionIsStableUntilKnowledgeBaseContentChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeBaseVersionerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("kb.zip")
        try Data("one".utf8).write(to: file)
        let versioner = KnowledgeBaseVersioner()

        let first = try await versioner.version(paths: [file.path])
        let repeated = try await versioner.version(paths: [file.path])
        try Data("two".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: file.path
        )
        let changed = try await versioner.version(paths: [file.path])

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, changed)
    }
}
