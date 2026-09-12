import XCTest
import GrozziieModelTesterCore
@testable import GrozziieModelTesterApp

@MainActor
final class ModelTesterViewModelTests: XCTestCase {
    func testEmptyInputCannotSendAndModelLabelIsFixed() {
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, _ in throw TestError.failed },
            newConversationOperation: { }
        )

        XCTAssertFalse(viewModel.canSend)
        XCTAssertEqual(viewModel.modelLabel, "GPT-5.6 Sol · 中")
    }

    func testSuccessfulSubmissionShowsBothMessagesAndDiagnostic() async {
        let viewModel = ModelTesterViewModel(
            sendOperation: { text, _ in
                XCTAssertEqual(text, "TP732支持Mac吗")
                return ModelTestResult(
                    answer: "TP732不支持原生macOS。",
                    diagnostic: RunDiagnostic.fixture(total: 2100)
                )
            },
            newConversationOperation: { }
        )
        viewModel.inputText = "TP732支持Mac吗"

        await viewModel.submit()

        XCTAssertEqual(viewModel.messages.map(\.text), ["TP732支持Mac吗", "TP732不支持原生macOS。"])
        XCTAssertEqual(viewModel.statusText, "回答完成")
        XCTAssertEqual(viewModel.diagnostic?.totalMilliseconds, 2100)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertTrue(viewModel.inputText.isEmpty)
    }

    func testFailureKeepsVisibleCustomerQuestionAndShowsError() async {
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, _ in throw TestError.failed },
            newConversationOperation: { }
        )
        viewModel.inputText = "M880不开机"

        await viewModel.submit()

        XCTAssertEqual(viewModel.messages.map(\.text), ["M880不开机"])
        XCTAssertTrue(viewModel.statusText.contains("失败"))
        XCTAssertFalse(viewModel.isGenerating)
    }

    func testImageOnlySubmissionIsEnabledAndPassesAttachment() async {
        var received: [String] = []
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, images in
                received = images
                return ModelTestResult(answer: "已看到图片。", diagnostic: RunDiagnostic.fixture(total: 10))
            },
            newConversationOperation: { }
        )
        viewModel.attachmentPaths = ["/tmp/customer.jpg"]

        XCTAssertTrue(viewModel.canSend)
        await viewModel.submit()

        XCTAssertEqual(received, ["/tmp/customer.jpg"])
        XCTAssertEqual(viewModel.messages.first?.text, "[图片]")
        XCTAssertTrue(viewModel.attachmentPaths.isEmpty)
    }

    func testNewConversationClearsVisibleState() async {
        var resetCalled = false
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, _ in
                ModelTestResult(answer: "回答", diagnostic: RunDiagnostic.fixture(total: 10))
            },
            newConversationOperation: { resetCalled = true }
        )
        viewModel.inputText = "问题"
        await viewModel.submit()

        await viewModel.startNewConversation()

        XCTAssertTrue(resetCalled)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.diagnostic)
        XCTAssertEqual(viewModel.statusText, "可以开始测试")
    }

    func testDroppedImagesAreFilteredAndDeduplicated() {
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, _ in throw TestError.failed },
            newConversationOperation: { }
        )

        viewModel.addAttachments(urls: [
            URL(fileURLWithPath: "/tmp/customer.JPG"),
            URL(fileURLWithPath: "/tmp/customer.JPG"),
            URL(fileURLWithPath: "/tmp/second.png"),
            URL(fileURLWithPath: "/tmp/not-an-image.pdf"),
        ])

        XCTAssertEqual(viewModel.attachmentPaths, ["/tmp/customer.JPG", "/tmp/second.png"])
        viewModel.removeAttachment(path: "/tmp/customer.JPG")
        XCTAssertEqual(viewModel.attachmentPaths, ["/tmp/second.png"])
    }

    func testDeleteCurrentHistoryClearsVisibleConversation() async {
        var deleted = false
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, _ in
                ModelTestResult(answer: "回答", diagnostic: RunDiagnostic.fixture(total: 10))
            },
            newConversationOperation: { },
            deleteCurrentOperation: { deleted = true },
            deleteAllOperation: { }
        )
        viewModel.inputText = "问题"
        await viewModel.submit()

        await viewModel.deleteCurrentHistory()

        XCTAssertTrue(deleted)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.statusText, "当前聊天记录已删除")
    }

    func testDeleteAllHistoryClearsVisibleConversation() async {
        var deletedAll = false
        let viewModel = ModelTesterViewModel(
            sendOperation: { _, _ in
                ModelTestResult(answer: "回答", diagnostic: RunDiagnostic.fixture(total: 10))
            },
            newConversationOperation: { },
            deleteCurrentOperation: { },
            deleteAllOperation: { deletedAll = true }
        )
        viewModel.inputText = "问题"
        await viewModel.submit()

        await viewModel.deleteAllHistory()

        XCTAssertTrue(deletedAll)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.statusText, "全部聊天记录已删除")
    }
}

private enum TestError: LocalizedError {
    case failed
    var errorDescription: String? { "模拟失败" }
}

private extension RunDiagnostic {
    static func fixture(total: Double) -> RunDiagnostic {
        RunDiagnostic(
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            loginCheckMilliseconds: 20,
            codexMilliseconds: total - 20,
            totalMilliseconds: total,
            sessionMode: "new",
            submittedHistoryBytes: 10,
            submittedImageCount: 0
        )
    }
}
