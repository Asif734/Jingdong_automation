import Foundation
import Network

enum StaticResourceError: Error {
    case invalidPath
    case notFound
}

struct StaticResourceResolver {
    let root: URL

    func fileURL(for requestTarget: String) throws -> URL {
        let pathOnly = requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard let decoded = pathOnly.removingPercentEncoding else {
            throw StaticResourceError.invalidPath
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains(".") else {
            throw StaticResourceError.invalidPath
        }

        let relative = components.isEmpty ? "index.html" : components.joined(separator: "/")
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw StaticResourceError.invalidPath
        }
        return candidate
    }

    static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "wasm": "application/wasm"
        case "tar": "application/x-tar"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "application/octet-stream"
        }
    }
}

final class LocalResourceServer: @unchecked Sendable {
    private let resolver: StaticResourceResolver
    private let queue = DispatchQueue(label: "QianniuOCR.LocalResourceServer")
    private var listener: NWListener?

    init(root: URL) {
        resolver = StaticResourceResolver(root: root)
    }

    func start() async throws -> URL {
        if let port = listener?.port {
            return URL(string: "http://127.0.0.1:\(port.rawValue)/index.html")!
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: OCRAppError.engineFailed("本地资源端口不可用"))
                        return
                    }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/index.html")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener?.cancel()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\r\n").first else {
                self?.send(status: "400 Bad Request", body: Data(), mime: "text/plain", on: connection)
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                self.send(status: "405 Method Not Allowed", body: Data(), mime: "text/plain", on: connection)
                return
            }

            do {
                let url = try self.resolver.fileURL(for: String(parts[1]))
                let body = try Data(contentsOf: url, options: .mappedIfSafe)
                self.send(
                    status: "200 OK",
                    body: body,
                    mime: StaticResourceResolver.mimeType(forExtension: url.pathExtension),
                    on: connection
                )
            } catch {
                self.send(status: "404 Not Found", body: Data("Not found".utf8), mime: "text/plain; charset=utf-8", on: connection)
            }
        }
    }

    private func send(status: String, body: Data, mime: String, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
