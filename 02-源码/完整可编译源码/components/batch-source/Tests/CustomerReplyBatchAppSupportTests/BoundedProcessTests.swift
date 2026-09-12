import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class BoundedProcessTests: XCTestCase {
    func testHardDeadlineTerminatesProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let childPIDURL = root.appendingPathComponent("child.pid")
        let command = "sleep 30 & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait"
        let clock = ContinuousClock()
        let start = clock.now

        let result = await BoundedProcess.run(
            .init(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command]
            ),
            softDeadline: .milliseconds(20),
            hardDeadline: .milliseconds(100)
        )

        XCTAssertEqual(result.termination, .hardDeadline)
        XCTAssertTrue(result.softDeadlineExceeded)
        XCTAssertFalse(result.processGroupStillAlive)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        if let text = try? String(contentsOf: childPIDURL), let pid = Int32(text) {
            XCTAssertNotEqual(kill(pid, 0), 0, "hard deadline must not leave a child process alive")
        }
    }

    func testStreamsOutputAndExitStatus() async {
        let result = await BoundedProcess.run(
            .init(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf out; printf err >&2; exit 7"]
            ),
            softDeadline: .seconds(1),
            hardDeadline: .seconds(2)
        )

        XCTAssertEqual(result.termination, .exited(7))
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "out")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "err")
        XCTAssertFalse(result.softDeadlineExceeded)
        XCTAssertFalse(result.processGroupStillAlive)
    }
}
