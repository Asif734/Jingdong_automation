import CoreGraphics
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class OCRWorkflowTests: XCTestCase {
    func testDefaultsToParsedViewAndCanSwitchToLosslessRawOCR() async {
        let result = OCRRunResult(
            lines: [
                OCRLine(text: "1", box: CGRect(x: 20, y: 100, width: 10, height: 18)),
                OCRLine(text: "-", box: CGRect(x: 20, y: 360, width: 5, height: 6), confidence: 0.2),
            ],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "tb9783153356",
                axSessionList: "tb9783153356",
                ocr: nil
            )
        )
        let model = AppModel(runner: MediaRunner(result: result))

        await model.runOCR()

        XCTAssertEqual(model.displayMode, .parsed)
        XCTAssertTrue(model.output.contains("\"v\" : \"1\""))
        XCTAssertFalse(model.output.contains("\"v\" : \"-\""))
        XCTAssertEqual(model.resolvedIdentity?.identity.value, "tb9783153356")
        XCTAssertEqual(model.resolvedIdentity?.source, .axHeader)

        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.output, "[\n  \"1\",\n  \"-\"\n]")
    }

    func testSuccessfulExportPublishesQueuePath() async {
        let exporter = ResultExporter(result: .success(URL(fileURLWithPath: "/tmp/alice.json")))
        let model = AppModel(
            runner: RecordingRunner(result: .success([OCRLine(text: "客户问题", box: .zero)])),
            exporter: exporter
        )

        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.lastQueuePath, "/tmp/alice.json")
        XCTAssertEqual(model.output, "[\n  \"客户问题\"\n]")
        XCTAssertEqual(model.stageHistory.last, .success)
    }

    func testRepeatedScanPublishesNoNewMessagesWithoutQueuePath() async {
        let exporter = ResultExporter(result: .success(nil))
        let model = AppModel(
            runner: RecordingRunner(result: .success([OCRLine(text: "旧消息", box: .zero)])),
            exporter: exporter
        )

        await model.runOCR()

        XCTAssertNil(model.lastQueuePath)
        XCTAssertTrue(model.status.contains("没有新消息"))
        XCTAssertEqual(model.stageHistory.last, .success)
    }

    func testExportFailureKeepsOCRResultAndShowsExplicitWarning() async {
        let exporter = ResultExporter(result: .failure(ExportTestError.failed))
        let model = AppModel(
            runner: RecordingRunner(result: .success([OCRLine(text: "客户问题", box: .zero)])),
            exporter: exporter
        )

        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.output, "[\n  \"客户问题\"\n]")
        XCTAssertNil(model.lastQueuePath)
        XCTAssertTrue(model.status.contains("队列更新失败"))
        XCTAssertFalse(model.isRunning)
    }

    func testImageIsInsertedInJSONByVerticalPositionAndPublishedForDisplay() async throws {
        let image = try makeOnePixelImage()
        let result = OCRRunResult(
            lines: [OCRLine(text: "图片后面的文字", box: CGRect(x: 10, y: 200, width: 80, height: 20))],
            images: [DetectedChatImage(box: CGRect(x: 20, y: 60, width: 120, height: 100), image: image)]
        )
        let model = AppModel(runner: MediaRunner(result: result))

        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.output, "[\n  \"[图片]\",\n  \"图片后面的文字\"\n]")
        XCTAssertEqual(model.detectedImages.count, 1)
        XCTAssertTrue(model.detectedImages[0] === image)
    }

    func testSuccessfulRunPublishesStagesAndLosslessOutput() async throws {
        let lines = [
            OCRLine(text: "1", box: CGRect(x: 0, y: 40, width: 8, height: 10)),
            OCRLine(text: "2025-08-24 10:27:33", box: CGRect(x: 0, y: 0, width: 120, height: 10)),
            OCRLine(text: "1", box: CGRect(x: 0, y: 20, width: 8, height: 10)),
        ]
        let runner = RecordingRunner(result: .success(lines))
        let model = AppModel(runner: runner)

        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.stageHistory, [.locating, .capturing, .recognizing, .success])
        XCTAssertEqual(model.output, "[\n  \"2025-08-24 10:27:33\",\n  \"1\",\n  \"1\"\n]")
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(runner.runCount, 1)
    }

    func testSecondRunReplacesPreviousOutput() async {
        let runner = SequencedRunner(results: [
            [OCRLine(text: "第一次", box: .zero)],
            [OCRLine(text: "第二次", box: .zero)],
        ])
        let model = AppModel(runner: runner)

        await model.runOCR()
        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.output, "[\n  \"第二次\"\n]")
        XCTAssertEqual(runner.runCount, 2)
    }

    func testSecondRunClearsPreviouslyDetectedImages() async throws {
        let image = try makeOnePixelImage()
        let runner = MediaSequencedRunner(results: [
            OCRRunResult(
                lines: [],
                images: [DetectedChatImage(box: CGRect(x: 0, y: 0, width: 1, height: 1), image: image)]
            ),
            OCRRunResult(lines: [OCRLine(text: "第二次无图", box: .zero)]),
        ])
        let model = AppModel(runner: runner)

        await model.runOCR()
        XCTAssertEqual(model.detectedImages.count, 1)

        await model.runOCR()
        model.selectDisplayMode(.raw)
        XCTAssertTrue(model.detectedImages.isEmpty)
        XCTAssertEqual(model.output, "[\n  \"第二次无图\"\n]")
    }

    func testSuccessfulRunKeepsMainChatTextThatMatchesPaginationPattern() async {
        let lines = [
            OCRLine(text: "客服", box: CGRect(x: 0, y: 10, width: 40, height: 10)),
            OCRLine(text: "41/41", box: CGRect(x: 0, y: 30, width: 50, height: 10)),
            OCRLine(text: "1", box: CGRect(x: 0, y: 50, width: 10, height: 10)),
        ]
        let model = AppModel(runner: RecordingRunner(result: .success(lines)))

        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.output, "[\n  \"客服\",\n  \"41/41\",\n  \"1\"\n]")
    }

    func testSuccessfulRunKeepsPaginationShapedTextAtBottomOfMainChat() async {
        let lines = [
            OCRLine(text: "客服", box: CGRect(x: 0, y: 10, width: 40, height: 10)),
            OCRLine(text: "正常消息", box: CGRect(x: 0, y: 40, width: 60, height: 10)),
            OCRLine(text: "41/41", box: CGRect(x: 0, y: 100, width: 50, height: 10)),
        ]
        let model = AppModel(runner: RecordingRunner(result: .success(lines)))

        await model.runOCR()
        model.selectDisplayMode(.raw)

        XCTAssertEqual(model.output, "[\n  \"客服\",\n  \"正常消息\",\n  \"41/41\"\n]")
    }

    func testFailurePublishesChineseErrorAndStopsRunning() async {
        let runner = RecordingRunner(result: .failure(OCRAppError.accessibilityPermissionMissing))
        let model = AppModel(runner: runner)

        await model.runOCR()

        XCTAssertEqual(model.status, "需要开启辅助功能权限")
        XCTAssertFalse(model.isRunning)
    }
}

@MainActor
private final class MediaRunner: OCRRunning {
    private let result: OCRRunResult

    init(result: OCRRunResult) {
        self.result = result
    }

    func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        stage(.locating)
        stage(.capturing)
        stage(.recognizing)
        return result
    }
}

private enum ExportTestError: LocalizedError {
    case failed
    var errorDescription: String? { "测试导出失败" }
}

private final class ResultExporter: CustomerRequestExporting, @unchecked Sendable {
    let result: Result<URL?, Error>

    init(result: Result<URL?, Error>) {
        self.result = result
    }

    func export(result: OCRRunResult) async throws -> URL? {
        try self.result.get()
    }
}

@MainActor
private final class MediaSequencedRunner: OCRRunning {
    private var results: [OCRRunResult]
    private var index = 0

    init(results: [OCRRunResult]) {
        self.results = results
    }

    func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        defer { index += 1 }
        return results[index]
    }
}

private func makeOnePixelImage() throws -> CGImage {
    let data = Data([255, 255, 255, 255]) as CFData
    let provider = try XCTUnwrap(CGDataProvider(data: data))
    return try XCTUnwrap(CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
}

@MainActor
private final class RecordingRunner: OCRRunning {
    private let result: Result<OCRRunResult, Error>
    private(set) var runCount = 0

    init(result: Result<[OCRLine], Error>) {
        self.result = result.map { OCRRunResult(lines: $0) }
    }

    func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        runCount += 1
        stage(.locating)
        stage(.capturing)
        stage(.recognizing)
        return try result.get()
    }
}

@MainActor
private final class SequencedRunner: OCRRunning {
    private var results: [[OCRLine]]
    private(set) var runCount = 0

    init(results: [[OCRLine]]) {
        self.results = results
    }

    func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        stage(.locating)
        stage(.capturing)
        stage(.recognizing)
        defer { runCount += 1 }
        return OCRRunResult(lines: results[runCount])
    }
}
