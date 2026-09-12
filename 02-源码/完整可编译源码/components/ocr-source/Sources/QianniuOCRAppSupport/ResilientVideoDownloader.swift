import Foundation
import QianniuVideoProbeCore

public struct SystemVideoDownloadPolicy: Equatable, Sendable {
    public let connectTimeout: TimeInterval
    public let totalTimeout: TimeInterval
    public let waitsForConnectivity: Bool

    public init(
        connectTimeout: TimeInterval = 5,
        totalTimeout: TimeInterval = 15,
        waitsForConnectivity: Bool = false
    ) {
        self.connectTimeout = connectTimeout
        self.totalTimeout = totalTimeout
        self.waitsForConnectivity = waitsForConnectivity
    }
}

public struct SystemVideoHTTPTransfer: Sendable {
    public let finalURL: URL
    public let statusCode: Int
    public let mimeType: String?
    public let elapsedMilliseconds: Int

    public init(
        finalURL: URL,
        statusCode: Int,
        mimeType: String?,
        elapsedMilliseconds: Int
    ) {
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public protocol SystemVideoHTTPTransport: Sendable {
    func download(
        _ source: URL,
        to destination: URL,
        policy: SystemVideoDownloadPolicy
    ) async throws -> SystemVideoHTTPTransfer
}

public struct VideoDownloadAttemptResult: Equatable, Sendable {
    public let statusCode: Int
    public let elapsedMilliseconds: Int
    public let bytes: Int64

    public init(statusCode: Int, elapsedMilliseconds: Int, bytes: Int64) {
        self.statusCode = statusCode
        self.elapsedMilliseconds = elapsedMilliseconds
        self.bytes = bytes
    }
}

public struct VideoTransferAttemptError: LocalizedError, Equatable, Sendable {
    public let category: VideoTransferFailureCategory
    public let isRetryable: Bool
    public let sanitizedDescription: String

    public var errorDescription: String? { sanitizedDescription }

    public init(
        category: VideoTransferFailureCategory,
        isRetryable: Bool,
        sanitizedDescription: String
    ) {
        self.category = category
        self.isRetryable = isRetryable
        self.sanitizedDescription = sanitizedDescription
    }
}

public protocol VideoDownloadAttempting: Sendable {
    func download(_ source: URL, to destination: URL) async throws -> VideoDownloadAttemptResult
}

public struct SystemRouteVideoDownloader: VideoDownloadAttempting {
    private let transport: any SystemVideoHTTPTransport
    private let policy: SystemVideoDownloadPolicy

    public init(
        transport: any SystemVideoHTTPTransport = URLSessionSystemVideoHTTPTransport(),
        policy: SystemVideoDownloadPolicy = SystemVideoDownloadPolicy()
    ) {
        self.transport = transport
        self.policy = policy
    }

    public func download(
        _ source: URL,
        to destination: URL
    ) async throws -> VideoDownloadAttemptResult {
        guard VideoURLPolicy.accepts(source) else {
            throw Self.error(.redirectRejected, retryable: false)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Self.error(.localFile, retryable: false)
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let transfer = try await transport.download(source, to: destination, policy: policy)
            guard VideoURLPolicy.accepts(transfer.finalURL) else {
                throw Self.error(.redirectRejected, retryable: false)
            }
            guard transfer.statusCode == 200 || transfer.statusCode == 206 else {
                throw Self.error(
                    .httpRejected,
                    retryable: Self.retryableHTTPStatuses.contains(transfer.statusCode)
                )
            }
            guard VideoDownloadPolicy.accepts(
                statusCode: transfer.statusCode,
                mimeType: transfer.mimeType
            ) else {
                throw Self.error(.invalidContent, retryable: false)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else {
                throw Self.error(.invalidContent, retryable: false)
            }
            return VideoDownloadAttemptResult(
                statusCode: transfer.statusCode,
                elapsedMilliseconds: transfer.elapsedMilliseconds,
                bytes: bytes
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Self.classify(error)
        }
    }

    private static let retryableHTTPStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    private static func classify(_ error: Error) -> VideoTransferAttemptError {
        if let typed = error as? VideoTransferAttemptError { return typed }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return Self.error(.dnsResolution, retryable: true)
            case .timedOut:
                return Self.error(.connectTimeout, retryable: true)
            case .notConnectedToInternet, .internationalRoamingOff,
                 .dataNotAllowed, .callIsActive:
                return Self.error(.offline, retryable: true)
            case .networkConnectionLost:
                return Self.error(.connectionReset, retryable: true)
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return Self.error(.tlsFailure, retryable: false)
            case .redirectToNonExistentLocation, .httpTooManyRedirects:
                return Self.error(.redirectRejected, retryable: false)
            default:
                return Self.error(.responseTimeout, retryable: true)
            }
        }
        if error is CocoaError {
            return Self.error(.localFile, retryable: false)
        }
        return Self.error(.connectionReset, retryable: true)
    }

    private static func error(
        _ category: VideoTransferFailureCategory,
        retryable: Bool
    ) -> VideoTransferAttemptError {
        VideoTransferAttemptError(
            category: category,
            isRetryable: retryable,
            sanitizedDescription: "视频下载失败：\(category.rawValue)"
        )
    }
}

public struct URLSessionSystemVideoHTTPTransport: SystemVideoHTTPTransport {
    public init() {}

    public func download(
        _ source: URL,
        to destination: URL,
        policy: SystemVideoDownloadPolicy
    ) async throws -> SystemVideoHTTPTransfer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.connectTimeout
        configuration.timeoutIntervalForResource = policy.totalTimeout
        configuration.waitsForConnectivity = policy.waitsForConnectivity
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let redirectGuard = VideoRedirectGuard()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source)
        request.timeoutInterval = policy.connectTimeout
        let started = Date()
        let (temporaryURL, response) = try await session.download(for: request, delegate: redirectGuard)
        if redirectGuard.rejectedRedirect {
            throw VideoTransferAttemptError(
                category: .redirectRejected,
                isRetryable: false,
                sanitizedDescription: "视频下载失败：redirectRejected"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw VideoTransferAttemptError(
                category: .httpRejected,
                isRetryable: false,
                sanitizedDescription: "视频下载失败：httpRejected"
            )
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return SystemVideoHTTPTransfer(
            finalURL: response.url ?? source,
            statusCode: http.statusCode,
            mimeType: response.mimeType,
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000))
        )
    }
}

private final class VideoRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
