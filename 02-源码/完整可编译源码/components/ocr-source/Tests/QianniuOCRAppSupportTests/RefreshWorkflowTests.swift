import CoreGraphics
import XCTest
import QianniuOCRCore
@testable import QianniuOCRAppSupport

@MainActor
final class RefreshWorkflowTests: XCTestCase {
    func testNeverReturningRecognizerHitsHardDeadlineAndResetsEngine() async throws {
        let events = EventRecorder()
        let engine = NeverReturningEngine()
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: engine,
            deadlines: OCRExecutionDeadlines(
                capture: .seconds(1), recognition: .milliseconds(30),
                linkResolution: .seconds(1), imageResolution: .seconds(1)
            )
        )

        do {
            _ = try await runner.run { _ in }
            XCTFail("recognition must time out")
        } catch let timeout as OCRStageTimeout {
            XCTAssertEqual(timeout.stage, "ocr-recognize")
        }
        XCTAssertEqual(engine.resetCount, 1)
    }

    func testRunnerLocatesCapturesAndRecognizesOnce() async throws {
        let events = EventRecorder()
        let capture = RecordingCapture(events: events)
        let engine = RecordingEngine(events: events)
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: capture,
            engine: engine,
            linkResolver: RecordingLinkResolver(events: events)
        )
        var stages: [OCRStage] = []

        let result = try await runner.run { stages.append($0) }

        XCTAssertEqual(events.values, ["locate", "capture", "recognize", "resolve-links"])
        XCTAssertEqual(stages, [.locating, .capturing, .recognizing, .detectingImages])
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(engine.callCount, 1)
        XCTAssertEqual(result.lines, [OCRLine(text: "原文", box: .zero)])
        XCTAssertTrue(result.images.isEmpty)
    }

    func testRunnerYieldsAfterLocatingStageBeforeBlockingLocatorWork() async throws {
        let events = EventRecorder()
        let locatingStageRendered = BooleanRecorder()
        let runner = LiveOCRRunner(
            locator: YieldCheckingLocator(
                locatingStageRendered: locatingStageRendered,
                events: events
            ),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events)
        )

        _ = try await runner.run { stage in
            guard stage == .locating else { return }
            Task { @MainActor in
                locatingStageRendered.value = true
            }
        }

        XCTAssertEqual(events.values.first, "locate-after-yield:true")
    }

    func testImageDetectionDoesNotBlockMainActor() async throws {
        let events = EventRecorder()
        let mainActorAdvanced = BooleanRecorder()
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: SlowImageDetector()
        )

        _ = try await runner.run { stage in
            guard stage == .detectingImages else { return }
            Task { @MainActor in
                mainActorAdvanced.value = true
            }
        }

        XCTAssertTrue(mainActorAdvanced.value)
    }

    func testCopiedOriginalImageReplacesLegacyScreenshotCropForSameBox() async throws {
        let events = EventRecorder()
        let box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let original = try XCTUnwrap(CGContext(
            data: nil,
            width: 1179,
            height: 884,
            bitsPerComponent: 8,
            bytesPerRow: 1179 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: [box]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [box]),
            imageCopyResolver: FixedImageCopyResolver(images: [
                DetectedChatImage(box: box, image: original)
            ])
        )

        let result = try await runner.run { _ in }

        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0].image.width, 1179)
        XCTAssertEqual(result.images[0].image.height, 884)
    }

    // Catches a pre-send text-only validation accidentally clicking Copy on
    // an old image that merely remains visible in the chat viewport.
    func testImageDisabledRunStillRecognizesTextButNeverInvokesImageCopy() async throws {
        let events = EventRecorder()
        let copy = RecordingImageCopyResolver()
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: [CGRect(x: 1, y: 1, width: 20, height: 20)]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [CGRect(x: 1, y: 1, width: 20, height: 20)]),
            imageCopyResolver: copy,
            linkResolver: RecordingLinkResolver(events: events)
        )
        var stages: [OCRStage] = []

        let result = try await runner.run(includeImages: false) { stages.append($0) }

        XCTAssertEqual(events.values, ["locate", "capture", "recognize", "resolve-links"])
        XCTAssertEqual(stages, [.locating, .capturing, .recognizing])
        XCTAssertEqual(copy.callCount, 0)
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.lines.map(\.text), ["原文"])
    }

    func testVideoMediaGateRunsAfterVisualDetectionAndBeforeAnyImageCopy() async throws {
        let events = EventRecorder()
        let copy = RecordingImageCopyResolver()
        let box = CGRect(x: 1, y: 1, width: 20, height: 20)
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: [box]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [box]),
            imageCopyResolver: copy
        )
        var gateCalls = 0

        let result = try await runner.run(includeImages: true, mediaAction: {
            gateCalls += 1
            return .ignore
        }) { _ in }

        XCTAssertEqual(gateCalls, 1)
        XCTAssertEqual(copy.callCount, 0)
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.lines.map(\.text), ["原文"])
    }

    func testOpenVideoActionInvokesVideoOpenerAndReturnsTerminalDispositionWithoutImageCopy() async throws {
        let events = EventRecorder()
        let copy = RecordingImageCopyResolver()
        let video = RecordingVideoOpener(outcome: .opened)
        let box = CGRect(x: 10, y: 200, width: 180, height: 120)
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: [box]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [box]),
            imageCopyResolver: copy,
            videoOpener: video
        )

        let result = try await runner.run(
            includeImages: true,
            mediaAction: { .openVideo(messageID: "VIDEO.105", customerUID: "buyer-a") }
        ) { _ in }

        XCTAssertEqual(result.mediaDisposition, .videoHandled(messageID: "VIDEO.105", outcome: .opened))
        XCTAssertEqual(video.messageIDs, ["VIDEO.105"])
        XCTAssertEqual(video.boxes, [box])
        XCTAssertEqual(copy.callCount, 0)
        XCTAssertTrue(result.images.isEmpty)
    }

    func testVideoOpeningIsNotCancelledByTheFormerDeadline() async throws {
        let events = EventRecorder()
        let copy = RecordingImageCopyResolver()
        let box = CGRect(x: 10, y: 200, width: 180, height: 120)
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: [box]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [box]),
            imageCopyResolver: copy,
            videoOpener: DelayedVideoOpener(delay: .milliseconds(60)),
            deadlines: OCRExecutionDeadlines(
                capture: .seconds(1), recognition: .seconds(1),
                linkResolution: .seconds(1), imageResolution: .seconds(1)
            )
        )

        let start = ContinuousClock.now
        let result = try await runner.run(
            includeImages: true,
            mediaAction: { .openVideo(messageID: "VIDEO.TIMEOUT", customerUID: "buyer-a") }
        ) { _ in }

        XCTAssertEqual(result.mediaDisposition, .videoHandled(messageID: "VIDEO.TIMEOUT", outcome: .opened))
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(50))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(copy.callCount, 0)
    }

    func testImageMediaGatePreservesExistingCopyFlow() async throws {
        let events = EventRecorder()
        let copy = RecordingImageCopyResolver()
        let box = CGRect(x: 1, y: 1, width: 20, height: 20)
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: [box]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [box]),
            imageCopyResolver: copy
        )

        _ = try await runner.run(includeImages: true, mediaAction: { .copy }) { _ in }

        XCTAssertEqual(copy.callCount, 1)
        XCTAssertEqual(copy.boxes, [box])
    }

    func testTextOnlyVisualResultNeverConsultsMediaGate() async throws {
        let events = EventRecorder()
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: RecordingCapture(events: events),
            engine: RecordingEngine(events: events),
            imageDetector: FixedImageDetector(boxes: []),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [])
        )
        var gateCalls = 0

        _ = try await runner.run(includeImages: true, mediaAction: {
            gateCalls += 1
            return .ignore
        }) { _ in }

        XCTAssertEqual(gateCalls, 0)
    }

    func testConfirmedLinkCardNeverReachesImageCopyOrCropButSeparatePhotosSurvive() async throws {
        try await assertLinkCardFiltering()
    }

    func testMissingCardTimestampDoesNotSuppressThePreviousIndependentPhoto() async throws {
        try await assertLinkCardFiltering(omitCardHeader: true)
    }

    func testCopiedURLWhitespaceDoesNotReenableImageClicksOnTheCard() async throws {
        try await assertLinkCardFiltering(copiedPrefix: " \n")
    }

    private func assertLinkCardFiltering(omitCardHeader: Bool = false, copiedPrefix: String = "") async throws {
        // Removing the link-card exclusion must cause thumbnail clicks/crops again.
        let before = CGRect(x: 20, y: 30, width: 200, height: 100)
        let thumbnail = CGRect(x: 20, y: 190, width: 100, height: 100)
        let wholeCard = CGRect(x: 20, y: 180, width: 250, height: 155)
        let after = CGRect(x: 20, y: 410, width: 200, height: 150)
        var lines = [
            OCRLine(text: "buyer 2026-8-25 17:15:51", box: CGRect(x: 20, y: 5, width: 300, height: 20)),
            OCRLine(text: "buyer 2026-8-25 18:17:03", box: CGRect(x: 20, y: 150, width: 300, height: 20)),
            OCRLine(text: "https://detail.tmall.com/item.htm?...", box: CGRect(x: 20, y: 310, width: 210, height: 20)),
            OCRLine(text: "buyer 2026-8-25 18:18:03", box: CGRect(x: 20, y: 370, width: 300, height: 20))
        ]
        if omitCardHeader { lines.remove(at: 1) }
        let events = EventRecorder()
        let copy = RecordingImageCopyResolver()
        let runner = LiveOCRRunner(
            locator: RecordingLocator(events: events),
            captureService: SizedCapture(),
            engine: StaticLinesEngine(lines: lines),
            imageDetector: FixedImageDetector(boxes: [before, thumbnail, after]),
            imageCopyCandidateDetector: FixedImageDetector(boxes: [wholeCard]),
            imageCopyResolver: copy,
            linkResolver: CompletingLinkResolver(prefix: copiedPrefix)
        )

        let result = try await runner.run { _ in }

        XCTAssertEqual(copy.boxes, [before, after], "A confirmed URL card must never be clicked as an image")
        XCTAssertEqual(result.images.map(\.box), [before, after], "The thumbnail must not fall back to a screenshot image")
        XCTAssertTrue(result.lines.contains { $0.text == copiedPrefix + "https://detail.tmall.com/item.htm?id=539699766942" })
    }
}

@MainActor
private struct StaticLinesEngine: OCRRecognizing {
    let lines: [OCRLine]
    func recognize(_ image: CGImage) async throws -> [OCRLine] { lines }
}

@MainActor
private struct SizedCapture: WindowCapturing {
    func capture(_ target: LocatedPanel) async throws -> CGImage {
        CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8,
                  bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

@MainActor
private final class CompletingLinkResolver: LinkResolving {
    let prefix: String
    init(prefix: String = "") { self.prefix = prefix }
    func resolve(lines: [OCRLine], panel: LocatedPanel, imageSize: CGSize) async -> [OCRLine] {
        lines.map { line in
            guard line.text.hasPrefix("https://") else { return line }
            return OCRLine(text: prefix + "https://detail.tmall.com/item.htm?id=539699766942", box: line.box)
        }
    }
}

@MainActor
private final class RecordingImageCopyResolver: ImageCopyResolving {
    var boxes: [CGRect] = []
    var callCount = 0
    func resolve(boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> [DetectedChatImage] {
        callCount += 1
        self.boxes = boxes
        return []
    }
}

@MainActor
private final class RecordingVideoOpener: VideoOpening {
    let outcome: VideoOpenOutcome
    var messageIDs: [String] = []
    var boxes: [CGRect] = []

    init(outcome: VideoOpenOutcome) { self.outcome = outcome }

    func open(messageID: String, customerUID: String, boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> VideoOpenOutcome {
        messageIDs.append(messageID)
        self.boxes = boxes
        return outcome
    }
}

@MainActor
private final class DelayedVideoOpener: VideoOpening {
    let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func open(messageID: String, customerUID: String, boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> VideoOpenOutcome {
        try? await Task.sleep(for: delay)
        return .opened
    }
}

@MainActor
private final class RecordingLinkResolver: LinkResolving {
    let events: EventRecorder

    init(events: EventRecorder) {
        self.events = events
    }

    func resolve(lines: [OCRLine], panel: LocatedPanel, imageSize: CGSize) async -> [OCRLine] {
        events.values.append("resolve-links")
        return lines
    }
}

private struct FixedImageDetector: ChatImageDetecting {
    let boxes: [CGRect]
    func detect(in image: CGImage) -> [CGRect] { boxes }
}

@MainActor
private final class FixedImageCopyResolver: ImageCopyResolving {
    let images: [DetectedChatImage]
    init(images: [DetectedChatImage]) { self.images = images }
    func resolve(boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> [DetectedChatImage] {
        images
    }
}

@MainActor
private final class EventRecorder {
    var values: [String] = []
}

@MainActor
private final class BooleanRecorder {
    var value = false
}

@MainActor
private struct YieldCheckingLocator: PanelLocating {
    let locatingStageRendered: BooleanRecorder
    let events: EventRecorder

    func locate() throws -> LocatedPanel {
        events.values.append("locate-after-yield:\(locatingStageRendered.value)")
        return LocatedPanel(ownerPID: 1, windowTitle: "接待中心", windowFrame: .zero, panelFrame: .zero)
    }
}

@MainActor
private struct RecordingLocator: PanelLocating {
    let events: EventRecorder

    func locate() throws -> LocatedPanel {
        events.values.append("locate")
        return LocatedPanel(ownerPID: 1, windowTitle: "接待中心", windowFrame: .zero, panelFrame: .zero)
    }
}

@MainActor
private final class RecordingCapture: WindowCapturing {
    let events: EventRecorder
    private(set) var callCount = 0

    init(events: EventRecorder) {
        self.events = events
    }

    func capture(_ target: LocatedPanel) async throws -> CGImage {
        callCount += 1
        events.values.append("capture")
        return CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
    }
}

@MainActor
private final class RecordingEngine: OCRRecognizing {
    let events: EventRecorder
    private(set) var callCount = 0

    init(events: EventRecorder) {
        self.events = events
    }

    func recognize(_ image: CGImage) async throws -> [OCRLine] {
        callCount += 1
        events.values.append("recognize")
        return [OCRLine(text: "原文", box: .zero)]
    }
}

@MainActor
private final class NeverReturningEngine: OCRRecognizing {
    private(set) var resetCount = 0

    func recognize(_ image: CGImage) async throws -> [OCRLine] {
        try await Task.sleep(for: .seconds(30))
        return []
    }

    func resetAfterTimeout() {
        resetCount += 1
    }
}

private struct SlowImageDetector: ChatImageDetecting {
    func detect(in image: CGImage) -> [CGRect] {
        Thread.sleep(forTimeInterval: 0.1)
        return []
    }
}
