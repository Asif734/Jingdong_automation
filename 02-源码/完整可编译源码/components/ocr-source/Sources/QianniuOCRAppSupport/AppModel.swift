import Foundation
import QianniuOCRCore

public enum OCRStage: Equatable, Sendable {
    case locating
    case capturing
    case recognizing
    case detectingImages
    case updatingQueue
    case success

    var statusText: String {
        switch self {
        case .locating: "正在定位千牛主聊天区…"
        case .capturing: "正在截取主聊天区…"
        case .recognizing: "正在识别文字…"
        case .detectingImages: "正在检测聊天图片…"
        case .updatingQueue: "正在更新 AI 客服队列…"
        case .success: "识别完成"
        }
    }
}

public enum OCRDisplayMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case parsed
    case raw

    public var id: Self { self }

    var label: String {
        switch self {
        case .parsed: "解析结果"
        case .raw: "原始 OCR"
        }
    }
}

public enum OCRAppError: LocalizedError, Equatable {
    case accessibilityPermissionMissing
    case screenRecordingPermissionMissing
    case qianniuNotRunning
    case receptionWindowNotFound
    case mainChatRegionNotFound
    case messagePanelNotFound
    case refreshButtonNotFound
    case refreshFailed(String)
    case captureFailed(String)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing: "需要开启辅助功能权限"
        case .screenRecordingPermissionMissing: "需要开启屏幕录制权限"
        case .qianniuNotRunning: "没有找到已打开的千牛"
        case .receptionWindowNotFound: "没有找到千牛接待中心窗口"
        case .mainChatRegionNotFound: "没有可靠定位到千牛主聊天区，请确认接待中心和聊天输入框可见"
        case .messagePanelNotFound: "没有找到右侧“消息记录”面板，请先打开它"
        case .refreshButtonNotFound: "没有找到“消息记录”旁边的刷新按钮"
        case .refreshFailed(let message): "刷新消息记录失败：\(message)"
        case .captureFailed(let message): "截图失败：\(message)"
        case .engineFailed(let message): "OCR 初始化或识别失败：\(message)"
        }
    }
}

@MainActor
public protocol OCRRunning: AnyObject {
    func run(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult
}

public struct DetectedChatImage {
    public let box: CGRect
    public let image: CGImage

    public init(box: CGRect, image: CGImage) {
        self.box = box
        self.image = image
    }
}

public enum VideoOpenOutcome: Equatable, Sendable {
    case opened
    case inFlight
    case alreadyAttempted
    case failedBeforeClick(String)
    case uncertainAfterClick(String)
}

public enum OCRMediaDisposition: Equatable, Sendable {
    case none
    case videoHandled(messageID: String, outcome: VideoOpenOutcome)
}

public struct OCRRunResult {
    public let lines: [OCRLine]
    public let images: [DetectedChatImage]
    public let sourceImageSize: CGSize
    public let identityCandidates: CustomerIdentityCandidates
    public let mediaDisposition: OCRMediaDisposition

    public init(
        lines: [OCRLine],
        images: [DetectedChatImage] = [],
        sourceImageSize: CGSize = .zero,
        identityCandidates: CustomerIdentityCandidates = .empty,
        mediaDisposition: OCRMediaDisposition = .none
    ) {
        self.lines = lines
        self.images = images
        self.sourceImageSize = sourceImageSize
        self.identityCandidates = identityCandidates
        self.mediaDisposition = mediaDisposition
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var status = "准备就绪"
    @Published public private(set) var output = "[]"
    @Published public private(set) var rawOutput = "[]"
    @Published public private(set) var parsedOutput = "[]"
    @Published public private(set) var displayMode: OCRDisplayMode = .parsed
    @Published public private(set) var resolvedIdentity: ResolvedCustomerIdentity?
    @Published public private(set) var isRunning = false
    @Published public private(set) var elapsedMilliseconds: Int?
    @Published public private(set) var detectedImages: [CGImage] = []
    @Published public private(set) var lastQueuePath: String?
    @Published public private(set) var pipelineStatus = PipelineStatusSnapshot.idle
    public private(set) var stageHistory: [OCRStage] = []

    private let runner: any OCRRunning
    private let exporter: (any CustomerRequestExporting)?
    private let pipelineStatusReader: PipelineStatusReader

    public init(runner: any OCRRunning) {
        self.runner = runner
        exporter = nil
        pipelineStatusReader = PipelineStatusReader(root: Self.defaultRecordRoot)
    }

    init(
        runner: any OCRRunning,
        exporter: (any CustomerRequestExporting)?,
        pipelineStatusReader: PipelineStatusReader? = nil
    ) {
        self.runner = runner
        self.exporter = exporter
        self.pipelineStatusReader = pipelineStatusReader
            ?? PipelineStatusReader(root: Self.defaultRecordRoot)
    }

    public static func live(runner: any OCRRunning) -> AppModel {
        AppModel(
            runner: runner,
            exporter: CustomerRequestPackageExporter(
                queueTrigger: CodexBatchAppTrigger()
            )
        )
    }

    public func runOCR() async {
        guard !isRunning else { return }
        isRunning = true
        elapsedMilliseconds = nil
        detectedImages = []
        lastQueuePath = nil
        stageHistory = []
        displayMode = .parsed
        resolvedIdentity = nil
        let start = ContinuousClock.now

        do {
            let result = try await runner.run { [weak self] stage in
                guard let self else { return }
                self.stageHistory.append(stage)
                self.status = stage.statusText
            }
            let parsed = ParsedChatParser.parse(
                lines: result.lines,
                imageBoxes: result.images.map(\.box),
                imageHeight: result.sourceImageSize.height
            )
            rawOutput = try jsonString(parsed.rawOCR)
            parsedOutput = try jsonString(parsed.messages)
            output = parsedOutput
            let ocrCandidate = result.identityCandidates.ocr
                ?? CustomerIdentityExtractor.detectedValue(
                    from: result.lines,
                    imageHeight: result.sourceImageSize.height
                )
            resolvedIdentity = CustomerIdentityResolver.resolve(
                candidates: CustomerIdentityCandidates(
                    axHeader: result.identityCandidates.axHeader,
                    axSessionList: result.identityCandidates.axSessionList,
                    ocr: ocrCandidate
                ),
                requestID: "preview"
            )
            detectedImages = result.images
                .sorted {
                    if $0.box.midY != $1.box.midY { return $0.box.midY < $1.box.midY }
                    return $0.box.minX < $1.box.minX
                }
                .map(\.image)
            var exportWarning: String?
            var hasNoNewMessages = false
            if let exporter {
                stageHistory.append(.updatingQueue)
                status = OCRStage.updatingQueue.statusText
                do {
                    if let queueEntry = try await exporter.export(result: result) {
                        lastQueuePath = queueEntry.path
                    } else {
                        hasNoNewMessages = true
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    exportWarning = "识别完成，但队列更新失败：\(message)"
                }
            }
            stageHistory.append(.success)
            if let exportWarning {
                status = exportWarning
            } else if let resolvedIdentity {
                let review = resolvedIdentity.identity.status == .needsReview ? "，需复核" : ""
                let increment = hasNoNewMessages ? " · 没有新消息" : ""
                status = "识别完成\(increment) · UID：\(resolvedIdentity.identity.value)（\(resolvedIdentity.source.rawValue)\(review)）"
            } else {
                status = hasNoNewMessages ? "识别完成 · 没有新消息" : OCRStage.success.statusText
            }
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        elapsedMilliseconds = start.duration(to: .now).wholeMilliseconds
        isRunning = false
        refreshPipelineStatus()
    }

    public func monitorPipelineStatus() async {
        while !Task.isCancelled {
            refreshPipelineStatus()
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    public func refreshPipelineStatus() {
        let next = pipelineStatusReader.read()
        if next != pipelineStatus {
            pipelineStatus = next
        }
    }

    public func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    public func selectDisplayMode(_ mode: OCRDisplayMode) {
        displayMode = mode
        output = mode == .parsed ? parsedOutput : rawOutput
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    private static var defaultRecordRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录", isDirectory: true)
    }
}

import AppKit

extension Duration {
    var wholeMilliseconds: Int {
        let value = components
        return Int(value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000)
    }
}
