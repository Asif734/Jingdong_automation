import Foundation

/// Only UI status labels are inputs here, never the OCR editor/chat text.
public struct OCRStatusSample: Equatable, Sendable {
    public let status: String
    public let uid: String?
    public let elapsed: String?
    public let isRunning: Bool

    public init?(texts: [String], recognitionButtonEnabled: Bool) {
        let prefixes = ["准备就绪", "正在定位千牛", "正在截取主聊天区", "正在识别文字", "正在检测聊天图片", "正在更新 AI 客服队列", "识别完成", "需要开启", "没有找到", "没有可靠定位", "截图失败", "OCR 初始化", "刷新消息记录失败"]
        guard let text = texts.first(where: { text in prefixes.contains(where: { text.hasPrefix($0) }) }) else { return nil }
        let scanText = String(text.components(separatedBy: "AI 客服处理状态")[0].prefix(700))
        status = scanText.components(separatedBy: "总耗时：")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        elapsed = scanText.components(separatedBy: "总耗时：").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rest = status.components(separatedBy: "UID：").dropFirst().first {
            uid = rest.components(separatedBy: "（")[0].components(separatedBy: " (")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        } else { uid = nil }
        isRunning = !recognitionButtonEnabled || status.hasPrefix("正在")
    }
}

public struct OCRProgressStep: Sendable {
    public let title: String
    public let detail: String
    public let isTerminal: Bool
    public let noNewMessages: Bool
    public let isError: Bool
}

/// A missing baseline never grants permission to attribute an old completion to a new scan.
public struct OCRProgressTracker: Sendable {
    public private(set) var finished = false
    private let uid: String
    private var baseline: OCRStatusSample?
    private var last: OCRStatusSample?
    private var sawRunning = false
    public init(uid: String, baseline: OCRStatusSample?) {
        self.uid = uid; self.baseline = baseline; self.last = baseline
    }
    public mutating func observe(_ sample: OCRStatusSample) -> OCRProgressStep? {
        guard !finished else { return nil }
        if let actual = sample.uid, actual != uid { return nil }
        guard sample != last else { return nil }
        last = sample
        if sample.isRunning { sawRunning = true }
        if !sample.isRunning && !sawRunning && baseline == nil {
            baseline = sample
            return nil
        }
        let queueError = sample.status.hasPrefix("识别完成，但队列更新失败：")
        let success = sample.status.hasPrefix("识别完成") && !queueError
        let errors = ["需要开启", "没有找到", "没有可靠定位", "截图失败", "OCR 初始化", "刷新消息记录失败"]
        let error = !sample.isRunning && (queueError || errors.contains { sample.status.hasPrefix($0) })
        // Successful completion must identify the same customer, even after observing running.
        guard !success || sample.uid == uid else { return nil }
        finished = !sample.isRunning && (success || error)
        return OCRProgressStep(title: sample.status,
            detail: sample.elapsed.map { "一期版总耗时：\($0)（界面观测）" } ?? "一期版界面观测；快速步骤可能在两次采样间完成",
            isTerminal: finished, noNewMessages: success && sample.status.hasPrefix("识别完成 · 没有新消息"), isError: error)
    }
}
