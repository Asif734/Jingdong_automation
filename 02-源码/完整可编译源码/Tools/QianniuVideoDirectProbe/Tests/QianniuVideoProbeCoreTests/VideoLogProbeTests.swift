import Foundation
import XCTest
@testable import QianniuVideoProbeCore

final class VideoLogProbeTests: XCTestCase {
    func testExtractsOnlySignedQianniuHTTPSMP4URL() throws {
        let line = "[WEB][CreateBrowser] url=https://msg2.cloudvideocdn.taobao.com/aus/msg_video/test/video.mp4?auth_key=TOP_SECRET&biz=message,wnd=42"

        let candidate = try XCTUnwrap(VideoLogProbe.extractCandidate(from: line))

        XCTAssertEqual(candidate.host, "msg2.cloudvideocdn.taobao.com")
        XCTAssertEqual(candidate.path, "/aus/msg_video/test/video.mp4")
        XCTAssertEqual(URLComponents(url: candidate, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "auth_key")
        XCTAssertNil(VideoLogProbe.extractCandidate(from: "url=http://msg2.cloudvideocdn.taobao.com/test.mp4?auth_key=x"))
        XCTAssertNil(VideoLogProbe.extractCandidate(from: "url=https://evil.example/test.mp4?auth_key=x"))
        XCTAssertNil(VideoLogProbe.extractCandidate(from: "url=https://msg2.cloudvideocdn.taobao.com/test.jpg?auth_key=x"))
    }

    func testTailCursorIgnoresOldContentAndReassemblesSplitNewLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("app.log")
        try Data("old-video-line\n".utf8).write(to: log)
        var cursor = try LogTailCursor(url: log, startAtEnd: true)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new-video".utf8))
        XCTAssertEqual(try cursor.readCompleteLines(), [])
        try handle.write(contentsOf: Data("-line\nnext-line\n".utf8))
        try handle.close()

        XCTAssertEqual(try cursor.readCompleteLines(), ["new-video-line", "next-line"])
    }

    func testEncodedReportCannotContainSignedURLOrAuthenticationQuery() throws {
        let report = SanitizedProbeReport(
            machine: .init(macOS: "26.6.2", architecture: "arm64", qianniuVersion: "9.97.74"),
            result: .passed,
            discoveryMilliseconds: 820,
            downloadMilliseconds: 1400,
            httpStatus: 200,
            file: .init(
                name: "客户视频.mp4",
                bytes: 511_771,
                sha256: "012345",
                durationSeconds: 4.3667,
                width: 720,
                height: 1280,
                videoCodec: "H.264",
                audioCodec: "AAC"
            ),
            failure: nil
        )

        let encoded = try JSONEncoder().encode(report)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("auth_key"))
        XCTAssertFalse(text.contains("sessionkey"))
        XCTAssertTrue(text.contains("511771"))
    }

    func testSHA256UsesFileBytesInsteadOfFileName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("任意名称.mp4")
        try Data("abc".utf8).write(to: file)

        XCTAssertEqual(
            try FileSHA256.hexDigest(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testInspectorRejectsHTMLOrTextSavedWithMP4Extension() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("错误页面.mp4")
        try Data("<html>expired</html>".utf8).write(to: file)

        do {
            _ = try await VideoFileInspector.inspect(file)
            XCTFail("an HTTP error page must not pass as a customer video")
        } catch let error as VideoProbeError {
            XCTAssertEqual(error, .invalidMedia)
        }
    }

    func testDownloadPolicyRejectsSuccessfulHTMLResponse() {
        XCTAssertTrue(VideoDownloadPolicy.accepts(statusCode: 200, mimeType: "video/mp4"))
        XCTAssertTrue(VideoDownloadPolicy.accepts(statusCode: 206, mimeType: nil))
        XCTAssertFalse(VideoDownloadPolicy.accepts(statusCode: 403, mimeType: "video/mp4"))
        XCTAssertFalse(VideoDownloadPolicy.accepts(statusCode: 200, mimeType: "text/html"))
    }

    func testDownloadSessionPolicyDoesNotImposeShortVideoCutoff() {
        let configuration = VideoDownloadSessionPolicy.makeConfiguration()

        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 24 * 60 * 60)
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, 24 * 60 * 60)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    func testArmedWatcherCanWaitWithoutADeadlineUntilVideoAddressAppears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("app.log")
        try Data().write(to: log)
        var armed = try VideoCandidateWatcher(pollInterval: .milliseconds(5)).arm(in: log)

        let task = Task { try await armed.wait() }
        try await Task.sleep(for: .milliseconds(50))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "url=https://msg2.cloudvideocdn.taobao.com/no-deadline.mp4?auth_key=SECRET\n".utf8
        ))
        try handle.close()

        let result = try await task.value
        XCTAssertEqual(result.path, "/no-deadline.mp4")
    }

    func testMarkdownReportContainsEvidenceButNoCredentialFields() {
        let report = SanitizedProbeReport(
            machine: .init(macOS: "26.6.2", architecture: "arm64", qianniuVersion: "9.97.74"),
            result: .passed,
            discoveryMilliseconds: 820,
            downloadMilliseconds: 1400,
            httpStatus: 200,
            file: .init(
                name: "下载的视频.mp4", bytes: 511_771, sha256: "012345",
                durationSeconds: 4.3667, width: 720, height: 1280,
                videoCodec: "H.264", audioCodec: "AAC"
            ),
            failure: nil
        )

        let markdown = ProbeReportMarkdown.render(report)

        XCTAssertTrue(markdown.contains("PASS"))
        XCTAssertTrue(markdown.contains("4.367"))
        XCTAssertTrue(markdown.contains("720 × 1280"))
        XCTAssertFalse(markdown.contains("https://"))
        XCTAssertFalse(markdown.contains("auth_key"))
        XCTAssertFalse(markdown.contains("sessionkey"))
    }

    func testWatcherReturnsOnlyVideoURLAppendedAfterItStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("app.log")
        let old = "url=https://msg2.cloudvideocdn.taobao.com/old.mp4?auth_key=OLD\n"
        try Data(old.utf8).write(to: log)
        let watcher = VideoCandidateWatcher(pollInterval: .milliseconds(10))

        let task = Task { try await watcher.waitForNewCandidate(in: log, timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(50))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let new = "url=https://msg2.cloudvideocdn.taobao.com/new.mp4?auth_key=NEW,wnd=1\n"
        try handle.write(contentsOf: Data(new.utf8))
        try handle.close()

        let result = try await task.value
        XCTAssertEqual(result.path, "/new.mp4")
    }

    func testArmedWatcherDoesNotMissURLWrittenBeforeAsyncWaitBegins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("app.log")
        try Data("old-line\n".utf8).write(to: log)
        var armed = try VideoCandidateWatcher(pollInterval: .milliseconds(5)).arm(in: log)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "url=https://msg2.cloudvideocdn.taobao.com/armed.mp4?auth_key=SECRET\n".utf8
        ))
        try handle.close()

        let result = try await armed.wait(timeout: .milliseconds(100))

        XCTAssertEqual(result.path, "/armed.mp4")
    }

    func testArmedWatcherReadsNewURLFromActiveOldLog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("app.log")
        let old = root.appendingPathComponent("app.log.old")
        try Data("stale-current\n".utf8).write(to: current)
        try Data("old-before-arm\n".utf8).write(to: old)
        var armed = try VideoCandidateWatcher(pollInterval: .milliseconds(5))
            .arm(in: [current, old])

        let handle = try FileHandle(forWritingTo: old)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "url=https://msg2.cloudvideocdn.taobao.com/from-old.mp4?auth_key=SECRET\n".utf8
        ))
        try handle.close()

        let result = try await armed.wait(timeout: .milliseconds(100))

        XCTAssertEqual(result.path, "/from-old.mp4")
    }

    func testArmedWatcherFollowsLogRotationWithoutReturningPreArmURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("app.log")
        let old = root.appendingPathComponent("app.log.old")
        try Data(
            "url=https://msg2.cloudvideocdn.taobao.com/pre-arm.mp4?auth_key=OLD\n".utf8
        ).write(to: current)
        try Data("older-archive\n".utf8).write(to: old)
        var armed = try VideoCandidateWatcher(pollInterval: .milliseconds(5))
            .arm(in: [current, old])

        try FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: current, to: old)
        try Data("new-current\n".utf8).write(to: current)
        let handle = try FileHandle(forWritingTo: old)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "url=https://msg2.cloudvideocdn.taobao.com/post-rotation.mp4?auth_key=NEW\n".utf8
        ))
        try handle.close()

        let result = try await armed.wait(timeout: .milliseconds(100))

        XCTAssertEqual(result.path, "/post-rotation.mp4")
    }

    func testWatcherTimesOutWithoutPersistingAnyCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("app.log")
        try Data().write(to: log)
        let watcher = VideoCandidateWatcher(pollInterval: .milliseconds(5))

        do {
            _ = try await watcher.waitForNewCandidate(in: log, timeout: .milliseconds(30))
            XCTFail("a silent log must time out")
        } catch let error as VideoProbeError {
            XCTAssertEqual(error, .timedOut)
        }
    }
}
