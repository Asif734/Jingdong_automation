import XCTest
@testable import QianniuOCRAppSupport

final class StaticResourceResolverTests: XCTestCase {
    func testResolvesOnlyFilesInsideResourceRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/ocr-assets", isDirectory: true)
        let resolver = StaticResourceResolver(root: root)

        XCTAssertEqual(
            try resolver.fileURL(for: "/models/model.tar?cache=1").path,
            "/tmp/ocr-assets/models/model.tar"
        )
        XCTAssertThrowsError(try resolver.fileURL(for: "/../private.txt"))
        XCTAssertThrowsError(try resolver.fileURL(for: "/models/%2e%2e/private.txt"))
    }

    func testReturnsBrowserRuntimeMimeTypes() {
        XCTAssertEqual(StaticResourceResolver.mimeType(forExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(StaticResourceResolver.mimeType(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(StaticResourceResolver.mimeType(forExtension: "mjs"), "text/javascript; charset=utf-8")
        XCTAssertEqual(StaticResourceResolver.mimeType(forExtension: "wasm"), "application/wasm")
        XCTAssertEqual(StaticResourceResolver.mimeType(forExtension: "tar"), "application/x-tar")
    }

    func testLocalServerServesAFileOverLoopback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("working".utf8).write(to: root.appendingPathComponent("index.html"))
        let server = LocalResourceServer(root: root)

        let url = try await server.start()
        let (data, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "working")
    }
}
