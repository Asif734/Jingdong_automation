import CoreGraphics
import XCTest
@testable import AutoReplyApp

final class DiagnosticBundleExporterTests: XCTestCase {
    func testDefaultBundleContainsNoCustomerOrCredentialMaterial() throws {
        let root = temporaryDirectory()
        let raw = root.appendingPathComponent("full-screen.png")
        try Data("tb-secret secret-name secret-token".utf8).write(to: raw)
        let exporter = DiagnosticBundleExporter(
            snapshot: .diagnosticFixture,
            profile: .empty,
            errors: [DiagnosticErrorRecord(
                occurredAt: Date(timeIntervalSince1970: 1),
                capability: "identity",
                code: "missing-row-id",
                detail: "tb-secret secret-name secret-token"
            )],
            rawEvidenceURLs: [raw],
            readiness: ReadinessStateExport(
                phase: .readOnlyReady,
                ocrPrepared: true,
                v2Prepared: true,
                profileCreated: true,
                endToEndVerified: false
            )
        )

        let directory = try exporter.export(to: root.appendingPathComponent("out"), includeRawEvidence: false)
        let bytes = try allFileText(in: directory)
        XCTAssertFalse(bytes.contains("tb-secret"))
        XCTAssertFalse(bytes.contains("secret-name"))
        XCTAssertFalse(bytes.contains("secret-token"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("raw-evidence/full-screen.png").path
        ))
        let readiness = try JSONDecoder().decode(
            ReadinessStateExport.self,
            from: Data(contentsOf: directory.appendingPathComponent("readiness-state.json"))
        )
        XCTAssertEqual(readiness.phase, .readOnlyReady)
        XCTAssertFalse(readiness.endToEndVerified)
    }

    func testRawEvidenceRequiresExplicitOptIn() throws {
        let root = temporaryDirectory()
        let raw = root.appendingPathComponent("window.png")
        try Data("raw-window".utf8).write(to: raw)
        let exporter = DiagnosticBundleExporter(
            snapshot: .diagnosticFixture,
            profile: .empty,
            errors: [],
            rawEvidenceURLs: [raw]
        )

        let directory = try exporter.export(to: root.appendingPathComponent("out"), includeRawEvidence: true)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("raw-evidence/window.png"), encoding: .utf8),
            "raw-window"
        )
    }

    func testBundleExportsStructuredSendCalibrationDecision() throws {
        let root = temporaryDirectory()
        let expected = SendCalibrationDiagnostic(
            stage: "发送控件校准",
            rawPressableCount: 40,
            eligibleCandidateCount: 0,
            selectedStrategy: "returnKeyOnce",
            level: .fallback,
            canContinue: true,
            nextAction: "使用 Return 发送；首次真实发送后自动核对结果"
        )
        let profile = MachineCompatibilityProfile(
            profileID: UUID(),
            fingerprintDigest: "fixture",
            capabilities: [
                "sendAX": CapabilityStatus(
                    level: .fallback,
                    strategy: "returnKeyOnce",
                    detail: "发送校准：可按40个，有效0个"
                )
            ],
            readOnlyPassedAt: Date(timeIntervalSince1970: 1),
            endToEndPassedAt: nil,
            calibrationDiagnostics: [expected]
        )
        let exporter = DiagnosticBundleExporter(
            snapshot: .diagnosticFixture,
            profile: profile,
            errors: [],
            rawEvidenceURLs: []
        )

        let directory = try exporter.export(
            to: root.appendingPathComponent("out"),
            includeRawEvidence: false
        )
        let diagnostics = try JSONDecoder().decode(
            [SendCalibrationDiagnostic].self,
            from: Data(contentsOf: directory.appendingPathComponent("calibration-diagnostics.json"))
        )

        XCTAssertEqual(diagnostics, [expected])
        XCTAssertTrue(diagnostics[0].canContinue)
    }

    private func allFileText(in root: URL) throws -> String {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath } ?? []
        return try files.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private extension CalibrationSnapshot {
    static let diagnosticFixture = CalibrationSnapshot(
        macOSBuild: "25G83",
        architecture: "arm64",
        qianniuVersion: "9.97.74",
        qianniuBuild: "20260812105806",
        qianniuRuntimeArchitecture: "arm64",
        displays: [CalibrationDisplay(relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 2)],
        windows: [CalibrationWindow(
            roleCategory: "reception",
            relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            captureFrame: CGRect(x: 0, y: 0, width: 2, height: 2),
            minimized: false,
            focused: true,
            regionCategories: ["conversation-list", "chat", "composer"]
        )],
        nodes: [CalibrationAXNode(
            id: 1,
            parentID: nil,
            role: "AXGroup",
            actionNames: [],
            labelCategory: "identity-like",
            relativeFrame: CGRect(x: 0.02, y: 0.15, width: 0.28, height: 0.065),
            hasValue: true
        )]
    )
}
