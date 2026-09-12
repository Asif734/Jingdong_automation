import AppKit
import Foundation
import QianniuSenderAppSupport

if CommandLine.arguments.contains("--run-queue") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let summary = await SenderApplicationRunner.runQueue()
        let object: [String: Any] = [
            "total": summary.total,
            "sent": summary.sent,
            "failed_before_send": summary.failedBeforeSend,
            "uncertain_after_send": summary.uncertainAfterSend,
            "skipped_already_running": summary.skippedBecauseAlreadyRunning,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = SenderAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
