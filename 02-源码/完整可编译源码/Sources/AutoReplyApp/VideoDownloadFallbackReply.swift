import CustomerReplyBatchCore
import Foundation

enum VideoDownloadFallbackReply {
    static let text = "亲，视频暂时加载失败，麻烦您重新发送一次或简单描述一下问题，我这边继续帮您查看。"

    static let historyJSONL =
        #"{"sender":"customer","t":"video_download_temporarily_unavailable","v":"客户发送了视频，但视频文件暂时无法加载。"}"#

    static let envelope = ReplyEnvelope(
        decision: .autoSend,
        riskLevel: .low,
        replyText: text,
        reason: "视频文件暂时无法加载时的固定、真实且可恢复客服提示"
    )

    static func revision(messageHash: String) -> String {
        "video-download-fallback:\(messageHash)"
    }
}
