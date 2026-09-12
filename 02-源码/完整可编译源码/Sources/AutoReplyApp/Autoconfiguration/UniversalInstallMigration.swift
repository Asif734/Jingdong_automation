import Foundation

private struct UniversalInstallMarker: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let migration: String
    let completed: Bool
}

enum UniversalInstallMigration {
    static func applyIfNeeded(
        root: URL,
        operatorStore: AtomicJSONStore<OperatorConfig>
    ) throws -> OperatorConfig? {
        let markerURL = root.appendingPathComponent(
            "运行状态/自动配置/universal-install-v1.json"
        )
        if FileManager.default.fileExists(atPath: markerURL.path) {
            return try operatorStore.load()
        }

        let old = try operatorStore.load()
        let migrated = OperatorConfig(
            serviceAliases: old?.serviceAliases ?? [],
            autoStartWhenReady: true
        )
        try operatorStore.saveCandidate(migrated, validate: { _ in true })

        let marker = UniversalInstallMarker(
            schemaVersion: 1,
            migration: "universal-install",
            completed: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: markerURL)
        defer { try? handle.close() }
        try handle.synchronize()
        return migrated
    }
}
