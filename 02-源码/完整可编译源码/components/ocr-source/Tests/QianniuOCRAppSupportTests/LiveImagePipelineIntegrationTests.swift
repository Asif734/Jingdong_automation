import CoreGraphics
import Foundation
import ImageIO
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class LiveImagePipelineIntegrationTests: XCTestCase {
    func testRealScreenshotsDetectParseAndPersistImagesAcrossScrollPositions() async throws {
        let cases = [
            FixtureCase(name: "bottom-1", expectedImageCount: 1, shouldQueue: true),
            FixtureCase(name: "middle-2", expectedImageCount: 2, shouldQueue: true),
            FixtureCase(name: "top-3", expectedImageCount: 1, shouldQueue: true),
        ]
        let engine = PaddleOCRWebEngine()

        for fixture in cases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qianniu-live-image-\(fixture.name)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let image = try loadFixture(fixture.name)
            let lines = try await engine.recognize(image)
            let boxes = await Task.detached {
                ConsensusChatImageDetector().detect(in: image)
            }.value
            let detected = boxes.compactMap { box -> DetectedChatImage? in
                guard let crop = image.cropping(to: box.integral) else { return nil }
                return DetectedChatImage(box: box, image: crop)
            }
            let parsed = ParsedChatParser.parse(
                lines: lines,
                imageBoxes: boxes,
                imageHeight: CGFloat(image.height)
            )

            XCTAssertEqual(
                detected.count,
                fixture.expectedImageCount,
                "\(fixture.name) 应检测到正确数量的图片"
            )
            XCTAssertEqual(
                parsed.messages.filter { $0.type == "image" && $0.sender == "customer" }.count,
                fixture.expectedImageCount,
                "\(fixture.name) 的图片应归属客户"
            )

            let exporter = CustomerRequestPackageExporter(
                rootDirectory: root,
                requestID: { "\(fixture.name)-request" },
                now: { Date(timeIntervalSince1970: 0) }
            )
            let queueURL = try await exporter.export(
                result: OCRRunResult(
                    lines: lines,
                    images: detected,
                    sourceImageSize: CGSize(width: image.width, height: image.height),
                    identityCandidates: CustomerIdentityCandidates(
                        axHeader: "tb263147182",
                        axSessionList: "tb263147182",
                        ocr: nil
                    )
                )
            )

            XCTAssertEqual(queueURL != nil, fixture.shouldQueue, "\(fixture.name) 入队状态不正确")
            let imageDirectory = root.appendingPathComponent("用户/tb263147182/images")
            let saved = try FileManager.default.contentsOfDirectory(
                at: imageDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "jpg" }
            XCTAssertEqual(saved.count, fixture.expectedImageCount, "\(fixture.name) 保存图片数不正确")

            let history = try String(
                contentsOf: root.appendingPathComponent("用户/tb263147182/history.jsonl"),
                encoding: .utf8
            )
            for index in 1...fixture.expectedImageCount {
                XCTAssertTrue(
                    history.contains("images/\(fixture.name)-request-\(index).jpg"),
                    "\(fixture.name) 历史记录缺少第 \(index) 张图片路径"
                )
            }
        }
    }

    private func loadFixture(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "jpeg",
                subdirectory: "Fixtures/LiveImageExperiment"
            )
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}

private struct FixtureCase {
    let name: String
    let expectedImageCount: Int
    let shouldQueue: Bool
}
