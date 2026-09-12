import AppKit
import Foundation
import QianniuOCRCore
import WebKit

@MainActor
protocol OCRRecognizing {
    func prepare() async throws
    func recognize(_ image: CGImage) async throws -> [OCRLine]
    func resetAfterTimeout()
}

extension OCRRecognizing {
    func prepare() async throws {}
    func resetAfterTimeout() {}
}

struct WebOCRPayload: Decodable {
    let lines: [WebOCRLine]
}

struct WebOCRLine: Decodable {
    let text: String
    let confidence: Double
    let box: CGRect

    private enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case box
    }

    private struct Box: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Double.self, forKey: .confidence)
        let decodedBox = try container.decode(Box.self, forKey: .box)
        box = CGRect(x: decodedBox.x, y: decodedBox.y, width: decodedBox.width, height: decodedBox.height)
    }

    var ocrLine: OCRLine {
        OCRLine(text: text, box: box, confidence: confidence)
    }
}

@MainActor
final class PaddleOCRWebEngine: NSObject, WKNavigationDelegate, OCRRecognizing {
    private let server: LocalResourceServer
    private let webView: WKWebView
    private var readyTask: Task<Void, Error>?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let packagedRoot = ResourceRootSelection.installedResourceRoot()
        let resourceRoot = ResourceRootSelection.select(
            packaged: packagedRoot,
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            development: {
                Bundle.module.resourceURL!.appendingPathComponent("WebOCR", isDirectory: true)
            }
        )
        server = LocalResourceServer(root: resourceRoot)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func prepare() async throws {
        try await ensureReady()
    }

    func recognize(_ image: CGImage) async throws -> [OCRLine] {
        try await ensureReady()
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw OCRAppError.engineFailed("无法把截图转换为 PNG")
        }
        let dataURL = "data:image/png;base64,\(png.base64EncodedString())"

        do {
            let value = try await webView.callAsyncJavaScript(
                "return JSON.stringify(await window.qianniuOCR.recognize(imageDataURL));",
                arguments: ["imageDataURL": dataURL],
                in: nil,
                contentWorld: .page
            )
            guard let json = value as? String else {
                throw OCRAppError.engineFailed("OCR 返回了无法读取的数据")
            }
            let payload = try JSONDecoder().decode(WebOCRPayload.self, from: Data(json.utf8))
            return payload.lines.map(\.ocrLine)
        } catch let error as OCRAppError {
            throw error
        } catch {
            let nsError = error as NSError
            throw OCRAppError.engineFailed(
                "\(String(reflecting: error)) [\(nsError.domain) \(nsError.code)] \(nsError.userInfo)"
            )
        }
    }

    func resetAfterTimeout() {
        readyTask?.cancel()
        readyTask = nil
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil
        webView.stopLoading()
        server.stop()
    }

    private func ensureReady() async throws {
        if let readyTask {
            return try await readyTask.value
        }
        let task = Task { @MainActor [server, webView] in
            let url = try await server.start()
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                webView.load(URLRequest(url: url))
            }
            _ = try await webView.callAsyncJavaScript(
                """
                return await new Promise((resolve, reject) => {
                  const deadline = Date.now() + 30000;
                  const check = () => {
                    if (window.qianniuOCR) return resolve(true);
                    if (window.__qianniuBootState?.error) {
                      return reject(new Error(window.__qianniuBootState.error));
                    }
                    if (Date.now() >= deadline) {
                      const scripts = Array.from(document.scripts).map((script) => ({
                        src: script.src,
                        type: script.type,
                        readyState: script.readyState || null
                      }));
                      return reject(new Error("等待 OCR 脚本加载超时 " + JSON.stringify({
                        baseURI: document.baseURI,
                        readyState: document.readyState,
                        scripts
                      })));
                    }
                    setTimeout(check, 50);
                  };
                  check();
                });
                """,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            _ = try await webView.callAsyncJavaScript(
                "return JSON.stringify(await window.qianniuOCR.ready());",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        }
        readyTask = task
        do {
            try await task.value
        } catch {
            readyTask = nil
            let nsError = error as NSError
            throw OCRAppError.engineFailed(
                "\(String(reflecting: error)) [\(nsError.domain) \(nsError.code)] \(nsError.userInfo)"
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }
}
