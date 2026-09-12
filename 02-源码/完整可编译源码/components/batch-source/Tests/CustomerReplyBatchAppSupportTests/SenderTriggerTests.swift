import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class SenderTriggerTests: XCTestCase {
    func testLaunchCommandUsesSenderAppBundleThroughLaunchServices() {
        let senderExecutable = URL(
            fileURLWithPath: "/Applications/AI客服三件套.app/Contents/Resources/Components/千牛自动发送-稳定签名版.app/Contents/MacOS/千牛自动发送"
        )

        let command = ProcessSenderTrigger.launchCommand(for: senderExecutable)

        XCTAssertEqual(command.executableURL, URL(fileURLWithPath: "/usr/bin/open"))
        XCTAssertEqual(
            command.arguments,
            [
                "-n",
                "/Applications/AI客服三件套.app/Contents/Resources/Components/千牛自动发送-稳定签名版.app",
                "--args",
                "--run-queue",
            ]
        )
    }
}
