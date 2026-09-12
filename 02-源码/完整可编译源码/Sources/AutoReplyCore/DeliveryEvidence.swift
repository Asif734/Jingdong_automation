import Foundation

public enum DeliveryObservation: Equatable, Sendable {
    case exactReplyFound
    case stableReplyAbsent
    case unavailable
}

public enum DeliveryEvidence {
    public static func exactServiceReplyFound(
        in historyJSONL: String,
        replyText: String,
        afterCustomerCount: Int = 0
    ) -> Bool {
        let expected = normalized(replyText)
        guard !expected.isEmpty else { return false }
        var customerCount = 0
        for line in historyJSONL.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let sender = object["sender"] as? String else { continue }
            if sender == "customer" {
                customerCount += 1
                continue
            }
            guard sender == "service", customerCount > afterCustomerCount,
                  let value = object["v"] as? String else { continue }
            if normalized(value) == expected { return true }
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
