import AVFoundation
import CryptoKit
import Foundation

public enum VideoURLPolicy {
    public static let approvedHosts: Set<String> = ["msg2.cloudvideocdn.taobao.com"]

    public static func accepts(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              approvedHosts.contains(host),
              url.pathExtension.lowercased() == "mp4" else { return false }
        return true
    }
}

public enum VideoLogProbe {
    private static let expression = try! NSRegularExpression(
        pattern: #"https://msg2\.cloudvideocdn\.taobao\.com/[^\s,\]\)\"]+"#
    )

    public static func extractCandidate(from line: String) -> URL? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in expression.matches(in: line, range: range) {
            guard let swiftRange = Range(match.range, in: line),
                  let url = URL(string: String(line[swiftRange])),
                  VideoURLPolicy.accepts(url) else { continue }
            return url
        }
        return nil
    }
}

public struct LogTailCursor: Sendable {
    private let url: URL
    private var identity: String
    private var offset: UInt64
    private var remainder = Data()

    public init(url: URL, startAtEnd: Bool) throws {
        self.url = url
        let metadata = try Self.metadata(for: url)
        identity = metadata.identity
        offset = startAtEnd ? metadata.size : 0
    }

    public mutating func readCompleteLines() throws -> [String] {
        let metadata = try Self.metadata(for: url)
        if metadata.identity != identity || metadata.size < offset {
            identity = metadata.identity
            offset = 0
            remainder.removeAll(keepingCapacity: true)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let appended = try handle.readToEnd() ?? Data()
        offset = metadata.size
        guard !appended.isEmpty || !remainder.isEmpty else { return [] }

        let data = remainder + appended
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            remainder = data
            return []
        }
        let complete = data[data.startIndex...lastNewline]
        let next = data.index(after: lastNewline)
        remainder = Data(data[next...])
        return String(decoding: complete, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    private static func metadata(for url: URL) throws -> (identity: String, size: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let system = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return ("\(system):\(file)", size)
    }
}

private struct RotatingLogTailCursor: Sendable {
    private struct Source: Sendable {
        var url: URL
        let identity: String
        var offset: UInt64
        var remainder = Data()
    }

    private let urls: [URL]
    private var sources: [String: Source]

    init(urls: [URL]) throws {
        self.urls = urls
        var initial: [String: Source] = [:]
        for url in urls {
            guard let metadata = try? Self.metadata(for: url) else { continue }
            if initial[metadata.identity] == nil {
                initial[metadata.identity] = Source(
                    url: url,
                    identity: metadata.identity,
                    offset: metadata.size
                )
            }
        }
        guard !initial.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        sources = initial
    }

    mutating func readCompleteLines() throws -> [String] {
        var visibleIdentities: [String] = []
        for url in urls {
            guard let metadata = try? Self.metadata(for: url) else { continue }
            if var source = sources[metadata.identity] {
                source.url = url
                sources[metadata.identity] = source
            } else {
                sources[metadata.identity] = Source(
                    url: url,
                    identity: metadata.identity,
                    offset: 0
                )
            }
            if !visibleIdentities.contains(metadata.identity) {
                visibleIdentities.append(metadata.identity)
            }
        }

        var lines: [String] = []
        for identity in visibleIdentities {
            guard var source = sources[identity] else { continue }
            let metadata = try Self.metadata(for: source.url)
            if metadata.size < source.offset {
                source.offset = 0
                source.remainder.removeAll(keepingCapacity: true)
            }
            let handle = try FileHandle(forReadingFrom: source.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: source.offset)
            let appended = try handle.readToEnd() ?? Data()
            source.offset += UInt64(appended.count)
            if !appended.isEmpty || !source.remainder.isEmpty {
                let data = source.remainder + appended
                if let lastNewline = data.lastIndex(of: 0x0A) {
                    let complete = data[data.startIndex...lastNewline]
                    let next = data.index(after: lastNewline)
                    source.remainder = Data(data[next...])
                    lines += String(decoding: complete, as: UTF8.self)
                        .split(whereSeparator: \Character.isNewline)
                        .map(String.init)
                } else {
                    source.remainder = data
                }
            }
            sources[identity] = source
        }
        return lines
    }

    private static func metadata(for url: URL) throws -> (identity: String, size: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let system = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return ("\(system):\(file)", size)
    }
}

public struct SanitizedProbeReport: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        case passed
        case failed
    }

    public struct Machine: Codable, Equatable, Sendable {
        public let macOS: String
        public let architecture: String
        public let qianniuVersion: String

        public init(macOS: String, architecture: String, qianniuVersion: String) {
            self.macOS = macOS
            self.architecture = architecture
            self.qianniuVersion = qianniuVersion
        }
    }

    public struct FileSummary: Codable, Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
        public let durationSeconds: Double
        public let width: Int
        public let height: Int
        public let videoCodec: String
        public let audioCodec: String?

        public init(
            name: String,
            bytes: Int64,
            sha256: String,
            durationSeconds: Double,
            width: Int,
            height: Int,
            videoCodec: String,
            audioCodec: String?
        ) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.durationSeconds = durationSeconds
            self.width = width
            self.height = height
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
        }
    }

    public let machine: Machine
    public let result: Result
    public let discoveryMilliseconds: Int
    public let downloadMilliseconds: Int
    public let httpStatus: Int?
    public let file: FileSummary?
    public let failure: String?

    public init(
        machine: Machine,
        result: Result,
        discoveryMilliseconds: Int,
        downloadMilliseconds: Int,
        httpStatus: Int?,
        file: FileSummary?,
        failure: String?
    ) {
        self.machine = machine
        self.result = result
        self.discoveryMilliseconds = discoveryMilliseconds
        self.downloadMilliseconds = downloadMilliseconds
        self.httpStatus = httpStatus
        self.file = file
        self.failure = failure
    }
}

public enum VideoProbeError: Error, Equatable, Sendable {
    case invalidMedia
    case missingVideoTrack
    case timedOut
    case downloadRejected
    case downloadFailed
    case outputFailed
}

extension VideoProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMedia: return "下载内容不是有效的MP4视频"
        case .missingVideoTrack: return "下载文件中没有可读取的视频轨道"
        case .timedOut: return "60秒内没有发现新打开的视频地址"
        case .downloadRejected: return "视频服务器拒绝下载或返回了非视频内容"
        case .downloadFailed: return "视频下载失败"
        case .outputFailed: return "测试结果无法写入桌面"
        }
    }
}

public struct VideoCandidateWatcher: Sendable {
    private let pollInterval: Duration

    public init(pollInterval: Duration = .milliseconds(200)) {
        self.pollInterval = pollInterval
    }

    public func arm(in logURL: URL) throws -> ArmedVideoCandidateWatcher {
        try arm(in: [logURL])
    }

    public func arm(in logURLs: [URL]) throws -> ArmedVideoCandidateWatcher {
        ArmedVideoCandidateWatcher(
            cursor: try RotatingLogTailCursor(urls: logURLs),
            pollInterval: pollInterval
        )
    }

    public func waitForNewCandidate(in logURL: URL, timeout: Duration) async throws -> URL {
        var armed = try arm(in: logURL)
        return try await armed.wait(timeout: timeout)
    }
}

public struct ArmedVideoCandidateWatcher: Sendable {
    private var cursor: RotatingLogTailCursor
    private let pollInterval: Duration

    fileprivate init(cursor: RotatingLogTailCursor, pollInterval: Duration) {
        self.cursor = cursor
        self.pollInterval = pollInterval
    }

    public mutating func wait(timeout: Duration) async throws -> URL {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            for line in try cursor.readCompleteLines() {
                if let candidate = VideoLogProbe.extractCandidate(from: line) {
                    return candidate
                }
            }
            try await Task.sleep(for: pollInterval)
        }
        throw VideoProbeError.timedOut
    }

    public mutating func wait() async throws -> URL {
        while true {
            try Task.checkCancellation()
            for line in try cursor.readCompleteLines() {
                if let candidate = VideoLogProbe.extractCandidate(from: line) {
                    return candidate
                }
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}

public enum VideoDownloadPolicy {
    public static func accepts(statusCode: Int, mimeType: String?) -> Bool {
        guard statusCode == 200 || statusCode == 206 else { return false }
        guard let mimeType = mimeType?.lowercased(), !mimeType.isEmpty else { return true }
        return mimeType == "video/mp4" || mimeType == "application/octet-stream"
    }
}

public struct VideoDownloadReceipt: Sendable {
    public let fileURL: URL
    public let statusCode: Int
    public let elapsedMilliseconds: Int

    public init(fileURL: URL, statusCode: Int, elapsedMilliseconds: Int) {
        self.fileURL = fileURL
        self.statusCode = statusCode
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum VideoDownloadSessionPolicy {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }
}

public struct VideoDownloadClient: Sendable {
    public init() {}

    public func download(from sourceURL: URL, to destinationURL: URL) async throws -> VideoDownloadReceipt {
        guard VideoURLPolicy.accepts(sourceURL) else { throw VideoProbeError.downloadRejected }
        let started = Date()
        let redirectGuard = VideoProbeRedirectGuard()
        let session = URLSession(configuration: VideoDownloadSessionPolicy.makeConfiguration())
        defer { session.invalidateAndCancel() }
        do {
            let request = URLRequest(url: sourceURL)
            let (temporaryURL, response) = try await session.download(for: request, delegate: redirectGuard)
            guard let http = response as? HTTPURLResponse,
                  !redirectGuard.rejectedRedirect,
                  response.url.map(VideoURLPolicy.accepts) != false,
                  VideoDownloadPolicy.accepts(statusCode: http.statusCode, mimeType: response.mimeType) else {
                throw VideoProbeError.downloadRejected
            }
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw VideoProbeError.outputFailed
            }
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
            return VideoDownloadReceipt(
                fileURL: destinationURL,
                statusCode: http.statusCode,
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000))
            )
        } catch let error as VideoProbeError {
            throw error
        } catch {
            throw VideoProbeError.downloadFailed
        }
    }
}

private final class VideoProbeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false

    var rejectedRedirect: Bool {
        lock.withLock { rejected }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, VideoURLPolicy.accepts(target) else {
            lock.withLock { rejected = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public enum ProbeReportMarkdown {
    public static func render(_ report: SanitizedProbeReport) -> String {
        var lines = [
            "# 千牛视频直链测试报告",
            "",
            "- 结果：\(report.result == .passed ? "PASS" : "FAIL")",
            "- macOS：\(report.machine.macOS)",
            "- 架构：\(report.machine.architecture)",
            "- 千牛版本：\(report.machine.qianniuVersion)",
            "- 发现耗时：\(report.discoveryMilliseconds) ms",
            "- 下载耗时：\(report.downloadMilliseconds) ms",
            "- HTTP状态：\(report.httpStatus.map(String.init) ?? "未取得")"
        ]
        if let file = report.file {
            lines += [
                "- 文件：\(file.name)",
                "- 大小：\(file.bytes) bytes",
                "- SHA-256：\(file.sha256)",
                "- 时长：\(String(format: "%.3f", file.durationSeconds)) 秒",
                "- 分辨率：\(file.width) × \(file.height)",
                "- 视频编码：\(file.videoCodec)",
                "- 音频编码：\(file.audioCodec ?? "无音轨")"
            ]
        }
        if let failure = report.failure {
            lines.append("- 失败原因：\(failure)")
        }
        lines += [
            "",
            "> 报告不包含临时视频地址、签名参数、千牛原始日志或登录凭证。",
            ""
        ]
        return lines.joined(separator: "\n")
    }
}

public enum FileSHA256 {
    public static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum VideoFileInspector {
    public static func inspect(_ url: URL) async throws -> SanitizedProbeReport.FileSummary {
        guard try hasISOBaseMediaHeader(url) else { throw VideoProbeError.invalidMedia }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first,
                  duration.isNumeric,
                  duration.seconds.isFinite,
                  duration.seconds > 0 else {
                throw VideoProbeError.missingVideoTrack
            }
            async let naturalSize = videoTrack.load(.naturalSize)
            async let transform = videoTrack.load(.preferredTransform)
            async let videoFormats = videoTrack.load(.formatDescriptions)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioFormats = try await audioTracks.first?.load(.formatDescriptions) ?? []
            let loadedVideoFormats = try await videoFormats
            let oriented = CGRect(origin: .zero, size: try await naturalSize)
                .applying(try await transform)
                .standardized
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return SanitizedProbeReport.FileSummary(
                name: url.lastPathComponent,
                bytes: byteCount,
                sha256: try FileSHA256.hexDigest(of: url),
                durationSeconds: duration.seconds,
                width: Int(oriented.width.rounded()),
                height: Int(oriented.height.rounded()),
                videoCodec: loadedVideoFormats.first.map(codecName) ?? "unknown",
                audioCodec: audioFormats.first.map(codecName)
            )
        } catch let error as VideoProbeError {
            throw error
        } catch {
            throw VideoProbeError.invalidMedia
        }
    }

    private static func hasISOBaseMediaHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count >= 8 else { return false }
        return String(decoding: prefix[4..<8], as: UTF8.self) == "ftyp"
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        let value = CMFormatDescriptionGetMediaSubType(description)
        switch value {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kAudioFormatMPEG4AAC: return "AAC"
        default:
            let bytes: [UInt8] = [
                UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
            ]
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
        }
    }
}
