import Darwin
import Foundation
import QianniuVideoProbeCore

public enum AddressFamily: String, Codable, Sendable {
    case ipv4
    case ipv6
}

public struct AlternateVideoRoute: Hashable, Sendable {
    public let address: String
    public let poolID: String
    public let family: AddressFamily

    public init(address: String, poolID: String, family: AddressFamily) {
        self.address = address
        self.poolID = poolID
        self.family = family
    }

    public var isPublicAddress: Bool {
        PublicIPAddress.classify(address)?.family == family
    }
}

public protocol AlternateDNSQuerying: Sendable {
    func addresses(host: String, server: String, timeout: Duration) async throws -> [String]
}

public protocol AlternateVideoRouteProviding: Sendable {
    func candidates(for approvedHost: String) async throws -> [AlternateVideoRoute]
}

public struct AlternateVideoRouteProvider: AlternateVideoRouteProviding {
    private struct Endpoint: Sendable {
        let id: String
        let server: String
    }

    private let query: any AlternateDNSQuerying
    private let endpoints = [
        Endpoint(id: "alidns", server: "223.5.5.5"),
        Endpoint(id: "dnspod", server: "119.29.29.29")
    ]

    public init(query: any AlternateDNSQuerying = DigAlternateDNSQuery()) {
        self.query = query
    }

    public func candidates(for approvedHost: String) async throws -> [AlternateVideoRoute] {
        guard VideoURLPolicy.approvedHosts.contains(approvedHost.lowercased()) else {
            throw VideoTransferAttemptError(
                category: .redirectRejected,
                isRetryable: false,
                sanitizedDescription: "备用线路拒绝未知视频主机"
            )
        }
        let query = query
        let responses = await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask {
                    let values = (try? await query.addresses(
                        host: approvedHost,
                        server: endpoint.server,
                        timeout: .seconds(3)
                    )) ?? []
                    return (index, values)
                }
            }
            var values = Array(repeating: [String](), count: endpoints.count)
            for await (index, result) in group { values[index] = result }
            return values
        }

        var pools: [[AlternateVideoRoute]] = []
        var seen = Set<String>()
        for (index, response) in responses.enumerated() {
            var routes: [AlternateVideoRoute] = []
            for address in response {
                guard seen.insert(address).inserted,
                      let classification = PublicIPAddress.classify(address) else { continue }
                routes.append(AlternateVideoRoute(
                    address: address,
                    poolID: endpoints[index].id,
                    family: classification.family
                ))
            }
            pools.append(routes)
        }

        var selected: [AlternateVideoRoute] = []
        var offset = 0
        while selected.count < 3 {
            var appended = false
            for pool in pools where offset < pool.count {
                selected.append(pool[offset])
                appended = true
                if selected.count == 3 { break }
            }
            if !appended { break }
            offset += 1
        }
        guard !selected.isEmpty else {
            throw VideoTransferAttemptError(
                category: .dnsResolution,
                isRetryable: true,
                sanitizedDescription: "备用 DNS 未返回可用公网地址"
            )
        }
        return selected
    }
}

public struct DigAlternateDNSQuery: AlternateDNSQuerying {
    public init() {}

    public func addresses(host: String, server: String, timeout: Duration) async throws -> [String] {
        guard VideoURLPolicy.approvedHosts.contains(host.lowercased()),
              PublicIPAddress.classify(server) != nil else {
            throw VideoTransferAttemptError(
                category: .dnsResolution,
                isRetryable: false,
                sanitizedDescription: "备用 DNS 参数无效"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        process.arguments = ["+short", "+time=2", "+tries=1", "@\(server)", host, "A", "AAAA"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeoutNanoseconds = timeout.nanosecondsClamped
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [String].self) { group in
                group.addTask {
                    process.waitUntilExit()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        throw VideoTransferAttemptError(
                            category: .dnsResolution,
                            isRetryable: true,
                            sanitizedDescription: "备用 DNS 查询失败"
                        )
                    }
                    return String(decoding: data, as: UTF8.self)
                        .split(whereSeparator: \Character.isNewline)
                        .map(String.init)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw VideoTransferAttemptError(
                        category: .dnsResolution,
                        isRetryable: true,
                        sanitizedDescription: "备用 DNS 查询超时"
                    )
                }
                defer { group.cancelAll() }
                return try await group.next() ?? []
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

public struct SanitizedProcessResult: Sendable {
    public let exitStatus: Int32
    public let stderrCategory: VideoTransferFailureCategory?
    public let httpStatus: Int?

    public init(
        exitStatus: Int32,
        stderrCategory: VideoTransferFailureCategory?,
        httpStatus: Int? = 200
    ) {
        self.exitStatus = exitStatus
        self.stderrCategory = stderrCategory
        self.httpStatus = httpStatus
    }
}

public protocol RunningProcess: Sendable {
    var processGroupID: Int32 { get }
    func wait() async -> SanitizedProcessResult
    func terminate(grace: Duration) async
}

public protocol ProcessRunning: Sendable {
    func spawn(
        executable: String,
        arguments: [String],
        sensitiveStandardInput: Data?,
        processGroup: Bool
    ) async throws -> any RunningProcess
}

public struct POSIXProcessRunner: ProcessRunning {
    public init() {}

    public func spawn(
        executable: String,
        arguments: [String],
        sensitiveStandardInput: Data?,
        processGroup: Bool
    ) async throws -> any RunningProcess {
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&stdinPipe) == 0,
              Darwin.pipe(&stdoutPipe) == 0,
              Darwin.pipe(&stderrPipe) == 0 else {
            Self.closePipe(&stdinPipe)
            Self.closePipe(&stdoutPipe)
            Self.closePipe(&stderrPipe)
            throw VideoTransferAttemptError(
                category: .localFile,
                isRetryable: false,
                sanitizedDescription: "无法建立视频下载进程管道"
            )
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            Self.closePipe(&stdinPipe)
            Self.closePipe(&stdoutPipe)
            Self.closePipe(&stderrPipe)
            throw VideoTransferAttemptError(
                category: .localFile,
                isRetryable: false,
                sanitizedDescription: "无法初始化视频下载进程"
            )
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        for descriptor in stdinPipe + stdoutPipe + stderrPipe {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if processGroup {
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        }

        let argumentStrings = [executable] + arguments
        let environmentStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let argv = argumentStrings.map { strdup($0) } + [nil]
        let envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { if let pointer { free(UnsafeMutableRawPointer(pointer)) } }
            for pointer in envp { if let pointer { free(UnsafeMutableRawPointer(pointer)) } }
        }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { argumentsBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                executable.withCString { executablePointer in
                    posix_spawn(
                        &pid,
                        executablePointer,
                        &actions,
                        &attributes,
                        UnsafeMutablePointer(mutating: argumentsBuffer.baseAddress!),
                        UnsafeMutablePointer(mutating: environmentBuffer.baseAddress!)
                    )
                }
            }
        }
        Self.close(stdinPipe[0])
        Self.close(stdoutPipe[1])
        Self.close(stderrPipe[1])
        guard status == 0 else {
            Self.close(stdinPipe[1])
            Self.close(stdoutPipe[0])
            Self.close(stderrPipe[0])
            throw VideoTransferAttemptError(
                category: .localFile,
                isRetryable: false,
                sanitizedDescription: "视频下载进程启动失败"
            )
        }
        if let input = sensitiveStandardInput {
            input.withUnsafeBytes { rawBuffer in
                guard var cursor = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(stdinPipe[1], cursor, remaining)
                    if written > 0 {
                        cursor = cursor.advanced(by: written)
                        remaining -= written
                    } else if errno != EINTR {
                        break
                    }
                }
            }
        }
        Self.close(stdinPipe[1])
        Self.makeNonBlocking(stdoutPipe[0])
        Self.makeNonBlocking(stderrPipe[0])
        return POSIXRunningProcess(
            pid: pid,
            stdoutDescriptor: stdoutPipe[0],
            stderrDescriptor: stderrPipe[0]
        )
    }

    private static func closePipe(_ values: inout [Int32]) {
        for value in values where value >= 0 { Darwin.close(value) }
        values = [-1, -1]
    }

    private static func close(_ descriptor: Int32) {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    private static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }
}

private actor POSIXRunningProcess: RunningProcess {
    nonisolated let processGroupID: Int32
    private let pid: pid_t
    private var stdoutDescriptor: Int32
    private var stderrDescriptor: Int32
    private var completed: SanitizedProcessResult?

    init(pid: pid_t, stdoutDescriptor: Int32, stderrDescriptor: Int32) {
        self.pid = pid
        processGroupID = pid
        self.stdoutDescriptor = stdoutDescriptor
        self.stderrDescriptor = stderrDescriptor
    }

    deinit {
        if stdoutDescriptor >= 0 { Darwin.close(stdoutDescriptor) }
        if stderrDescriptor >= 0 { Darwin.close(stderrDescriptor) }
    }

    func wait() async -> SanitizedProcessResult {
        if let completed { return completed }
        var stdout = Data()
        var status: Int32 = 0
        while true {
            drain(stdoutDescriptor, into: &stdout, limit: 32)
            drain(stderrDescriptor, into: nil, limit: 8_192)
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited == -1 && errno != EINTR { break }
            if Task.isCancelled {
                await terminate(grace: .milliseconds(150))
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        drain(stdoutDescriptor, into: &stdout, limit: 32)
        drain(stderrDescriptor, into: nil, limit: 8_192)
        closeDescriptors()
        let exitStatus = Self.decode(status)
        let result = SanitizedProcessResult(
            exitStatus: exitStatus,
            stderrCategory: Self.category(forCurlExit: exitStatus),
            httpStatus: Int(String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        completed = result
        return result
    }

    func terminate(grace: Duration) async {
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
        try? await Task.sleep(for: grace)
        if kill(-pid, 0) == 0 {
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
        }
    }

    private func drain(_ descriptor: Int32, into data: inout Data?, limit: Int) {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0, data != nil, data!.count < limit {
                data!.append(contentsOf: buffer.prefix(min(count, limit - data!.count)))
            } else if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    private func drain(_ descriptor: Int32, into data: inout Data, limit: Int) {
        var optional: Data? = data
        drain(descriptor, into: &optional, limit: limit)
        data = optional ?? data
    }

    private func drain(_ descriptor: Int32, into data: Data?, limit: Int) {
        var mutable = data
        drain(descriptor, into: &mutable, limit: limit)
    }

    private func closeDescriptors() {
        if stdoutDescriptor >= 0 { Darwin.close(stdoutDescriptor); stdoutDescriptor = -1 }
        if stderrDescriptor >= 0 { Darwin.close(stderrDescriptor); stderrDescriptor = -1 }
    }

    private static func decode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func category(forCurlExit status: Int32) -> VideoTransferFailureCategory? {
        switch status {
        case 0: return nil
        case 6: return .dnsResolution
        case 7, 28: return .connectTimeout
        case 22: return .httpRejected
        case 35, 51, 58, 59, 60, 66, 77, 80, 82, 83, 90, 91: return .tlsFailure
        case 23, 26: return .localFile
        case 52, 55, 56: return .connectionReset
        default: return .responseTimeout
        }
    }
}

public protocol ResolvedVideoDownloading: Sendable {
    func download(
        source: URL,
        resolvedAddress: String,
        destination: URL
    ) async throws -> VideoDownloadAttemptResult
}

public protocol AlternateRouteDownloading: Sendable {
    func downloadFirstValid(
        source: URL,
        candidates: [AlternateVideoRoute],
        destination: URL
    ) async throws -> AlternateRouteReceipt
}

public struct CurlResolvedVideoDownloader: ResolvedVideoDownloading {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = POSIXProcessRunner()) {
        self.runner = runner
    }

    public func download(
        source: URL,
        resolvedAddress: String,
        destination: URL
    ) async throws -> VideoDownloadAttemptResult {
        guard VideoURLPolicy.accepts(source) else {
            throw Self.error(.redirectRejected, retryable: false)
        }
        guard let classification = PublicIPAddress.classify(resolvedAddress) else {
            throw Self.error(.dnsResolution, retryable: false)
        }
        let sourceText = source.absoluteString
        guard !sourceText.contains("\"") && !sourceText.contains("\\")
                && !sourceText.contains("\r") && !sourceText.contains("\n") else {
            throw Self.error(.redirectRejected, retryable: false)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Self.error(.localFile, retryable: false)
        }
        let host = source.host!.lowercased()
        let address = classification.family == .ipv6 ? "[\(resolvedAddress)]" : resolvedAddress
        let arguments = [
            "--config", "-", "--fail-with-body", "--silent", "--show-error",
            "--connect-timeout", "5", "--max-time", "15",
            "--output", destination.path,
            "--write-out", "%{http_code}",
            "--resolve", "\(host):443:\(address)"
        ]
        let standardInput = Data("url = \"\(sourceText)\"\n".utf8)
        let process = try await runner.spawn(
            executable: "/usr/bin/curl",
            arguments: arguments,
            sensitiveStandardInput: standardInput,
            processGroup: true
        )
        let started = Date()
        let result = await withTaskCancellationHandler {
            await process.wait()
        } onCancel: {
            Task { await process.terminate(grace: .milliseconds(150)) }
        }
        guard result.exitStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw Self.error(result.stderrCategory ?? .connectionReset, retryable: true)
        }
        guard result.httpStatus == 200 || result.httpStatus == 206 else {
            try? FileManager.default.removeItem(at: destination)
            throw Self.error(.httpRejected, retryable: true)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw Self.error(.invalidContent, retryable: false)
        }
        return VideoDownloadAttemptResult(
            statusCode: result.httpStatus ?? 200,
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000)),
            bytes: bytes
        )
    }

    private static func error(
        _ category: VideoTransferFailureCategory,
        retryable: Bool
    ) -> VideoTransferAttemptError {
        VideoTransferAttemptError(
            category: category,
            isRetryable: retryable,
            sanitizedDescription: "备用视频线路失败：\(category.rawValue)"
        )
    }
}

public struct AlternateRouteReceipt: Sendable {
    public let route: AlternateVideoRoute
    public let result: VideoDownloadAttemptResult
    public let fileURL: URL
}

public struct AlternateRouteRace: Sendable {
    public typealias Validate = @Sendable (URL) async throws -> Void

    private enum Outcome: Sendable {
        case success(AlternateVideoRoute, VideoDownloadAttemptResult, URL)
        case failure(VideoTransferAttemptError)
    }

    private let downloader: any ResolvedVideoDownloading
    private let validate: Validate

    public init(
        downloader: any ResolvedVideoDownloading,
        validate: @escaping Validate
    ) {
        self.downloader = downloader
        self.validate = validate
    }

    public func downloadFirstValid(
        source: URL,
        candidates: [AlternateVideoRoute],
        destination: URL
    ) async throws -> AlternateRouteReceipt {
        guard !candidates.isEmpty else {
            throw VideoTransferAttemptError(
                category: .dnsResolution,
                isRetryable: true,
                sanitizedDescription: "没有可用备用视频线路"
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VideoTransferAttemptError(
                category: .localFile,
                isRetryable: false,
                sanitizedDescription: "目标视频文件已经存在"
            )
        }
        let attempts = candidates.prefix(3).map { route in
            (route, destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).partial.mp4"
            ))
        }
        defer {
            for (_, partial) in attempts { try? FileManager.default.removeItem(at: partial) }
        }
        let downloader = downloader
        let validate = validate
        var lastError = VideoTransferAttemptError(
            category: .connectionReset,
            isRetryable: true,
            sanitizedDescription: "全部备用视频线路失败"
        )
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            for (route, partial) in attempts {
                group.addTask {
                    do {
                        let result = try await downloader.download(
                            source: source,
                            resolvedAddress: route.address,
                            destination: partial
                        )
                        try await validate(partial)
                        return .success(route, result, partial)
                    } catch is CancellationError {
                        return .failure(VideoTransferAttemptError(
                            category: .connectionReset,
                            isRetryable: true,
                            sanitizedDescription: "备用线路已取消"
                        ))
                    } catch let error as VideoTransferAttemptError {
                        try? FileManager.default.removeItem(at: partial)
                        return .failure(error)
                    } catch {
                        try? FileManager.default.removeItem(at: partial)
                        return .failure(VideoTransferAttemptError(
                            category: .invalidVideo,
                            isRetryable: false,
                            sanitizedDescription: "备用线路视频校验失败"
                        ))
                    }
                }
            }
            while let outcome = try await group.next() {
                switch outcome {
                case .success(let route, let result, let partial):
                    do {
                        try FileManager.default.moveItem(at: partial, to: destination)
                    } catch {
                        group.cancelAll()
                        throw VideoTransferAttemptError(
                            category: .localFile,
                            isRetryable: false,
                            sanitizedDescription: "备用线路视频发布失败"
                        )
                    }
                    group.cancelAll()
                    return AlternateRouteReceipt(route: route, result: result, fileURL: destination)
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }
}

extension AlternateRouteRace: AlternateRouteDownloading {}

private enum PublicIPAddress {
    struct Classification {
        let family: AddressFamily
    }

    static func classify(_ value: String) -> Classification? {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) { Array($0) }
            guard isPublicIPv4(bytes) else { return nil }
            return Classification(family: .ipv4)
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            guard isPublicIPv6(bytes) else { return nil }
            return Classification(family: .ipv6)
        }
        return nil
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
        if b[0] == 100 && (64...127).contains(b[1]) { return false }
        if b[0] == 169 && b[1] == 254 { return false }
        if b[0] == 172 && (16...31).contains(b[1]) { return false }
        if b[0] == 192 && b[1] == 168 { return false }
        if b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2) { return false }
        if b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100)) { return false }
        if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) { return false }
        if b.dropLast().allSatisfy({ $0 == 0 }) && b.last == 1 { return false }
        if b[0] & 0xfe == 0xfc { return false }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }
        if b[0] == 0xff { return false }
        if b[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8]) { return false }
        return true
    }
}

private extension Duration {
    var nanosecondsClamped: UInt64 {
        let components = self.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = UInt64(clamping: components.seconds)
        let nanos = UInt64(clamping: components.attoseconds / 1_000_000_000)
        return seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue &+ nanos
    }
}
