import XCTest
@testable import CustomerReplyBatchAppSupport

@MainActor
final class BatchViewModelTests: XCTestCase {
    func testActivationStartsExactlyOneBatchAndPublishesSummary() async {
        let runner = CountingRunner()
        let model = BatchViewModel(runner: runner)

        async let first: Void = model.activate()
        async let second: Void = model.activate()
        _ = await (first, second)

        let count = await runner.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.summary?.autoSend, 2)
        XCTAssertEqual(model.statusText, "处理完成")
    }
}

private actor CountingRunner: BatchRunning {
    private(set) var count = 0

    func runOnce() async -> BatchSummary {
        count += 1
        try? await Task.sleep(nanoseconds: 50_000_000)
        var summary = BatchSummary()
        summary.total = 2
        summary.autoSend = 2
        return summary
    }
}
