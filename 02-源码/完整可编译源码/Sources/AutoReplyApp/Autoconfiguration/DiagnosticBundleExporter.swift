import Foundation

struct DiagnosticErrorRecord: Codable, Equatable, Sendable {
    let occurredAt: Date
    let capability: String
    let code: String
    let detail: String
}

struct DiagnosticManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let fingerprint: EnvironmentFingerprint
    let capabilityStates: [String: CapabilityStatus]
    let includedRawEvidence: Bool
}

struct DiagnosticBundleExporter: Sendable {
    let snapshot: CalibrationSnapshot
    let profile: MachineCompatibilityProfile
    let errors: [DiagnosticErrorRecord]
    let rawEvidenceURLs: [URL]
    var readiness: ReadinessStateExport? = nil
    var now: @Sendable () -> Date = { Date() }

    func export(to root: URL, includeRawEvidence: Bool) throws -> URL {
        let fileManager = FileManager.default
        let output = root.appendingPathComponent("千牛脱敏诊断包", isDirectory: true)
        if fileManager.fileExists(atPath: output.path) {
            try fileManager.removeItem(at: output)
        }
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        let fingerprint = profile.environmentFingerprint ?? EnvironmentFingerprint.make(from: snapshot)
        let manifest = DiagnosticManifest(
            schemaVersion: 1,
            createdAt: now(),
            fingerprint: fingerprint,
            capabilityStates: profile.capabilities,
            includedRawEvidence: includeRawEvidence
        )
        try write(manifest, to: output.appendingPathComponent("manifest.json"))
        try write(snapshot, to: output.appendingPathComponent("redacted-snapshot.json"))
        try write(profile, to: output.appendingPathComponent("machine-profile.json"))
        try write(
            profile.calibrationDiagnostics ?? [],
            to: output.appendingPathComponent("calibration-diagnostics.json")
        )
        if let readiness {
            try write(readiness, to: output.appendingPathComponent("readiness-state.json"))
        }

        let boundedErrors = Array(errors.suffix(200)).map { error in
            includeRawEvidence ? error : DiagnosticErrorRecord(
                occurredAt: error.occurredAt,
                capability: structuralToken(error.capability),
                code: structuralToken(error.code),
                detail: "已脱敏；原始详情未包含"
            )
        }
        try write(boundedErrors, to: output.appendingPathComponent("structured-errors.json"))

        if includeRawEvidence, !rawEvidenceURLs.isEmpty {
            let rawDirectory = output.appendingPathComponent("raw-evidence", isDirectory: true)
            try fileManager.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
            for source in rawEvidenceURLs {
                guard source.isFileURL,
                      fileManager.fileExists(atPath: source.path),
                      !source.hasDirectoryPath else { continue }
                let safeName = sanitizedFilename(source.lastPathComponent)
                try fileManager.copyItem(at: source, to: rawDirectory.appendingPathComponent(safeName))
            }
        }
        return output
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func structuralToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.filter { allowed.contains($0) }
        let token = String(String.UnicodeScalarView(scalars))
        return token.isEmpty ? "redacted" : String(token.prefix(80))
    }

    private func sanitizedFilename(_ value: String) -> String {
        structuralToken(value.replacingOccurrences(of: "/", with: "-"))
    }
}
