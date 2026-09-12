import Foundation
import XCTest
@testable import QianniuOCRAppSupport

final class VideoAlternateRouteTests: XCTestCase {
    func testRaceValidatesDownloadedBytesThroughATemporaryMP4URL() async throws {
        let fixture = try AlternateRouteFixture()
        defer { fixture.remove() }
        let downloader = ScriptedResolvedDownloader(scripts: [
            "1.1.1.1": .success(after: .milliseconds(1), body: Data("video".utf8))
        ])
        let race = AlternateRouteRace(
            downloader: downloader,
            validate: { url in
                guard url.pathExtension.lowercased() == "mp4" else {
                    throw VideoTransferAttemptError(
                        category: .invalidVideo,
                        isRetryable: false,
                        sanitizedDescription: "AVFoundation requires an MP4 file extension"
                    )
                }
            }
        )

        let receipt = try await race.downloadFirstValid(
            source: fixture.signedURL,
            candidates: [AlternateVideoRoute(
                address: "1.1.1.1",
                poolID: "a",
                family: .ipv4
            )],
            destination: fixture.outputURL
        )

        XCTAssertEqual(receipt.fileURL, fixture.outputURL)
    }

    func testResolverReturnsAtMostThreePublicAddressesFromTwoResolverPools() async throws {
        let dns = ScriptedDNSQuery(results: [
            "223.5.5.5": ["1.1.1.1", "10.0.0.8", "1.1.1.1"],
            "119.29.29.29": ["2606:4700:4700::1111", "8.8.8.8"]
        ])
        let provider = AlternateVideoRouteProvider(query: dns)

        let routes = try await provider.candidates(for: "msg2.cloudvideocdn.taobao.com")

        XCTAssertEqual(routes.count, 3)
        XCTAssertGreaterThanOrEqual(Set(routes.map(\.poolID)).count, 2)
        XCTAssertTrue(routes.allSatisfy(\.isPublicAddress))
        XCTAssertFalse(routes.contains { $0.address == "10.0.0.8" })
    }

    func testResolverRejectsUnapprovedHostWithoutExecutingDig() async throws {
        let dns = ScriptedDNSQuery(results: ["223.5.5.5": ["1.1.1.1"]])
        let provider = AlternateVideoRouteProvider(query: dns)

        do {
            _ = try await provider.candidates(for: "evil.example")
            XCTFail("Expected unapproved host to be rejected")
        } catch let error as VideoTransferAttemptError {
            XCTAssertEqual(error.category, .redirectRejected)
        }
        let calls = await dns.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCurlReceivesSignedURLOnlyOnSensitiveStdin() async throws {
        let fixture = try AlternateRouteFixture()
        defer { fixture.remove() }
        let runner = RecordingProcessRunner(body: Data("video".utf8))
        let downloader = CurlResolvedVideoDownloader(runner: runner)

        let result = try await downloader.download(
            source: fixture.signedURL,
            resolvedAddress: "93.184.216.34",
            destination: fixture.outputURL
        )

        XCTAssertEqual(result.bytes, 5)
        let capturedInvocation = await runner.invocation
        let invocation = try XCTUnwrap(capturedInvocation)
        XCTAssertEqual(invocation.executable, "/usr/bin/curl")
        XCTAssertTrue(invocation.arguments.contains("--resolve"))
        XCTAssertFalse(invocation.arguments.joined(separator: " ").contains("auth_key"))
        let standardInput = String(decoding: invocation.sensitiveStandardInput ?? Data(), as: UTF8.self)
        XCTAssertTrue(standardInput.contains("auth_key=TOP_SECRET"))
        XCTAssertFalse(invocation.wasLogged)
    }

    func testCurlRejectsPrivateResolvedAddressBeforeSpawningProcess() async throws {
        let fixture = try AlternateRouteFixture()
        defer { fixture.remove() }
        let runner = RecordingProcessRunner(body: Data("video".utf8))
        let downloader = CurlResolvedVideoDownloader(runner: runner)

        do {
            _ = try await downloader.download(
                source: fixture.signedURL,
                resolvedAddress: "192.168.1.10",
                destination: fixture.outputURL
            )
            XCTFail("Expected private address to be rejected")
        } catch let error as VideoTransferAttemptError {
            XCTAssertEqual(error.category, .dnsResolution)
        }
        let invocation = await runner.invocation
        XCTAssertNil(invocation)
    }

    func testRacePublishesFirstValidWinnerAndCancelsLosingDownloads() async throws {
        let fixture = try AlternateRouteFixture()
        defer { fixture.remove() }
        let downloader = ScriptedResolvedDownloader(scripts: [
            "1.1.1.1": .success(after: .milliseconds(200), body: Data("slow-a".utf8)),
            "8.8.8.8": .success(after: .milliseconds(10), body: Data("winner".utf8)),
            "9.9.9.9": .success(after: .milliseconds(200), body: Data("slow-b".utf8))
        ])
        let race = AlternateRouteRace(
            downloader: downloader,
            validate: { url in
                guard try Data(contentsOf: url) == Data("winner".utf8) else {
                    throw VideoTransferAttemptError(
                        category: .invalidVideo,
                        isRetryable: false,
                        sanitizedDescription: "invalid video"
                    )
                }
            }
        )
        let routes = [
            AlternateVideoRoute(address: "1.1.1.1", poolID: "a", family: .ipv4),
            AlternateVideoRoute(address: "8.8.8.8", poolID: "b", family: .ipv4),
            AlternateVideoRoute(address: "9.9.9.9", poolID: "c", family: .ipv4)
        ]

        let receipt = try await race.downloadFirstValid(
            source: fixture.signedURL,
            candidates: routes,
            destination: fixture.outputURL
        )

        XCTAssertEqual(receipt.route.poolID, "b")
        XCTAssertEqual(try Data(contentsOf: fixture.outputURL), Data("winner".utf8))
        try await Task.sleep(for: .milliseconds(20))
        let cancelled = await downloader.cancelledAddresses
        XCTAssertEqual(Set(cancelled), ["1.1.1.1", "9.9.9.9"])
        let partials = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("partial") }
        XCTAssertTrue(partials.isEmpty)
    }
}

private actor ScriptedDNSQuery: AlternateDNSQuerying {
    private let results: [String: [String]]
    private(set) var calls: [String] = []

    init(results: [String: [String]]) {
        self.results = results
    }

    func addresses(host: String, server: String, timeout: Duration) async throws -> [String] {
        calls.append("\(host)@\(server)")
        return results[server] ?? []
    }
}

private actor RecordingProcessRunner: ProcessRunning {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let sensitiveStandardInput: Data?
        let wasLogged: Bool
    }

    private let body: Data
    private(set) var invocation: Invocation?

    init(body: Data) {
        self.body = body
    }

    func spawn(
        executable: String,
        arguments: [String],
        sensitiveStandardInput: Data?,
        processGroup: Bool
    ) async throws -> any RunningProcess {
        invocation = Invocation(
            executable: executable,
            arguments: arguments,
            sensitiveStandardInput: sensitiveStandardInput,
            wasLogged: false
        )
        let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "--output")) + 1
        let output = URL(fileURLWithPath: arguments[outputIndex])
        try body.write(to: output, options: .atomic)
        return FinishedTestProcess()
    }
}

private struct FinishedTestProcess: RunningProcess {
    let processGroupID: Int32 = 123
    func wait() async -> SanitizedProcessResult {
        SanitizedProcessResult(exitStatus: 0, stderrCategory: nil)
    }
    func terminate(grace: Duration) async {}
}

private actor ScriptedResolvedDownloader: ResolvedVideoDownloading {
    enum Script: Sendable {
        case success(after: Duration, body: Data)
    }

    private let scripts: [String: Script]
    private(set) var cancelledAddresses: [String] = []

    init(scripts: [String: Script]) {
        self.scripts = scripts
    }

    func download(
        source: URL,
        resolvedAddress: String,
        destination: URL
    ) async throws -> VideoDownloadAttemptResult {
        guard let script = scripts[resolvedAddress] else {
            throw VideoTransferAttemptError(
                category: .dnsResolution,
                isRetryable: true,
                sanitizedDescription: "missing script"
            )
        }
        do {
            switch script {
            case .success(let delay, let body):
                try await Task.sleep(for: delay)
                try body.write(to: destination, options: .atomic)
                return VideoDownloadAttemptResult(
                    statusCode: 200,
                    elapsedMilliseconds: 10,
                    bytes: Int64(body.count)
                )
            }
        } catch is CancellationError {
            cancelledAddresses.append(resolvedAddress)
            throw CancellationError()
        }
    }
}

private struct AlternateRouteFixture {
    let root: URL
    let signedURL: URL
    let outputURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        signedURL = try XCTUnwrap(URL(
            string: "https://msg2.cloudvideocdn.taobao.com/video.mp4?auth_key=TOP_SECRET"
        ))
        outputURL = root.appendingPathComponent("winner.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
