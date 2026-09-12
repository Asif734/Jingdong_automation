import Foundation
import QianniuOCRCore

public struct AutomationCaptureReceipt: Sendable {
    public let uid: String
    public let queueEntryURL: URL?
    public let historyURL: URL
    public let latestSpeaker: String?
    public init(uid: String, queueEntryURL: URL?, historyURL: URL, latestSpeaker: String?) {
        self.uid = uid; self.queueEntryURL = queueEntryURL; self.historyURL = historyURL; self.latestSpeaker = latestSpeaker
    }
}

public actor AutomationCaptureBridge {
    private let root: URL
    private let exporter: CustomerRequestPackageExporter
    public init(rootDirectory: URL) {
        root = rootDirectory
        exporter = CustomerRequestPackageExporter(rootDirectory: rootDirectory, queueTrigger: nil)
    }
    public func export(
        result: OCRRunResult,
        expectedUID: String,
        serviceAliases: Set<String>? = nil,
        routedIdentityConfirmed: Bool = false
    ) async throws -> AutomationCaptureReceipt {
        let candidates = CustomerIdentityCandidates(axHeader: result.identityCandidates.axHeader,
            axSessionList: result.identityCandidates.axSessionList,
            ocr: result.identityCandidates.ocr ?? CustomerIdentityExtractor.detectedValue(from: result.lines, imageHeight: result.sourceImageSize.height))
        let resolved = CustomerIdentityResolver.resolve(candidates: candidates, requestID: "automation-validation")
        guard !expectedUID.isEmpty, expectedUID != ".", expectedUID != "..", !expectedUID.contains("/"),
              !expectedUID.contains("\\"), !expectedUID.contains("..."), !expectedUID.contains("…"),
              !expectedUID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              routedIdentityConfirmed || (resolved.identity.status == .detected && resolved.identity.value == expectedUID),
              expectedUID == expectedUID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AutomationCaptureError.identityMismatch
        }
        let exportResult: OCRRunResult
        if routedIdentityConfirmed {
            exportResult = OCRRunResult(
                lines: result.lines,
                images: result.images,
                sourceImageSize: result.sourceImageSize,
                identityCandidates: CustomerIdentityCandidates(
                    axHeader: expectedUID,
                    axSessionList: expectedUID,
                    ocr: expectedUID
                )
            )
        } else {
            exportResult = result
        }
        let user = root.appendingPathComponent("用户/\(expectedUID)")
        guard user.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/用户/") else {
            throw AutomationCaptureError.identityMismatch
        }
        let parsed = ParsedChatParser.parse(lines: exportResult.lines, imageBoxes: exportResult.images.map(\.box),
            imageHeight: exportResult.sourceImageSize.height, serviceAliases: serviceAliases)
        let latest = parsed.messages.last(where: { $0.sender == "customer" || $0.sender == "service" })?.sender
        let queue = try await exporter.export(result: exportResult, serviceAliases: serviceAliases)
        return AutomationCaptureReceipt(uid: expectedUID, queueEntryURL: queue,
            historyURL: user.appendingPathComponent("history.jsonl"), latestSpeaker: latest)
    }
}

public enum AutomationCaptureError: LocalizedError {
    case identityMismatch
    public var errorDescription: String? { "当前完整 UID 与采集身份不一致或不安全；未导出" }
}
