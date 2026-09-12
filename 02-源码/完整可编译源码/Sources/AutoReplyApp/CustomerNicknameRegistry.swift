import Foundation
import UnreadCore

struct CustomerNicknameRegistry {
    private struct Entry: Codable {
        var nickname: String
        var pendingNickname: String?
        var pendingCount: Int
    }

    private struct Document: Codable {
        var scopes: [String: [String: Entry]] = [:]
    }

    private let url: URL
    private var document: Document

    init(url: URL) {
        self.url = url
        document = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
            ?? Document()
    }

    func nickname(scope: String, uid: String) -> String? {
        document.scopes[normalizedScope(scope)]?[normalizedUID(uid)]?.nickname
    }

    mutating func observe(scope: String, uid: String, nickname: String) throws {
        let scopeKey = normalizedScope(scope)
        let uidKey = normalizedUID(uid)
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uidKey.isEmpty, let fullNickname = ConversationLocator.customerNickname(from: value) else { return }

        var entries = document.scopes[scopeKey] ?? [:]
        if var entry = entries[uidKey] {
            if ConversationLocator.nicknameMatches(expected: entry.nickname, actual: fullNickname) {
                entry.pendingNickname = nil
                entry.pendingCount = 0
            } else if entry.pendingNickname == fullNickname {
                entry.pendingCount += 1
                if entry.pendingCount >= 2 {
                    entry.nickname = fullNickname
                    entry.pendingNickname = nil
                    entry.pendingCount = 0
                }
            } else {
                entry.pendingNickname = fullNickname
                entry.pendingCount = 1
            }
            entries[uidKey] = entry
        } else {
            entries[uidKey] = Entry(nickname: fullNickname, pendingNickname: nil, pendingCount: 0)
        }
        document.scopes[scopeKey] = entries
        try persist()
    }

    private func normalizedScope(_ scope: String) -> String {
        let value = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "default" : value
    }

    private func normalizedUID(_ uid: String) -> String {
        uid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }
}
