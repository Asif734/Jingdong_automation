import Foundation
import Combine

@MainActor
public final class BatchViewModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusText = "等待启动"
    @Published public private(set) var summary: BatchSummary?
    private let runner: any BatchRunning

    public init(runner: any BatchRunning) {
        self.runner = runner
    }

    public func activate() async {
        guard !isRunning, summary == nil else { return }
        isRunning = true
        statusText = "正在处理队列…"
        let value = await runner.runOnce()
        summary = value
        statusText = "处理完成"
        isRunning = false
    }
}
