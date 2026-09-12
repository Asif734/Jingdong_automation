import Foundation
import CoreGraphics
import OSLog
import QianniuOCRCore

@MainActor
public final class LiveOCRRunner: OCRRunning, OCRPrewarming {
    private let logger = Logger(subsystem: "com.scy.qianniu-ocr.copy-experiment", category: "image-routing")
    private let locator: any PanelLocating
    private let captureService: any WindowCapturing
    private let engine: any OCRRecognizing
    private let imageDetector: any ChatImageDetecting
    private let imageCopyCandidateDetector: any ChatImageDetecting
    private let imageCopyResolver: any ImageCopyResolving
    private let videoOpener: any VideoOpening
    private let linkResolver: any LinkResolving
    private let deadlines: OCRExecutionDeadlines

    public init() {
        let reader = AXWindowReader()
        locator = AXMainChatLocator(reader: reader)
        captureService = WindowCaptureService()
        engine = PaddleOCRWebEngine()
        imageDetector = ConsensusChatImageDetector()
        imageCopyCandidateDetector = ImageCopyCandidateDetector()
        imageCopyResolver = ChatImageCopyResolver()
        videoOpener = UnavailableVideoOpener()
        linkResolver = ChatLinkResolver()
        deadlines = .live
    }

    public init(
        videoAttemptStoreURL: URL,
        videoLogURLs: [URL],
        bestEffortVideoDownloadDirectoryURL: URL,
        onVideoProgress: @escaping @MainActor @Sendable (VideoOpenProgressPhase) -> Void = { _ in },
        onVideoDownloadStarted: @escaping @Sendable (String, Date) async -> Void = { _, _ in },
        onVideoDownloadCompleted: @escaping @Sendable (BestEffortVideoDownloadCompletion) async -> Void = { _ in }
    ) {
        let reader = AXWindowReader()
        locator = AXMainChatLocator(reader: reader)
        captureService = WindowCaptureService()
        engine = PaddleOCRWebEngine()
        imageDetector = ConsensusChatImageDetector()
        imageCopyCandidateDetector = ImageCopyCandidateDetector()
        imageCopyResolver = ChatImageCopyResolver()
        videoOpener = QianniuVideoOpener(
            journalURL: videoAttemptStoreURL,
            videoTransfers: QianniuBestEffortVideoTransferArmer(
                logURLs: videoLogURLs,
                outputDirectory: bestEffortVideoDownloadDirectoryURL,
                onStarted: onVideoDownloadStarted,
                onCompleted: onVideoDownloadCompleted
            ),
            onProgress: onVideoProgress
        )
        linkResolver = ChatLinkResolver()
        deadlines = .live
    }

    public init(
        videoAttemptStoreURL: URL,
        videoLogURLs: [URL],
        videoDownloadDirectoryURL: URL,
        videoTransferJournalURL: URL,
        onVideoDownloaded: @escaping @Sendable (DownloadedCustomerVideo) async -> Void = { _ in }
    ) {
        let reader = AXWindowReader()
        locator = AXMainChatLocator(reader: reader)
        captureService = WindowCaptureService()
        engine = PaddleOCRWebEngine()
        imageDetector = ConsensusChatImageDetector()
        imageCopyCandidateDetector = ImageCopyCandidateDetector()
        imageCopyResolver = ChatImageCopyResolver()
        videoOpener = QianniuVideoOpener(
            journalURL: videoAttemptStoreURL,
            videoTransfers: QianniuLogVideoTransferArmer(
                logURLs: videoLogURLs,
                outputDirectory: videoDownloadDirectoryURL,
                journalURL: videoTransferJournalURL,
                completion: onVideoDownloaded
            )
        )
        linkResolver = ChatLinkResolver()
        deadlines = .live
    }

    public init(
        videoAttemptStoreURL: URL,
        videoLogURLs: [URL],
        videoTransferStore: DurableVideoTransferStore,
        videoTransferCoordinator: VideoTransferCoordinator,
        onVideoProgress: @escaping @MainActor @Sendable (VideoOpenProgressPhase) -> Void = { _ in }
    ) {
        let reader = AXWindowReader()
        locator = AXMainChatLocator(reader: reader)
        captureService = WindowCaptureService()
        engine = PaddleOCRWebEngine()
        imageDetector = ConsensusChatImageDetector()
        imageCopyCandidateDetector = ImageCopyCandidateDetector()
        imageCopyResolver = ChatImageCopyResolver()
        videoOpener = QianniuVideoOpener(
            journalURL: videoAttemptStoreURL,
            videoTransfers: QianniuResilientVideoTransferArmer(
                logURLs: videoLogURLs,
                coordinator: videoTransferCoordinator
            ),
            transferState: videoTransferStore,
            onProgress: onVideoProgress
        )
        linkResolver = ChatLinkResolver()
        deadlines = .live
    }

    init(
        locator: any PanelLocating,
        captureService: any WindowCapturing,
        engine: any OCRRecognizing,
        imageDetector: any ChatImageDetecting = ConsensusChatImageDetector(),
        imageCopyCandidateDetector: any ChatImageDetecting = ImageCopyCandidateDetector(),
        imageCopyResolver: (any ImageCopyResolving)? = nil,
        videoOpener: (any VideoOpening)? = nil,
        linkResolver: (any LinkResolving)? = nil,
        deadlines: OCRExecutionDeadlines = .live
    ) {
        self.locator = locator
        self.captureService = captureService
        self.engine = engine
        self.imageDetector = imageDetector
        self.imageCopyCandidateDetector = imageCopyCandidateDetector
        self.imageCopyResolver = imageCopyResolver ?? ChatImageCopyResolver()
        self.videoOpener = videoOpener ?? UnavailableVideoOpener()
        self.linkResolver = linkResolver ?? ChatLinkResolver()
        self.deadlines = deadlines
    }

    public func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        try await run(includeImages: true, stage: stage)
    }

    public func prepareOCR() async throws {
        try await engine.prepare()
    }

    public func recognizeText(in image: CGImage) async throws -> [OCRLine] {
        try await engine.recognize(image)
    }

    public func run(includeImages: Bool, stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        try await run(includeImages: includeImages, mediaAction: { .copy }, stage: stage)
    }

    public func run(
        includeImages: Bool,
        mediaAction: @escaping @MainActor @Sendable () async -> DetectedMediaAction,
        stage: @escaping (OCRStage) -> Void
    ) async throws -> OCRRunResult {
        stage(.locating)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(80))
        let panel = try locator.locate()
        stage(.capturing)
        let captureService = captureService
        let image = try await withOCRDeadline(deadlines.capture, stage: "ocr-capture") {
            try await captureService.capture(panel)
        }
        stage(.recognizing)
        let engine = engine
        let recognizedLines: [OCRLine]
        do {
            recognizedLines = try await withOCRDeadline(deadlines.recognition, stage: "ocr-recognize") {
                let lines = try await engine.recognize(image)
                try Task.checkCancellation()
                return lines
            }
        } catch let timeout as OCRStageTimeout {
            engine.resetAfterTimeout()
            throw timeout
        }
        let linkResolver = linkResolver
        let lines = (try? await withOCRDeadline(deadlines.linkResolution, stage: "link-resolution") {
            let lines = await linkResolver.resolve(
                lines: recognizedLines,
                panel: panel,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            try Task.checkCancellation()
            return lines
        }) ?? recognizedLines
        if !includeImages {
            return result(lines: lines, images: [], panel: panel, image: image)
        }
        stage(.detectingImages)
        let detector = imageDetector
        let candidateDetector = imageCopyCandidateDetector
        async let legacyBoxesTask = Task.detached(priority: .userInitiated) {
            detector.detect(in: image)
        }.value
        async let copyBoxesTask = Task.detached(priority: .userInitiated) {
            candidateDetector.detect(in: image)
        }.value
        let linkCards = confirmedLinkCardRegions(original: recognizedLines, resolved: lines)
        func isOutsideLinkCards(_ box: CGRect) -> Bool {
            !linkCards.contains { card in
                let intersection = card.region.intersection(box)
                // A missing OCR header must not stretch the card over earlier
                // photos. Require the candidate to reach this URL's footer.
                let reachesFooter = box.maxY >= card.footer.minY - card.footer.height * 3
                    && box.minY < card.footer.maxY
                return reachesFooter && !intersection.isNull
                    && intersection.width * intersection.height >= box.width * box.height * 0.5
            }
        }
        let rawLegacyBoxes = await legacyBoxesTask
        let rawCopyBoxes = deduplicated(rawLegacyBoxes + (await copyBoxesTask))
        let legacyBoxes = rawLegacyBoxes.filter(isOutsideLinkCards)
        let copyBoxes = rawCopyBoxes.filter(isOutsideLinkCards)
        logger.info("confirmed link cards=\(linkCards.count); image candidates before=\(rawCopyBoxes.count) after=\(copyBoxes.count)")
        if !copyBoxes.isEmpty || !legacyBoxes.isEmpty {
            switch await mediaAction() {
            case .ignore:
                return result(lines: lines, images: [], panel: panel, image: image)
            case .openVideo(let messageID, let customerUID):
                let outcome = await videoOpener.open(
                    messageID: messageID,
                    customerUID: customerUID,
                    boxes: copyBoxes.isEmpty ? legacyBoxes : copyBoxes,
                    panel: panel,
                    imageSize: CGSize(width: image.width, height: image.height)
                )
                return result(
                    lines: lines,
                    images: [],
                    panel: panel,
                    image: image,
                    mediaDisposition: .videoHandled(messageID: messageID, outcome: outcome)
                )
            case .videoInFlight(let messageID):
                return result(
                    lines: lines,
                    images: [],
                    panel: panel,
                    image: image,
                    mediaDisposition: .videoHandled(messageID: messageID, outcome: .inFlight)
                )
            case .copy:
                break
            }
        }
        let imageCopyResolver = imageCopyResolver
        let copiedImages: [DetectedChatImage] = (try? await withOCRDeadline(deadlines.imageResolution, stage: "image-resolution") {
            let images = await imageCopyResolver.resolve(
                boxes: copyBoxes,
                panel: panel,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            try Task.checkCancellation()
            return images
        }) ?? []
        var images = copiedImages
        images.append(contentsOf: legacyBoxes.compactMap { box -> DetectedChatImage? in
            guard copiedImages.allSatisfy({ overlap($0.box, box) < 0.80 }) else { return nil }
            guard let cropped = image.cropping(to: box.integral) else { return nil }
            return DetectedChatImage(box: box, image: cropped)
        })
        return result(lines: lines, images: images, panel: panel, image: image)
    }

    private func result(lines: [OCRLine], images: [DetectedChatImage], panel: LocatedPanel,
                        image: CGImage, mediaDisposition: OCRMediaDisposition = .none) -> OCRRunResult {
        OCRRunResult(
            lines: lines,
            images: images,
            sourceImageSize: CGSize(width: image.width, height: image.height),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: panel.identityCandidates.axHeader,
                axSessionList: panel.identityCandidates.axSessionList,
                ocr: CustomerIdentityExtractor.detectedValue(
                    from: lines,
                    imageHeight: CGFloat(image.height)
                )
            ),
            mediaDisposition: mediaDisposition
        )
    }

    // Copy routing only: do not change OCR, its image detector, or message parsing.
    // The card is bounded by its own message header and URL footer, so a photo
    // in the preceding/following message is not suppressed merely for being nearby.
    private func confirmedLinkCardRegions(original: [OCRLine], resolved: [OCRLine]) -> [(region: CGRect, footer: CGRect)] {
        let headers = original.filter { line in
            let compact = line.text.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "：", with: ":")
            return compact.range(of: #"\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\d{1,2}:\d{2}:\d{2}"#,
                                 options: .regularExpression) != nil
        }
        return zip(original, resolved).compactMap { source, copied in
            guard source.text != copied.text,
                  let url = URLComponents(string: copied.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme == "http" || url.scheme == "https",
                  url.host?.isEmpty == false,
                  source.box.height > 0 else { return nil }
            let top = headers.filter { $0.box.maxY <= source.box.minY }
                .map(\.box.maxY).max() ?? 0
            let height = source.box.height
            return (CGRect(x: source.box.minX - height * 2, y: top,
                           width: source.box.width + height * 8,
                           height: source.box.maxY + height - top), source.box)
        }
    }

    private func deduplicated(_ boxes: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for box in boxes where result.allSatisfy({ overlap($0, box) < 0.80 }) {
            result.append(box)
        }
        return result
    }

    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

public enum DetectedMediaAction: Equatable, Sendable {
    case copy
    case ignore
    case openVideo(messageID: String, customerUID: String)
    case videoInFlight(messageID: String)
}

@MainActor
protocol VideoOpening: AnyObject {
    func open(messageID: String, customerUID: String, boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> VideoOpenOutcome
}

@MainActor
private final class UnavailableVideoOpener: VideoOpening {
    func open(messageID: String, customerUID: String, boxes: [CGRect], panel: LocatedPanel, imageSize: CGSize) async -> VideoOpenOutcome {
        .failedBeforeClick("视频打开器尚未就绪")
    }
}
