import Foundation
import AutoReplyCore
import QianniuOCRAppSupport

enum VideoAnalysisSnapshotFactory {
    static func make(
        receipt: DownloadedCustomerVideo,
        manifest: CustomerVideoEvidenceManifest,
        evidenceRoot: URL,
        knowledgeBasePaths: [String]
    ) throws -> CaptureSnapshot {
        let framePaths = manifest.frames.map { evidenceRoot.appendingPathComponent($0.fileName).path }
        guard !framePaths.isEmpty, framePaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            throw CustomerVideoEvidenceError.frameExtractionFailed
        }
        let transcript = manifest.transcript.map {
            String(format: "%.2f–%.2f秒：%@", $0.startSeconds, $0.startSeconds + $0.durationSeconds, $0.text)
        }.joined(separator: "；")
        let timestamps = manifest.frames.map { String(format: "%.2f", $0.timestampSeconds) }.joined(separator: "、")
        let description = "客户发送了一段视频。已按播放顺序提取关键画面，时间点（秒）：\(timestamps)。"
            + (transcript.isEmpty ? "没有可靠语音转写。" : "语音转写：\(transcript)")
        let row: [String: Any] = [
            "sender": "customer", "t": "video_evidence", "v": description,
            "video_hash": receipt.messageHash
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return CaptureSnapshot(
            uid: receipt.customerUID,
            customerRevision: "video-analysis:\(receipt.messageHash)",
            historyJSONL: json,
            imagePaths: framePaths,
            knowledgeBasePaths: knowledgeBasePaths,
            hasUnansweredCustomer: true,
            shouldGenerate: true,
            targetCustomerJSONL: json,
            preservesHistoryCheckpoint: true
        )
    }

    static func fallback(receipt: DownloadedCustomerVideo, knowledgeBasePaths: [String]) -> CaptureSnapshot {
        let row = "{\"sender\":\"customer\",\"t\":\"video_evidence_unavailable\",\"v\":\"客户发送了视频，但系统未能提取可靠画面或语音；请询问客户主要希望查看哪个现象或操作步骤，不得假装已经看见视频内容。\"}"
        return CaptureSnapshot(
            uid: receipt.customerUID,
            customerRevision: "video-analysis:\(receipt.messageHash)",
            historyJSONL: row,
            knowledgeBasePaths: knowledgeBasePaths,
            hasUnansweredCustomer: true,
            shouldGenerate: true,
            targetCustomerJSONL: row,
            preservesHistoryCheckpoint: true
        )
    }
}
