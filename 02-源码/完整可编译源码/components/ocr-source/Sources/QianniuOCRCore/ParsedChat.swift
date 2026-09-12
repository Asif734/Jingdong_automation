import CoreGraphics
import Foundation

public struct ParsedChatMessage: Codable, Equatable, Sendable {
    public let sender: String
    public let type: String
    public let value: String?
    public let path: String?
    public let timestamp: String?
    public let readStatus: String?

    public init(
        sender: String,
        type: String,
        value: String?,
        path: String?,
        timestamp: String?,
        readStatus: String?
    ) {
        self.sender = sender
        self.type = type
        self.value = value
        self.path = path
        self.timestamp = timestamp
        self.readStatus = readStatus
    }

    enum CodingKeys: String, CodingKey {
        case sender
        case type = "t"
        case value = "v"
        case path = "p"
        case timestamp
        case readStatus = "read_status"
    }
}

public struct ParsedChatResult: Codable, Equatable, Sendable {
    public let rawOCR: [String]
    public let messages: [ParsedChatMessage]

    public init(rawOCR: [String], messages: [ParsedChatMessage]) {
        self.rawOCR = rawOCR
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case rawOCR = "raw_ocr"
        case messages = "msg"
    }
}

public enum ParsedChatParser {
    private static let imagePrefix = "\u{0}qianniu-image:"

    public static func parse(
        lines: [OCRLine],
        imageBoxes: [CGRect],
        imageHeight: CGFloat,
        serviceAliases: Set<String>? = nil
    ) -> ParsedChatResult {
        let rawMarkers = imageBoxes.enumerated().map { index, box in
            OCRLine(
                text: "\(imagePrefix)\(index)",
                box: box,
                confidence: nil
            )
        }
        let parsingMarkers = imageBoxes.enumerated().map { index, box in
            OCRLine(
                text: "\(imagePrefix)\(index)",
                box: CGRect(x: box.minX, y: box.minY, width: box.width, height: 1),
                confidence: nil
            )
        }
        let ordered = SpatialOrdering.readingOrder(lines + rawMarkers)
        let raw = ordered.map(displayText)
        let messageLines = lines.filter { line in
            !imageBoxes.contains { imageBox in
                isInsideDetectedImage(line.box, imageBox: imageBox)
            }
        }
        let rows = visualRows(SpatialOrdering.readingOrder(messageLines + parsingMarkers))
        var pendingSender: String?
        var pendingTimestamp: String?
        var pendingServiceAliasSuffixCandidate = false
        var messages: [ParsedChatMessage] = []
        var previousTextRowBox: CGRect?
        var previousServiceAliasSuffixCandidate = false

        for (rowIndex, row) in rows.enumerated() {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let compactRow = sorted
                .filter { !$0.text.hasPrefix(imagePrefix) }
                .map(\.text)
                .joined()
                .replacingOccurrences(of: " ", with: "")
            if metadata(from: sorted, serviceAliases: serviceAliases) == nil,
               (sorted.map(\.box.maxY).max() ?? .infinity) <= imageHeight * 0.15,
               sorted.contains(where: { line in
                   CustomerIdentityExtractor.isAccountLike(
                       line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                   )
               }) {
                continue
            }
            if metadata(from: sorted, serviceAliases: serviceAliases) == nil,
               (sorted.map(\.box.maxY).max() ?? .infinity) <= imageHeight * 0.15,
               isLikelyClippedTimestampFragment(compactRow) {
                continue
            }
            if serviceAliases == nil, compactRow.contains("旗舰店"),
               metadata(from: sorted, serviceAliases: serviceAliases) == nil {
                pendingSender = "service"
                pendingServiceAliasSuffixCandidate = false
                previousTextRowBox = nil
                previousServiceAliasSuffixCandidate = false
                continue
            }
            if let metadata = metadata(from: sorted, serviceAliases: serviceAliases) {
                let nextRowIsImage = rows.indices.contains(rowIndex + 1)
                    && rows[rowIndex + 1].contains { $0.text.hasPrefix(imagePrefix) }
                let imageSpecificSender = metadata.sender == "unknown"
                    && nextRowIsImage
                    && hasJoinedAccountPrefixBeforeTimestamp(sorted)
                    ? "customer"
                    : metadata.sender
                if serviceAliases != nil && imageSpecificSender == "unknown" {
                    // In configured mode, an unrecognized sender header is not
                    // evidence of service identity. A colon-shaped identity row
                    // is nevertheless strong evidence that horizontal placement
                    // must not guess either side; preserve it as unknown. Legacy
                    // headers without that shape retain the existing fallback.
                    pendingSender = metadata.locksUnknown ? "unknown" : nil
                } else if imageSpecificSender != "unknown" || pendingSender == nil {
                    pendingSender = imageSpecificSender
                }
                pendingTimestamp = metadata.timestamp
                pendingServiceAliasSuffixCandidate = metadata.serviceAliasSuffixCandidate
                previousTextRowBox = nil
                previousServiceAliasSuffixCandidate = false
                continue
            }
            if (pendingSender != nil || pendingTimestamp != nil),
               isPunctuationOnly(compactRow) {
                continue
            }

            for line in sorted where line.text.hasPrefix(imagePrefix) {
                guard let index = Int(line.text.dropFirst(imagePrefix.count)) else { continue }
                let imageSender = pendingSender ?? inferredSender(box: line.box, lines: messageLines)
                messages.append(
                    ParsedChatMessage(
                        // This workflow's AI sends text only; default only unresolved images to customer.
                        sender: imageSender == "unknown" ? "customer" : imageSender,
                        type: "image",
                        value: nil,
                        path: "images/\(index + 1).jpg",
                        timestamp: pendingTimestamp,
                        readStatus: nil
                    )
                )
                pendingSender = nil
                pendingTimestamp = nil
                pendingServiceAliasSuffixCandidate = false
                previousTextRowBox = nil
                previousServiceAliasSuffixCandidate = false
            }

            let textLines = sorted.filter { !$0.text.hasPrefix(imagePrefix) }
            let serviceRow = pendingSender == "service"
                || (pendingSender == nil && previousTextRowBox != nil && messages.last?.sender == "service")
            let retained = textLines.filter {
                !isConfirmedToolbarNoise($0, imageHeight: imageHeight)
                    && !(serviceRow && isReadStatusToolbar($0, in: textLines))
            }
            guard !retained.isEmpty else { continue }
            var text = retained.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let readStatus: String?
            if text.hasSuffix("未读") {
                readStatus = "未读"
                text.removeLast(2)
            } else if text.hasSuffix("已读") {
                readStatus = "已读"
                text.removeLast(2)
            } else {
                readStatus = nil
            }
            let combinedBox = retained.dropFirst().reduce(retained[0].box) {
                $0.union($1.box)
            }
            if pendingSender == nil,
               pendingTimestamp == nil,
               let previousBox = previousTextRowBox,
               let lastIndex = messages.indices.last,
               messages[lastIndex].type == "text",
               (messages[lastIndex].sender != "unknown" || previousServiceAliasSuffixCandidate),
               messages[lastIndex].timestamp != nil {
                let rowHeight = max(previousBox.height, combinedBox.height)
                let verticalGap = combinedBox.minY - previousBox.maxY
                let leftAligned = abs(combinedBox.minX - previousBox.minX) <= rowHeight * 1.25
                let rightAligned = abs(combinedBox.maxX - previousBox.maxX) <= rowHeight * 1.25
                // OCR boxes may slightly overlap even when their text baselines
                // belong to successive wrapped rows (notably mixed Latin/CJK).
                if combinedBox.midY > previousBox.midY,
                   verticalGap >= -min(previousBox.height, combinedBox.height) * 0.25,
                   verticalGap <= rowHeight,
                   leftAligned || rightAligned {
                    let previous = messages[lastIndex]
                    messages[lastIndex] = ParsedChatMessage(
                        sender: previousServiceAliasSuffixCandidate && readStatus == "已读"
                            ? "service" : previous.sender,
                        type: previous.type,
                        value: (previous.value ?? "") + text,
                        path: previous.path,
                        timestamp: previous.timestamp,
                        readStatus: readStatus ?? previous.readStatus
                    )
                    previousTextRowBox = combinedBox
                    continue
                }
            }
            let resolvedSender = pendingServiceAliasSuffixCandidate && readStatus == "已读"
                ? "service"
                : pendingSender ?? inferredSender(box: combinedBox, lines: messageLines)
            messages.append(
                ParsedChatMessage(
                    sender: resolvedSender,
                    type: isCompleteWebURL(text) ? "link" : "text",
                    value: text,
                    path: nil,
                    timestamp: pendingTimestamp,
                    readStatus: readStatus
                )
            )
            previousTextRowBox = combinedBox
            previousServiceAliasSuffixCandidate = pendingServiceAliasSuffixCandidate
            pendingSender = nil
            pendingTimestamp = nil
            pendingServiceAliasSuffixCandidate = false
        }

        return ParsedChatResult(rawOCR: raw, messages: messages)
    }

    private static func isCompleteWebURL(_ text: String) -> Bool {
        guard !text.hasSuffix(".."), !text.contains("…"),
              let components = URLComponents(string: text),
              components.scheme == "http" || components.scheme == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }

    private static func displayText(_ line: OCRLine) -> String {
        line.text.hasPrefix(imagePrefix) ? "[图片]" : line.text
    }

    private static func isInsideDetectedImage(_ box: CGRect, imageBox: CGRect) -> Bool {
        guard box.width > 0, box.height > 0 else { return imageBox.contains(box.origin) }
        if imageBox.contains(CGPoint(x: box.midX, y: box.midY)) { return true }
        let intersection = box.intersection(imageBox)
        guard !intersection.isNull else { return false }
        return intersection.width * intersection.height >= box.width * box.height * 0.5
    }

    private static func visualRows(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.sorted {
            if $0.box.midY != $1.box.midY { return $0.box.midY < $1.box.midY }
            return $0.box.minX < $1.box.minX
        }
        var rows: [[OCRLine]] = []
        for line in sorted {
            // Require compatible centers with every member. A tall toolbar
            // box must not bridge two neighboring text rows via their union.
            if let index = rows.indices.last {
                let row = rows[index]
                // A small dot/quote follows its nearest word, but cannot act
                // as an anchor that pulls the next text row into this one.
                let anchors = row.filter { member in
                    !row.contains { isAdjacentSmallPunctuation(member, beside: $0) }
                }
                let sameBand = anchors.allSatisfy {
                    abs($0.box.midY - line.box.midY) <= min($0.box.height, line.box.height) * 0.5
                }
                let trailingPunctuation = anchors.contains { isAdjacentSmallPunctuation(line, beside: $0) }
                let leadingPunctuation = anchors.count == 1
                    && isAdjacentSmallPunctuation(anchors[0], beside: line)
                if sameBand || trailingPunctuation || leadingPunctuation {
                    rows[index].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows
    }

    private static func isAdjacentSmallPunctuation(_ small: OCRLine, beside large: OCRLine) -> Bool {
        let gap = max(small.box.minX - large.box.maxX, large.box.minX - small.box.maxX)
        return isPunctuationOnly(small.text) && large.box.height > 0
            && small.box.height <= large.box.height * 0.5
            && small.box.width <= large.box.height * 0.75
            && gap >= 0 && gap <= large.box.height * 0.75
            && small.box.minY >= large.box.minY && small.box.maxY <= large.box.maxY
    }

    private static func metadata(
        from row: [OCRLine],
        serviceAliases: Set<String>?
    ) -> (
        sender: String,
        timestamp: String,
        locksUnknown: Bool,
        serviceAliasSuffixCandidate: Bool
    )? {
        let compact = row.map(\.text).joined()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "：", with: ":")
        let pattern = #"(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})(\d{1,2}:\d{2}:\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: compact,
                range: NSRange(compact.startIndex..., in: compact)
              ),
              let dateRange = Range(match.range(at: 1), in: compact),
              let timeRange = Range(match.range(at: 2), in: compact) else {
            return nil
        }
        let sender: String
        var locksUnknown = false
        let serviceAliasSuffixCandidate = false
        let arrowRange = ["-->", "->", "—>", "→"]
            .compactMap { compact.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        if let arrowRange {
            let senderLabel = compact[..<arrowRange.lowerBound]
            sender = serviceAliases == nil && senderLabel.contains("旗舰店") ? "service" : "customer"
        } else if compact.range(
            of: #"^[A-Za-z][A-Za-z0-9_.@-]{3,63}>[^>]*旗舰店"#,
            options: .regularExpression
        ) != nil {
            // OCR occasionally collapses the arrow to a single `>`. A plausible
            // account before the store is stronger customer evidence than a
            // configured service alias appearing later in the same header.
            sender = "customer"
        } else if let serviceAliases {
            let label = String(compact[..<dateRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trailingName = label.split(separator: ":", omittingEmptySubsequences: true).last.map(String.init)
            locksUnknown = label.contains(":")
            sender = serviceAliases.contains(label)
                || trailingName.map(serviceAliases.contains) == true
                || trailingName.map { observed in
                    serviceAliases.contains { alias in
                        alias.count > 1 && alias.first == "小"
                            && String(alias.dropFirst()) == observed
                    }
                } == true
                || serviceAliases.contains(where: {
                    label.count > $0.count && label.hasSuffix($0)
                })
                ? "service" : "customer"
        } else if compact.contains("旗舰店") {
            sender = "service"
        } else if row.contains(where: { line in
            CustomerIdentityExtractor.isAccountLike(
                line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }) {
            sender = "customer"
        } else {
            sender = "unknown"
        }
        return (
            sender,
            "\(compact[dateRange]) \(compact[timeRange])",
            locksUnknown,
            serviceAliasSuffixCandidate
        )
    }

    private static func isConfirmedToolbarNoise(_ line: OCRLine, imageHeight: CGFloat) -> Bool {
        guard imageHeight > 0,
              line.box.midY >= imageHeight * 0.82,
              line.box.width <= 14,
              line.box.height <= 10,
              (line.confidence ?? 1) < 0.5 else {
            return false
        }
        return line.text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    private static func isReadStatusToolbar(_ line: OCRLine, in row: [OCRLine]) -> Bool {
        // Only a separate, low-confidence symbol block immediately beyond a
        // standalone service read-status label. Never strip symbols in body text.
        guard (line.confidence ?? 1) < 0.9, isPunctuationOnly(line.text) else { return false }
        return row.contains { status in
            let label = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let height = status.box.height
            let gap = line.box.minX - status.box.maxX
            return (label == "已读" || label == "未读") && height > 0
                && gap >= height * 0.75 && gap <= height * 3
                && line.box.width >= height * 1.5 && line.box.width <= height * 6
                && line.box.height <= height * 2
                && abs(line.box.midY - status.box.midY) <= height * 0.5
        }
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    private static func isLikelyClippedTimestampFragment(_ text: String) -> Bool {
        let digitCount = text.unicodeScalars.count {
            CharacterSet.decimalDigits.contains($0)
        }
        let separators = CharacterSet(charactersIn: "-/:.∠")
        let separatorCount = text.unicodeScalars.count { separators.contains($0) }
        return digitCount >= 8 && separatorCount >= 3
    }

    private static func hasJoinedAccountPrefixBeforeTimestamp(_ row: [OCRLine]) -> Bool {
        let compact = row.map(\.text).joined()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "：", with: ":")
        guard let regex = try? NSRegularExpression(
            pattern: #"\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\d{1,2}:\d{2}:\d{2}"#
        ), let match = regex.firstMatch(
            in: compact,
            range: NSRange(compact.startIndex..., in: compact)
        ), let dateRange = Range(match.range, in: compact) else {
            return false
        }
        return CustomerIdentityExtractor.isAccountLike(String(compact[..<dateRange.lowerBound]))
    }

    private static func inferredSender(box: CGRect, lines: [OCRLine]) -> String {
        guard let minX = lines.map(\.box.minX).min(),
              let maxX = lines.map(\.box.maxX).max(),
              maxX > minX else {
            return "unknown"
        }
        let center = (minX + maxX) / 2
        if box.maxX < center { return "customer" }
        if box.minX > center { return "service" }
        return "unknown"
    }
}
