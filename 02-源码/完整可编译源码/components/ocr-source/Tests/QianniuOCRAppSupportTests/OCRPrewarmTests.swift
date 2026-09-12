import CoreGraphics
import XCTest
@testable import QianniuOCRAppSupport
@testable import QianniuOCRCore

@MainActor
final class OCRPrewarmTests: XCTestCase {
    func testLiveRunnerWarmsTheSameRecognizerUsedForRecognition() async throws {
        let engine = RecordingOCRRecognizer()
        let runner = LiveOCRRunner(
            locator: NeverUsedPanelLocator(),
            captureService: NeverUsedWindowCapture(),
            engine: engine
        )

        try await runner.prepareOCR()

        XCTAssertEqual(engine.prepareCalls, 1)
        XCTAssertEqual(engine.recognizeCalls, 0)
    }
}

@MainActor
private final class RecordingOCRRecognizer: OCRRecognizing {
    private(set) var prepareCalls = 0
    private(set) var recognizeCalls = 0

    func prepare() async throws { prepareCalls += 1 }

    func recognize(_ image: CGImage) async throws -> [OCRLine] {
        recognizeCalls += 1
        return []
    }
}

private struct NeverUsedPanelLocator: PanelLocating {
    func locate() throws -> LocatedPanel { throw CancellationError() }
}

private struct NeverUsedWindowCapture: WindowCapturing {
    func capture(_ panel: LocatedPanel) async throws -> CGImage { throw CancellationError() }
}
