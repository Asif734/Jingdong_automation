import CryptoKit
import Foundation
import AutoReplyCore
import CustomerReplyBatchCore
import QianniuOCRAppSupport
import QianniuOCRCore

@MainActor protocol NativeUIAutomation: AnyObject {
    var leaseRegistry: UIOperationLeaseRegistry { get }
    func checkSafety() throws
    func discover(eligibleUIDs: Set<String>?, lease: UIOperationLease) async throws -> [String]
    func open(uid: String, lease: UIOperationLease) async throws
    func header(lease: UIOperationLease) async throws -> String?
    func observeUnread(uid: String, lease: UIOperationLease) async throws -> (hasUnread: Bool, latestPreviewIsImage: Bool)
    func recognize(includeImages: Bool, lease: UIOperationLease,
                   stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult
    func activateForValidation(lease: UIOperationLease) async throws
    func send(uid: String, text: String, lease: UIOperationLease) async throws -> DeliveryResult
    func openTransferMenu(uid: String, lease: UIOperationLease) async throws
}

struct NativeOperationDeadlines: Sendable {
    let discovery: Duration
    let openIdentity: Duration
    let recognition: Duration
    let preSendEvidence: Duration
    let sendInvocation: Duration

    static let live = NativeOperationDeadlines(
        discovery: .seconds(5),
        openIdentity: .seconds(5),
        recognition: .seconds(20),
        preSendEvidence: .seconds(8),
        // The transaction has its own 3-second press and 5-second read-only
        // verification limits. This outer circuit breaker must leave room for
        // activation and the bounded unknown-evidence rechecks as well.
        sendInvocation: .seconds(15)
    )
}

@MainActor final class NativeAutomationDriver: AutomationDriver {
    var serviceAliases: Set<String> = []
    var currentUIOwner: String?
    var onStage: ((String?, String) -> Void)?
    private let ui: any NativeUIAutomation
    private let history: CapturedHistory
    private let bridge: AutomationCaptureBridge
    private let transferPlaceholderStore: TransferPlaceholderStore
    private let deadlines: NativeOperationDeadlines
    private let onConfirmedDelivery: @Sendable (Date) async -> Void
    private var leaseRegistry: UIOperationLeaseRegistry { ui.leaseRegistry }
    func revokeUIOperations() { leaseRegistry.revokeAll() }
    init(ui: any NativeUIAutomation, root: URL, knowledgeBasePaths: [String] = [],
         deadlines: NativeOperationDeadlines = .live,
         onConfirmedDelivery: @escaping @Sendable (Date) async -> Void = { _ in }) {
        self.ui = ui
        self.deadlines = deadlines
        self.onConfirmedDelivery = onConfirmedDelivery
        history = CapturedHistory(root: root, knowledgeBasePaths: knowledgeBasePaths)
        bridge = AutomationCaptureBridge(rootDirectory: root)
        transferPlaceholderStore = TransferPlaceholderStore(root: root)
    }
    func discover() async throws -> [String] {
        try ui.checkSafety()
        currentUIOwner = "发现会话"; onStage?(nil, "发现会话")
        defer { currentUIOwner = nil; onStage?(nil, "UI 空闲") }
        let lease = leaseRegistry.acquire(uid: "发现会话")
        return try await bounded(deadlines.discovery, stage: "conversation-discovery", lease: lease) { [ui] in
            try await ui.discover(eligibleUIDs: nil, lease: lease).filter(CapturedHistory.validUID)
        }
    }
    func capture(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot {
        let captureAliases = serviceAliases
        return try await capture(uid: uid, after: cursor, includeImages: true, observationStage: nil, serviceAliases: captureAliases)
    }
    func capture(uid: String, after cursor: CustomerCursor, includeImages: Bool) async throws -> CaptureSnapshot {
        let captureAliases = serviceAliases
        return try await capture(
            uid: uid,
            after: cursor,
            includeImages: includeImages,
            observationStage: includeImages ? nil : "同一任务已尝试图片复制；本次仅核对文字与链接",
            serviceAliases: captureAliases
        )
    }
    func capture(uid: String) async throws -> CaptureSnapshot {
        try await capture(uid: uid, after: .empty)
    }
    func captureBeforeDelivery(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot {
        let captureAliases = serviceAliases
        try validate(uid); try ui.checkSafety()
        let lease = leaseRegistry.acquire(uid: uid)
        let observation = try await bounded(deadlines.preSendEvidence, stage: "pre-send-evidence", lease: lease) { [ui] in
            try await ui.activateForValidation(lease: lease)
            return try await ui.observeUnread(uid: uid, lease: lease)
        }
        let preview = observation.latestPreviewIsImage ? "[图片]" : "非图片/无预览"
        return try await capture(
            uid: uid,
            after: cursor,
            includeImages: observation.hasUnread,
            observationStage: "发送前复核：新红点=\(observation.hasUnread ? "是" : "否")，最新预览=\(preview)",
            serviceAliases: captureAliases
        )
    }
    func captureBeforeDelivery(uid: String) async throws -> CaptureSnapshot {
        try await captureBeforeDelivery(uid: uid, after: .empty)
    }
    private func capture(uid: String, after cursor: CustomerCursor, includeImages: Bool, observationStage: String?,
                         serviceAliases captureAliases: Set<String>) async throws -> CaptureSnapshot {
        try validate(uid); try ui.checkSafety()
        currentUIOwner = uid
        if let observationStage { onStage?(uid, observationStage) }
        onStage?(uid, "打开并核对会话")
        defer { currentUIOwner = nil; onStage?(uid, "UI 空闲") }
        let lease = leaseRegistry.acquire(uid: uid)
        do {
            do {
                try await bounded(deadlines.openIdentity, stage: "open-and-identity", lease: lease) { [ui] in
                    try await ui.open(uid: uid, lease: lease)
                    guard try await ui.header(lease: lease) == uid else {
                        throw AutomationDriverError.unsafeUI("打开聊天后完整 UID 核对失败")
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AutomationDriverError.captureFailedBeforeMedia(error.localizedDescription)
            }
            let result = try await bounded(deadlines.recognition, stage: "ocr-recognition", lease: lease) { [weak self, ui] in
                try await ui.activateForValidation(lease: lease)
                let value = try await ui.recognize(includeImages: includeImages, lease: lease) { stage in
                    Task { @MainActor [weak self] in self?.onStage?(uid, "OCR: \(stage)") }
                }
                try Task.checkCancellation()
                return value
            }
            if case .videoHandled(let messageID, let outcome) = result.mediaDisposition {
                guard leaseRegistry.isValid(lease) else { throw CancellationError() }
                onStage?(uid, Self.videoStage(outcome))
                return CaptureSnapshot(
                    uid: uid,
                    customerRevision: "video:\(Self.hashMessageID(messageID))",
                    historyJSONL: "",
                    hasUnansweredCustomer: false,
                    shouldGenerate: false,
                    startCursor: cursor,
                    endCursor: cursor
                )
            }
            try await bounded(deadlines.openIdentity, stage: "post-capture-identity", lease: lease) { [ui] in
                try await ui.activateForValidation(lease: lease)
                guard try await ui.header(lease: lease) == uid else {
                    throw AutomationDriverError.unsafeUI("采集后完整 UID 核对失败")
                }
            }
            guard leaseRegistry.isValid(lease) else { throw CancellationError() }
            try validate(uid); try ui.checkSafety()
            onStage?(uid, "提交隔离历史与冻结输入")
            let receipt = try await bridge.export(
                result: result,
                expectedUID: uid,
                serviceAliases: captureAliases,
                routedIdentityConfirmed: true
            )
            return try history.snapshot(
                uid: receipt.uid,
                latestSpeaker: receipt.latestSpeaker,
                newlyQueued: receipt.queueEntryURL != nil,
                after: cursor
            )
        } catch is AutomationCaptureError { throw AutomationDriverError.unsafeUI("OCR 身份与完整 UID 不一致；已停止") }
    }

    private static func hashMessageID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func videoStage(_ outcome: VideoOpenOutcome) -> String {
        switch outcome {
        case .opened: return "视频已打开并发起下载；播放器已关闭，继续扫描"
        case .inFlight: return "视频正在后台处理；本轮不重复打开"
        case .alreadyAttempted: return "视频已处理过；本条不重复打开"
        case .failedBeforeClick(let reason): return "视频未点击并结束本轮：\(reason)"
        case .uncertainAfterClick(let reason): return "视频已点击但结果无法确认；禁止重试：\(reason)"
        }
    }
    func send(uid: String, text: String) async throws -> DeliveryResult {
        try validate(uid); try ui.checkSafety()
        currentUIOwner = uid; onStage?(uid, "发送及回读确认")
        defer { currentUIOwner = nil; onStage?(uid, "UI 空闲") }
        let lease = leaseRegistry.acquire(uid: uid)
        let result = try await bounded(deadlines.sendInvocation, stage: "send-invocation", lease: lease) { [ui] in
            try await ui.activateForValidation(lease: lease)
            return try await ui.send(uid: uid, text: text, lease: lease)
        }
        if result == .sent { await onConfirmedDelivery(Date()) }
        return result
    }
    func recordTransferPlaceholder(uid: String, customerRevision: String, reply: ReplyEnvelope) async throws {
        _ = try transferPlaceholderStore.record(
            uid: uid,
            customerRevision: customerRevision,
            reply: reply
        )
        try validate(uid); try ui.checkSafety()
        currentUIOwner = uid; onStage?(uid, "打开转人工选择界面并切换到组")
        defer { currentUIOwner = nil; onStage?(uid, "UI 空闲") }
        let lease = leaseRegistry.acquire(uid: uid)
        // This operation includes ScreenCaptureKit capture and OCR of the popup,
        // so it needs the recognition budget rather than the short AX-open budget.
        try await bounded(deadlines.recognition, stage: "open-transfer-menu", lease: lease) { [ui] in
            try await ui.open(uid: uid, lease: lease)
            guard try await ui.header(lease: lease) == uid else {
                throw AutomationDriverError.unsafeUI("打开转人工前完整 UID 核对失败")
            }
            try await ui.openTransferMenu(uid: uid, lease: lease)
        }
        onStage?(uid, "已从上到下尝试可见转交分组；遇到首个有效分组即停止")
    }
    func reconcile(uid: String, replyText: String, after cursor: CustomerCursor) async throws -> DeliveryObservation {
        let snapshot = try await captureBeforeDelivery(uid: uid, after: cursor)
        return DeliveryEvidence.exactServiceReplyFound(
            in: snapshot.historyJSONL,
            replyText: replyText,
            afterCustomerCount: cursor.count
        )
            ? .exactReplyFound
            : .stableReplyAbsent
    }
    private func validate(_ uid: String) throws {
        guard CapturedHistory.validUID(uid) else {
            throw AutomationDriverError.unsafeUI("UID 不完整或不安全：\(uid)")
        }
    }

    private func bounded<Value: Sendable>(
        _ duration: Duration,
        stage: String,
        lease: UIOperationLease,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await withOperationDeadline(duration, stage: stage, operation: operation)
            guard leaseRegistry.isValid(lease) else { throw CancellationError() }
            return value
        } catch {
            if error is OperationTimeout || error is CancellationError {
                leaseRegistry.revokeAll()
            }
            throw error
        }
    }
}
