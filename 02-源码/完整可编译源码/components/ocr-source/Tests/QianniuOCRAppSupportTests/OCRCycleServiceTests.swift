import CoreGraphics
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class OCRCycleServiceTests: XCTestCase {
    func testRunOnceExportsQueueEntryWithoutLaunchingBatchApp() async throws {
        let result = OCRRunResult(
            lines: [
                OCRLine(
                    text: "你好",
                    box: CGRect(x: 20, y: 100, width: 40, height: 20)
                ),
            ],
            sourceImageSize: CGSize(width: 500, height: 350),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "u1",
                axSessionList: "u1",
                ocr: nil
            )
        )
        let runner = StubOCRCycleRunner(result: result)
        let exporter = StubOCRCycleExporter(
            result: URL(fileURLWithPath: "/tmp/待处理/u1.json")
        )
        let service = OCRCycleService(runner: runner, exporter: exporter)

        let outcome = try await service.runOnce()

        XCTAssertEqual(outcome.queueEntryURL?.lastPathComponent, "u1.json")
        XCTAssertEqual(outcome.uid, "u1")
        XCTAssertGreaterThanOrEqual(outcome.elapsedMilliseconds, 0)
        XCTAssertEqual(runner.runCount, 1)
        let exportCount = await exporter.currentExportCount()
        XCTAssertEqual(exportCount, 1)
    }

    func testLiveRunnerIsLazyAndCanBeReleasedAfterIdleThreshold() async throws {
        let result = OCRRunResult(
            lines: [],
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "u1",
                axSessionList: "u1",
                ocr: nil
            )
        )
        let factory = OCRRunnerFactory(result: result)
        let exporter = StubOCRCycleExporter(result: nil)
        var current = Date(timeIntervalSince1970: 1_000)
        let service = OCRCycleService(
            makeRunner: { factory.make() },
            exporter: exporter,
            now: { current }
        )

        XCTAssertEqual(factory.makeCount, 0)
        _ = try await service.runOnce()
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertFalse(
            service.releaseEngineIfIdle(
                since: current.addingTimeInterval(899),
                idleThreshold: 900
            )
        )
        current.addTimeInterval(900)
        XCTAssertTrue(
            service.releaseEngineIfIdle(since: current, idleThreshold: 900)
        )
        _ = try await service.runOnce()
        XCTAssertEqual(factory.makeCount, 2)
    }
}

@MainActor
private final class OCRRunnerFactory {
    private let result: OCRRunResult
    private(set) var makeCount = 0

    init(result: OCRRunResult) {
        self.result = result
    }

    func make() -> any OCRRunning {
        makeCount += 1
        return StubOCRCycleRunner(result: result)
    }
}

@MainActor
private final class StubOCRCycleRunner: OCRRunning {
    private let result: OCRRunResult
    private(set) var runCount = 0

    init(result: OCRRunResult) {
        self.result = result
    }

    func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        runCount += 1
        return result
    }
}

private actor StubOCRCycleExporter: CustomerRequestExporting {
    private let result: URL?
    private(set) var exportCount = 0

    init(result: URL?) {
        self.result = result
    }

    func export(result: OCRRunResult) async throws -> URL? {
        exportCount += 1
        return self.result
    }

    func currentExportCount() -> Int {
        exportCount
    }
}
