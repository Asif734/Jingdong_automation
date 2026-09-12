import CryptoKit
import Foundation

struct DistributionFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
}

struct DistributionManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let architecture: String
    let files: [DistributionFile]

    static func make(for app: URL, version: String) throws -> DistributionManifest {
        let files = try regularFiles(in: app).map { url in
            DistributionFile(
                path: url.path.replacingOccurrences(of: app.path + "/", with: ""),
                sha256: try sha256(url)
            )
        }.sorted { $0.path < $1.path }
        return DistributionManifest(
            schemaVersion: 1,
            appVersion: version,
            architecture: "arm64",
            files: files
        )
    }

    fileprivate static func regularFiles(in root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            return values.isRegularFile == true && values.isSymbolicLink != true ? url : nil
        }
    }

    fileprivate static func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct InstallationDestinations: Equatable, Sendable {
    let system: URL
    let user: URL
}

struct InstallationReceipt: Codable, Equatable, Sendable {
    let installedAt: Date
    let destinationURL: URL
    let appVersion: String
    let architecture: String
}

enum InstallationTransactionError: LocalizedError {
    case noWritableDestination
    case invalidManifest(String)
    case signatureInvalid
    case architectureInvalid([String])
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWritableDestination: "系统和用户 Applications 目录都不可写"
        case .invalidManifest(let detail): "安装包校验失败：\(detail)"
        case .signatureInvalid: "应用代码签名校验失败"
        case .architectureInvalid(let values): "应用架构不匹配：\(values.joined(separator: ","))"
        case .rollbackFailed(let detail): "安装失败且旧版本恢复失败：\(detail)"
        }
    }
}

struct InstallationTransaction {
    static let appName = "千牛全自动客服-版本B.app"

    let systemApplicationsURL: URL
    let userApplicationsURL: URL
    let isWritable: (URL) -> Bool
    let verifySignature: (URL) -> Bool
    let executableArchitectures: (URL) -> [String]
    var now: () -> Date = { Date() }

    init(
        systemApplicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        userApplicationsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true),
        isWritable: @escaping (URL) -> Bool = Self.defaultWritable,
        verifySignature: @escaping (URL) -> Bool = Self.defaultSignatureVerification,
        executableArchitectures: @escaping (URL) -> [String] = Self.defaultArchitectures
    ) {
        self.systemApplicationsURL = systemApplicationsURL
        self.userApplicationsURL = userApplicationsURL
        self.isWritable = isWritable
        self.verifySignature = verifySignature
        self.executableArchitectures = executableArchitectures
    }

    func chooseDestination() throws -> URL {
        if isWritable(systemApplicationsURL) {
            return systemApplicationsURL.appendingPathComponent(Self.appName)
        }
        if isWritable(userApplicationsURL) {
            return userApplicationsURL.appendingPathComponent(Self.appName)
        }
        throw InstallationTransactionError.noWritableDestination
    }

    func install(
        payload: URL,
        manifest: DistributionManifest,
        destinations: InstallationDestinations? = nil
    ) throws -> InstallationReceipt {
        let selected: URL
        if let destinations {
            if isWritable(destinations.system) {
                selected = destinations.system.appendingPathComponent(Self.appName)
            } else if isWritable(destinations.user) {
                selected = destinations.user.appendingPathComponent(Self.appName)
            } else {
                throw InstallationTransactionError.noWritableDestination
            }
        } else {
            selected = try chooseDestination()
        }
        try validate(payload: payload, manifest: manifest)
        let fileManager = FileManager.default
        let parent = selected.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".qianniu-autoreply-staging-\(UUID().uuidString).app")
        let backup = parent.appendingPathComponent("\(Self.appName).backup-\(Int(now().timeIntervalSince1970))")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: payload, to: staging)
        try validate(payload: staging, manifest: manifest)

        let hadExisting = fileManager.fileExists(atPath: selected.path)
        if hadExisting { try fileManager.moveItem(at: selected, to: backup) }
        do {
            try fileManager.moveItem(at: staging, to: selected)
            try validate(payload: selected, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: selected)
            if hadExisting {
                do { try fileManager.moveItem(at: backup, to: selected) }
                catch { throw InstallationTransactionError.rollbackFailed(error.localizedDescription) }
            }
            throw error
        }
        removeOldBackups(in: parent, preserving: backup)
        return InstallationReceipt(
            installedAt: now(),
            destinationURL: selected,
            appVersion: manifest.appVersion,
            architecture: manifest.architecture
        )
    }

    private func validate(payload: URL, manifest: DistributionManifest) throws {
        guard manifest.schemaVersion == 1, manifest.architecture == "arm64" else {
            throw InstallationTransactionError.invalidManifest("版本或架构字段不支持")
        }
        let actual = try DistributionManifest.regularFiles(in: payload).map {
            $0.path.replacingOccurrences(of: payload.path + "/", with: "")
        }.sorted()
        let expected = manifest.files.map(\.path).sorted()
        guard actual == expected else {
            throw InstallationTransactionError.invalidManifest("文件清单不一致")
        }
        for item in manifest.files {
            let url = payload.appendingPathComponent(item.path)
            guard try DistributionManifest.sha256(url) == item.sha256 else {
                throw InstallationTransactionError.invalidManifest("哈希不一致：\(item.path)")
            }
        }
        let executable = payload.appendingPathComponent("Contents/MacOS/AutoReplyApp")
        let architectures = executableArchitectures(executable)
        guard architectures == ["arm64"] || (architectures.contains("arm64") && !architectures.contains("x86_64")) else {
            throw InstallationTransactionError.architectureInvalid(architectures)
        }
        guard verifySignature(payload) else { throw InstallationTransactionError.signatureInvalid }
    }

    private func removeOldBackups(in directory: URL, preserving newest: URL) {
        let fileManager = FileManager.default
        let prefix = Self.appName + ".backup-"
        let backups = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
        for url in backups.dropFirst(3) where url != newest { try? fileManager.removeItem(at: url) }
    }

    private static func defaultWritable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            return fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path)
        }
        return fileManager.isWritableFile(atPath: url.path)
    }

    private static func defaultSignatureVerification(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    private static func defaultArchitectures(_ executable: URL) -> [String] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", executable.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).map(String.init)
        } catch { return [] }
    }
}
