import Foundation

public enum ConversationIdentitySource: String, Codable, Equatable, Sendable {
    case containerTitle
    case childNickname
    case chatHeader
    case uniquePrefix
    case ocrNickname
}

public struct ConversationIdentityPolicy: Codable, Equatable, Sendable {
    public let orderedSources: [ConversationIdentitySource]

    public init(orderedSources: [ConversationIdentitySource]) {
        var seen: Set<ConversationIdentitySource> = []
        self.orderedSources = orderedSources.filter { seen.insert($0).inserted }
    }

    public static let `default` = availableSources(
        containerTitle: true,
        childNickname: true,
        header: true,
        ocr: true
    )

    public static func availableSources(
        containerTitle: Bool,
        childNickname: Bool,
        header: Bool,
        ocr: Bool
    ) -> ConversationIdentityPolicy {
        var sources: [ConversationIdentitySource] = []
        if containerTitle { sources.append(.containerTitle) }
        if childNickname { sources.append(.childNickname) }
        if header { sources.append(.chatHeader) }
        if containerTitle || childNickname || header { sources.append(.uniquePrefix) }
        if ocr { sources.append(.ocrNickname) }
        return ConversationIdentityPolicy(orderedSources: sources)
    }

    public func contains(_ source: ConversationIdentitySource) -> Bool {
        orderedSources.contains(source)
    }

    public func resolvePrefix(_ display: String, visibleIdentities: [String]) -> String? {
        guard contains(.uniquePrefix), let prefix = Self.truncatedPrefix(display) else { return nil }
        let normalizedPrefix = Self.normalized(prefix)
        guard Self.usablePrefix(normalizedPrefix) else { return nil }
        let matches = visibleIdentities.filter {
            let normalized = Self.normalized($0)
            return !normalized.isEmpty && normalized.hasPrefix(normalizedPrefix)
        }
        if matches.count == 1 { return matches[0] }
        // A truncated row can still be routed as a provisional unique prefix when
        // this snapshot exposes no matching full identity. Two matches are never safe.
        return matches.isEmpty ? display : nil
    }

    private static func truncatedPrefix(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("...") { return String(value.dropLast(3)) }
        if value.hasSuffix("…") { return String(value.dropLast()) }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        let mapped = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(mapped.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || Self.isHan($0)
        })
    }

    private static func usablePrefix(_ prefix: String) -> Bool {
        let hanCount = prefix.unicodeScalars.filter(isHan).count
        return hanCount > 0 ? prefix.count >= 2 : prefix.count >= 4
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x9FFF).contains(Int(scalar.value))
            || (0xF900...0xFAFF).contains(Int(scalar.value))
    }
}
