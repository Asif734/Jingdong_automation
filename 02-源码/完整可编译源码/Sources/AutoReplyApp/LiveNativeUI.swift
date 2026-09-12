import Foundation
import AppKit
import AutoReplyCore
import UnreadCore
import QianniuOCRAppSupport
import QianniuSenderAppSupport
import QianniuSenderCore
import OSLog

enum ConversationOpenRoute {
    static func visibleRow(uid: String, rows: [ConversationRow]) -> ConversationRow? {
        ConversationLocator.fresh(uid: uid, rows: rows)
    }
}

@MainActor final class LiveNativeUI: NativeUIAutomation {
    static let discoveryInterval: TimeInterval = 1
    let leaseRegistry = UIOperationLeaseRegistry()
    private let native: NativeSession
    private let sender: QianniuAXSession
    private let list: NativeConversationList
    private let runtimeAdapter: AdaptiveRuntimeAdapter
    private let mediaTypeResolver: any VisualMediaTypeResolving
    private let runner: LiveOCRRunner
    private let safety: NativeSafety
    private let root: URL
    private var nextDiscovery = Date.distantPast
    private var activateOnNextDiscovery = false
    private var expectedUID: String?
    private var openedUID: String?
    private var activeScope = "default"
    private var nicknameRegistry: CustomerNicknameRegistry
    private var identityPendingTracker = IdentityPendingTracker()
    private let identityLog = Logger(subsystem: "com.local.qianniu-auto-reply", category: "soft-identity")
    init(
        root: URL,
        safety: NativeSafety,
        preferStructuralUID: Bool = true,
        ocrRunner: LiveOCRRunner? = nil,
        runtimeAdapter: AdaptiveRuntimeAdapter? = nil,
        mediaTypeResolver: (any VisualMediaTypeResolving)? = nil
    ) {
        self.root = root
        self.safety = safety
        runner = ocrRunner ?? LiveOCRRunner()
        let adapter = runtimeAdapter ?? AdaptiveRuntimeAdapter(profile: .empty)
        self.runtimeAdapter = adapter
        self.mediaTypeResolver = mediaTypeResolver ?? ImageFallbackMediaResolver()
        native = NativeSession(
            preferStructuralUID: preferStructuralUID,
            identityPolicy: adapter.identityPolicy,
            conversationListPolicy: adapter.conversationListPolicy,
            windowPolicy: adapter.windowPolicy
        )
        sender = QianniuAXSession(
            composerPolicy: adapter.composerPolicy,
            sendTrigger: adapter.sendPolicy
        )
        list = NativeConversationList(
            conversationListPolicy: adapter.conversationListPolicy,
            identityPolicy: adapter.identityPolicy
        )
        nicknameRegistry = CustomerNicknameRegistry(url: root.appendingPathComponent("运行状态/身份映射.json"))
    }
    func apply(profile: MachineCompatibilityProfile) {
        runtimeAdapter.update(profile: profile)
        native.apply(profile: profile)
        list.apply(profile: profile)
        sender.apply(composerPolicy: profile.composerPolicy, sendTrigger: profile.sendPolicy)
    }
    func calibrationSnapshot() throws -> CalibrationSnapshot {
        try native.check()
        return try native.calibrationSnapshot()
    }
    func prepareForStart() { activateOnNextDiscovery = true; nextDiscovery = .distantPast }
    func checkSafety() throws {
        try safety.check()
        do { try native.check() } catch { throw AutomationDriverError.unsafeUI(error.localizedDescription) }
    }
    func discover(eligibleUIDs: Set<String>?, lease: UIOperationLease) async throws -> [String] {
        try await requireValid(lease)
        guard Date() >= nextDiscovery else { return [] }
        nextDiscovery = Date().addingTimeInterval(Self.discoveryInterval)
        do {
            if activateOnNextDiscovery {
                activateOnNextDiscovery = false
                try await requireValid(lease)
                try await native.activate()
            }
            try await requireValid(lease)
            try await list.restoreSearch()
            let scene = try native.snapshot()
            let pixels = try await native.capture(scene)
            let dotted = RedDotDetector.targets(image: pixels, window: scene.frame, candidates: scene.candidates)
            let fresh = try native.snapshot()
            guard let targetCandidates = SceneFreshness.confirmed(
                dotted: dotted,
                captured: scene,
                fresh: fresh
            ) else { throw AutomationDriverError.unsafeUI("未读截图后接待窗口发生变化，等待重新核对") }
            activeScope = native.currentReceptionTitle() ?? activeScope
            identityLog.debug("Unread scan candidates=\(scene.candidates.count) matches=\(targetCandidates.count) image=\(pixels.width)x\(pixels.height)")
            for observation in identityPendingTracker.observe(dotted: targetCandidates) {
                identityLog.warning("Unresolved dotted row \(observation.candidate.nodeID): \(String(describing: observation.disposition), privacy: .public)")
            }
            let targetRows = targetCandidates.compactMap(\.row)
            for row in targetRows {
                if let nickname = row.nickname { observeNickname(uid: row.uid, nickname: nickname) }
            }
            let targets = targetRows.map(\.uid)
            if !targets.isEmpty {
                try await requireValid(lease)
                try await native.activate()
            }
            let page = NativeDiscoveryPage(unreadUIDs: targets, selectedUID: nil, eligibleUIDs: eligibleUIDs)
            return page.discoveredUIDs
        } catch let error as AssistantError { throw AutomationDriverError.unsafeUI(error.localizedDescription) }
    }
    func open(uid: String, lease: UIOperationLease) async throws {
        try await requireValid(lease)
        try safety.check(forceProcessCheck: true)
        expectedUID = uid
        openedUID = nil
        sender.bindNickname(uid: uid, nickname: nicknameRegistry.nickname(scope: activeScope, uid: uid))
        do {
            try await requireValid(lease)
            try await native.activate()
            // The unread detector already resolved a concrete, visible conversation row.
            // Prefer that normal list row: putting a UID into Qianniu's global contact
            // search can enter its "create conversation" path instead of switching the
            // existing reception chat.
            try await requireValid(lease)
            try await list.restoreSearch()
            let scene = try native.snapshot()
            if let row = ConversationOpenRoute.visibleRow(uid: uid, rows: scene.rows) {
                try await requireValid(lease)
                try native.click(row, scene: scene)
                try await Task.sleep(for: .milliseconds(350))
            } else {
                try await requireValid(lease)
                try await sender.searchAndOpen(uid: uid)
            }
            openedUID = uid
            if let title = try native.displayHeaderTitle() {
                activeScope = native.currentReceptionTitle() ?? activeScope
                if let nickname = ConversationLocator.customerNickname(from: title) {
                    observeNickname(uid: uid, nickname: nickname)
                }
            }
        }
        catch { throw AutomationDriverError.unsafeUI(error.localizedDescription) }
    }
    func header(lease: UIOperationLease) async throws -> String? {
        try await requireValid(lease)
        guard let expectedUID,
              let routed = ConversationLocator.routedIdentity(expectedUID: expectedUID, openedUID: openedUID) else { return nil }
        do {
            if let actual = try native.displayHeaderTitle(),
               let nickname = ConversationLocator.customerNickname(from: actual) {
                activeScope = native.currentReceptionTitle() ?? activeScope
                observeNickname(uid: expectedUID, nickname: nickname)
            }
        } catch {
            identityLog.warning("Non-blocking header observation failed: \(error.localizedDescription, privacy: .public)")
        }
        return routed
    }

    private func observeNickname(uid: String, nickname: String) {
        do {
            try nicknameRegistry.observe(scope: activeScope, uid: uid, nickname: nickname)
            sender.bindNickname(uid: uid, nickname: nicknameRegistry.nickname(scope: activeScope, uid: uid))
        } catch {
            identityLog.warning("Nickname mapping persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    func observeUnread(uid: String, lease: UIOperationLease) async throws -> (hasUnread: Bool, latestPreviewIsImage: Bool) {
        try await requireValid(lease)
        do {
            try await list.restoreSearch()
            let scene = try native.snapshot()
            let pixels = try await native.capture(scene)
            let fresh = try native.snapshot()
            guard scene == fresh else {
                throw AutomationDriverError.unsafeUI("发送前未读截图期间列表变化，等待重新核对")
            }
            guard let row = ConversationLocator.fresh(uid: uid, rows: fresh.rows) else {
                throw AutomationDriverError.unsafeUI("发送前无法在可见列表中核对目标 UID：\(uid)")
            }
            let hasUnread = RedDotDetector.targets(image: pixels, window: fresh.frame, candidates: fresh.candidates)
                .contains { $0.identity.resolved == uid }
            return (hasUnread, row.latestPreviewIsImage)
        } catch let error as AssistantError {
            throw AutomationDriverError.unsafeUI(error.localizedDescription)
        }
    }
    func recognize(includeImages: Bool, lease: UIOperationLease,
                   stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        try await requireValid(lease)
        _ = try await runtimeAdapter.captureStrategy()
        guard let expectedUID else {
            throw AutomationDriverError.unsafeUI("媒体识别前没有已核对的客户身份")
        }
        let mediaTypeResolver = mediaTypeResolver
        let result = try await runner.run(
            includeImages: includeImages,
            mediaAction: {
                await LiveMediaRouting.action(
                    resolver: mediaTypeResolver,
                    customerUID: expectedUID
                )
            },
            stage: stage
        )
        try await requireValid(lease)
        return result
    }
    func activateForValidation(lease: UIOperationLease) async throws {
        try await requireValid(lease)
        do { try await native.activate() }
        catch { throw AutomationDriverError.unsafeUI(error.localizedDescription) }
    }
    func send(uid: String, text: String, lease: UIOperationLease) async throws -> DeliveryResult {
        try await requireValid(lease)
        _ = try await runtimeAdapter.composerStrategy()
        _ = try await runtimeAdapter.sendStrategy()
        try safety.check(forceProcessCheck: true)
        let marker = root.appendingPathComponent("运行状态/调度器/send-attempts/\(UUID().uuidString).json")
        switch await QianniuSendTransaction(session: sender).send(uid: uid, text: text, attemptMarkerURL: marker) {
        case .sent: return .sent
        case .failedBeforeSend(let reason):
            if reason.contains("UID") || reason.contains("权限") || reason.contains("辅助功能") {
                throw AutomationDriverError.unsafeUI(reason)
            }
            return .failedBeforeSend(reason)
        case .uncertainAfterSend(let reason): return .uncertain(reason)
        }
    }
    func openTransferMenu(uid: String, lease: UIOperationLease) async throws {
        try await requireValid(lease)
        try safety.check(forceProcessCheck: true)
        guard expectedUID == uid, openedUID == uid else {
            throw AutomationDriverError.unsafeUI("打开转人工前当前客户身份未绑定")
        }
        try await native.activate()
        try await requireValid(lease)
        let ownerPID = try native.processIdentifier()
        let visibleBefore = try await TransferPopupCapture.visibleWindowIDs(ownerPID: ownerPID)
        let anchor = try native.pressTransferCurrentUser()
        let popup = try await TransferPopupCapture.waitForPopup(
            anchor: anchor,
            visibleBefore: visibleBefore
        )
        try await requireValid(lease)
        let lines = try await runner.recognizeText(in: popup.topImage)
        guard let localPoint = TransferGroupTabSelection.clickPoint(
            lines: lines,
            imageSize: CGSize(width: popup.topImage.width, height: popup.topImage.height)
        ) else {
            throw AutomationDriverError.unsafeUI("未通过 OCR 唯一识别“转交到组”；未点击内部选项")
        }
        let screenPoint = CGPoint(
            x: popup.frame.minX + localPoint.x,
            y: popup.frame.minY + localPoint.y
        )
        try native.clickTransferPopup(point: screenPoint, popupFrame: popup.frame)
        try await Task.sleep(for: .milliseconds(400))

        guard var groupPopup = try await TransferPopupCapture.recapture(
            popup: popup,
            anchor: anchor
        ) else {
            return
        }
        var groupLines = try await runner.recognizeText(in: groupPopup.fullImage)
        let points = TransferGroupCandidateSelection.clickPoints(
            lines: groupLines,
            imageSize: CGSize(width: groupPopup.fullImage.width, height: groupPopup.fullImage.height)
        )
        for point in points {
            try await requireValid(lease)
            let scaleX = groupPopup.frame.width / CGFloat(groupPopup.fullImage.width)
            let scaleY = groupPopup.frame.height / CGFloat(groupPopup.fullImage.height)
            let candidatePoint = CGPoint(
                x: groupPopup.frame.minX + point.x * scaleX,
                y: groupPopup.frame.minY + point.y * scaleY
            )
            let textsBefore = TransferGroupCandidateSelection.normalizedTexts(groupLines)
            try native.clickTransferPopup(point: candidatePoint, popupFrame: groupPopup.frame)
            try await Task.sleep(for: .milliseconds(450))
            guard let afterPopup = try await TransferPopupCapture.recapture(
                popup: groupPopup,
                anchor: anchor
            ) else {
                return
            }
            let afterLines = try await runner.recognizeText(in: afterPopup.fullImage)
            if TransferGroupCandidateSelection.resultAfterClick(
                popupStillVisible: true,
                recognizedTextsBefore: textsBefore,
                recognizedTextsAfter: TransferGroupCandidateSelection.normalizedTexts(afterLines)
            ) == .selectionAccepted {
                return
            }
            groupPopup = afterPopup
            groupLines = afterLines
        }
    }

    private func requireValid(_ lease: UIOperationLease) async throws {
        guard leaseRegistry.isValid(lease) else {
            throw AutomationDriverError.unsafeUI("过期 UI 操作已丢弃")
        }
        try Task.checkCancellation()
    }
}

struct NativeDiscoveryPage {
    let unreadUIDs: [String]
    let selectedUID: String?
    let eligibleUIDs: Set<String>?
    private func accepts(_ uid: String) -> Bool {
        CapturedHistory.validUID(uid) && (eligibleUIDs?.contains(uid) ?? true)
    }
    private var eligibleUnread: [String] { unreadUIDs.filter(accepts) }
    var discoveredUIDs: [String] { eligibleUnread }
}
