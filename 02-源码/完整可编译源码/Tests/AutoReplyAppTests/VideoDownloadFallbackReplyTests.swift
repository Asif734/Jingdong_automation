import XCTest
@testable import AutoReplyApp

final class VideoDownloadFallbackReplyTests: XCTestCase {
    func testPreparedFallbackIsTruthfulAndStable() {
        XCTAssertEqual(
            VideoDownloadFallbackReply.text,
            "亲，视频暂时加载失败，麻烦您重新发送一次或简单描述一下问题，我这边继续帮您查看。"
        )
        XCTAssertEqual(
            VideoDownloadFallbackReply.revision(messageHash: "safe-hash"),
            "video-download-fallback:safe-hash"
        )
        XCTAssertEqual(VideoDownloadFallbackReply.envelope.decision, .autoSend)
        XCTAssertEqual(VideoDownloadFallbackReply.envelope.riskLevel, .low)
        XCTAssertEqual(VideoDownloadFallbackReply.envelope.replyText, VideoDownloadFallbackReply.text)
    }

    func testSyntheticHistoryContainsNoAddressOrRawMessageIdentifier() {
        let history = VideoDownloadFallbackReply.historyJSONL
        XCTAssertTrue(history.contains("video_download_temporarily_unavailable"))
        XCTAssertFalse(history.contains("http"))
        XCTAssertFalse(history.contains("auth_key"))
        XCTAssertFalse(history.contains("messageId"))
    }
}
