import CoreGraphics
import Foundation

public struct CustomerIdentity: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case detected
        case needsReview = "needs_review"
    }

    public let value: String
    public let status: Status

    public init(value: String, status: Status) {
        self.value = value
        self.status = status
    }
}

public enum CustomerIdentityExtractor {
    public static func extract(
        from lines: [OCRLine],
        imageHeight: CGFloat
    ) -> CustomerIdentity? {
        detectedValue(from: lines, imageHeight: imageHeight).map {
            CustomerIdentity(value: $0, status: .detected)
        }
    }

    public static func detectedValue(
        from lines: [OCRLine],
        imageHeight: CGFloat
    ) -> String? {
        guard imageHeight > 0 else { return nil }
        return lines
            .filter { $0.box.midY <= imageHeight * 0.22 }
            .sorted {
                if $0.box.midY != $1.box.midY { return $0.box.midY < $1.box.midY }
                return $0.box.minX < $1.box.minX
            }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isAccountLike)
    }

    public static func identity(
        from lines: [OCRLine],
        imageHeight: CGFloat,
        requestID: String
    ) -> CustomerIdentity {
        extract(from: lines, imageHeight: imageHeight)
            ?? CustomerIdentity(value: "unknown-\(requestID)", status: .needsReview)
    }

    public static func isAccountLike(_ text: String) -> Bool {
        guard (4...64).contains(text.count),
              text.rangeOfCharacter(from: .decimalDigits) != nil else {
            return false
        }
        return text.range(
            of: #"^tb[A-Za-z0-9_.@-]{2,62}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func structuralAXValue(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 256,
              !trimmed.contains("\n"),
              !trimmed.hasSuffix("..."),
              !trimmed.hasSuffix("…") else {
            return nil
        }
        let isDateOrTimestamp = trimmed.range(
            of: #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?$"#,
            options: .regularExpression
        ) != nil
        return isDateOrTimestamp ? nil : trimmed
    }
}

public struct CustomerIdentityCandidates: Codable, Equatable, Sendable {
    public let axHeader: String?
    public let axSessionList: String?
    public let ocr: String?

    public init(axHeader: String?, axSessionList: String?, ocr: String?) {
        self.axHeader = axHeader
        self.axSessionList = axSessionList
        self.ocr = ocr
    }

    public static let empty = CustomerIdentityCandidates(
        axHeader: nil,
        axSessionList: nil,
        ocr: nil
    )

    enum CodingKeys: String, CodingKey {
        case axHeader = "ax_header"
        case axSessionList = "ax_session_list"
        case ocr
    }
}

public enum CustomerIdentitySource: String, Codable, Equatable, Sendable {
    case axHeader = "ax_header"
    case axSessionList = "ax_session_list"
    case ocr
    case fallback
}

public struct ResolvedCustomerIdentity: Equatable, Sendable {
    public let identity: CustomerIdentity
    public let source: CustomerIdentitySource
    public let candidates: CustomerIdentityCandidates

    public init(
        identity: CustomerIdentity,
        source: CustomerIdentitySource,
        candidates: CustomerIdentityCandidates
    ) {
        self.identity = identity
        self.source = source
        self.candidates = candidates
    }
}

public enum CustomerIdentityResolver {
    public static func resolve(
        candidates original: CustomerIdentityCandidates,
        requestID: String
    ) -> ResolvedCustomerIdentity {
        let candidates = CustomerIdentityCandidates(
            axHeader: CustomerIdentityExtractor.structuralAXValue(original.axHeader),
            axSessionList: CustomerIdentityExtractor.structuralAXValue(original.axSessionList),
            ocr: validOCR(original.ocr)
        )
        if let header = candidates.axHeader {
            let conflict = candidates.axSessionList.map { $0 != header } ?? false
            return ResolvedCustomerIdentity(
                identity: CustomerIdentity(
                    value: header,
                    status: conflict ? .needsReview : .detected
                ),
                source: .axHeader,
                candidates: candidates
            )
        }
        if let session = candidates.axSessionList {
            return ResolvedCustomerIdentity(
                identity: CustomerIdentity(value: session, status: .detected),
                source: .axSessionList,
                candidates: candidates
            )
        }
        if let ocr = candidates.ocr {
            return ResolvedCustomerIdentity(
                identity: CustomerIdentity(value: ocr, status: .detected),
                source: .ocr,
                candidates: candidates
            )
        }
        return ResolvedCustomerIdentity(
            identity: CustomerIdentity(value: "unknown-\(requestID)", status: .needsReview),
            source: .fallback,
            candidates: candidates
        )
    }

    private static func validOCR(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomerIdentityExtractor.isAccountLike(trimmed) ? trimmed : nil
    }
}

public struct CustomerRequestMessage: Codable, Equatable, Sendable {
    public let t: String
    public let v: String?
    public let p: String?

    public init(t: String, v: String?, p: String?) {
        self.t = t
        self.v = v
        self.p = p
    }
}

public enum CustomerRequestManifestBuilder {
    public static func messages(
        lines: [OCRLine],
        imageBoxes: [CGRect]
    ) -> [CustomerRequestMessage] {
        let markerPrefix = "\u{0}qianniu-image:"
        let markers = imageBoxes.enumerated().map { index, box in
            OCRLine(text: "\(markerPrefix)\(index)", box: box)
        }
        return SpatialOrdering.readingOrder(lines + markers).map { line in
            guard line.text.hasPrefix(markerPrefix),
                  let index = Int(line.text.dropFirst(markerPrefix.count)) else {
                return CustomerRequestMessage(t: "text", v: line.text, p: nil)
            }
            return CustomerRequestMessage(
                t: "image",
                v: nil,
                p: "images/\(index + 1).jpg"
            )
        }
    }
}
