import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class ResilientVideoDownloaderTests: XCTestCase {
    func testTimeoutMapsToConnectCategoryWithoutLeakingSignedURL() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let transport = ScriptedSystemTransport(result: .failure(URLError(.timedOut)))
        let downloader = SystemRouteVideoDownloader(transport: transport)

        do {
            _ = try await downloader.download(fixture.approvedURL, to: fixture.outputURL)
            XCTFail("Expected the timed-out request to fail")
        } catch let error as VideoTransferAttemptError {
            XCTAssertEqual(error.category, .connectTimeout)
            XCTAssertTrue(error.isRetryable)
            XCTAssertFalse(error.sanitizedDescription.contains("auth_key"))
            XCTAssertFalse(error.sanitizedDescription.contains("TOP_SECRET"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
    }

    func testUnapprovedSourceIsRejectedBeforeNetworkTransportRuns() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let transport = ScriptedSystemTransport(result: .success(.approved()))
        let downloader = SystemRouteVideoDownloader(transport: transport)
        let evil = try XCTUnwrap(URL(string: "https://evil.example/video.mp4?auth_key=SECRET"))

        do {
            _ = try await downloader.download(evil, to: fixture.outputURL)
            XCTFail("Expected an unapproved source to fail")
        } catch let error as VideoTransferAttemptError {
            XCTAssertEqual(error.category, .redirectRejected)
            XCTAssertFalse(error.isRetryable)
        }
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testRedirectedResponseHostIsRejectedAndPartialFileIsRemoved() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let redirected = try XCTUnwrap(URL(string: "https://evil.example/video.mp4"))
        let transport = ScriptedSystemTransport(
            result: .success(.approved(finalURL: redirected)),
            body: Data("not-published".utf8)
        )
        let downloader = SystemRouteVideoDownloader(transport: transport)

        do {
            _ = try await downloader.download(fixture.approvedURL, to: fixture.outputURL)
            XCTFail("Expected cross-host redirect to fail")
        } catch let error as VideoTransferAttemptError {
            XCTAssertEqual(error.category, .redirectRejected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
    }

    func testSuccessfulVideoResponsePublishesBytesAndUsesBoundedPolicy() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let body = Data("video-bytes".utf8)
        let transport = ScriptedSystemTransport(
            result: .success(.approved()),
            body: body
        )
        let downloader = SystemRouteVideoDownloader(transport: transport)

        let result = try await downloader.download(fixture.approvedURL, to: fixture.outputURL)

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.bytes, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: fixture.outputURL), body)
        let capturedPolicy = await transport.lastPolicy
        let policy = try XCTUnwrap(capturedPolicy)
        XCTAssertEqual(policy.connectTimeout, 5)
        XCTAssertEqual(policy.totalTimeout, 15)
        XCTAssertFalse(policy.waitsForConnectivity)
    }

    func testHTMLSuccessResponseIsRejectedAsInvalidContent() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.remove() }
        let transport = ScriptedSystemTransport(
            result: .success(.approved(mimeType: "text/html")),
            body: Data("<html/>".utf8)
        )
        let downloader = SystemRouteVideoDownloader(transport: transport)

        do {
            _ = try await downloader.download(fixture.approvedURL, to: fixture.outputURL)
            XCTFail("Expected HTML content to fail")
        } catch let error as VideoTransferAttemptError {
            XCTAssertEqual(error.category, .invalidContent)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputURL.path))
    }
}

private struct DownloadFixture {
    let root: URL
    let approvedURL: URL
    let outputURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        approvedURL = try XCTUnwrap(URL(
            string: "https://msg2.cloudvideocdn.taobao.com/video.mp4?auth_key=TOP_SECRET"
        ))
        outputURL = root.appendingPathComponent("result.partial.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ScriptedSystemTransport: SystemVideoHTTPTransport {
    private let result: Result<SystemVideoHTTPTransfer, Error>
    private let body: Data
    private(set) var callCount = 0
    private(set) var lastPolicy: SystemVideoDownloadPolicy?

    init(result: Result<SystemVideoHTTPTransfer, Error>, body: Data = Data("video".utf8)) {
        self.result = result
        self.body = body
    }

    func download(
        _ source: URL,
        to destination: URL,
        policy: SystemVideoDownloadPolicy
    ) async throws -> SystemVideoHTTPTransfer {
        callCount += 1
        lastPolicy = policy
        let value = try result.get()
        try body.write(to: destination, options: .atomic)
        return value
    }
}

private extension SystemVideoHTTPTransfer {
    static func approved(
        finalURL: URL = URL(string: "https://msg2.cloudvideocdn.taobao.com/video.mp4")!,
        mimeType: String? = "video/mp4"
    ) -> SystemVideoHTTPTransfer {
        SystemVideoHTTPTransfer(
            finalURL: finalURL,
            statusCode: 200,
            mimeType: mimeType,
            elapsedMilliseconds: 12
        )
    }
}
