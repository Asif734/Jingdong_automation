import XCTest
@testable import QianniuOCRCore

final class RefreshStabilityTests: XCTestCase {
    func testNoChangeBeforeTwelveHundredMillisecondsKeepsWaiting() {
        let initial = RefreshSnapshot(fingerprint: "same", isEnabled: true, isBusy: false)

        XCTAssertEqual(
            RefreshStabilityPolicy.decision(initial: initial, samples: [(1199, initial)]),
            .wait
        )
    }

    func testNoChangeForTwelveHundredMillisecondsProceedsAsNoNewMessages() {
        let initial = RefreshSnapshot(fingerprint: "same", isEnabled: true, isBusy: false)

        XCTAssertEqual(
            RefreshStabilityPolicy.decision(initial: initial, samples: [(1200, initial)]),
            .proceedNoChange
        )
    }

    func testChangedStateNeedsTwoEqualSamplesAndFiveHundredMilliseconds() {
        let initial = RefreshSnapshot(fingerprint: "old", isEnabled: true, isBusy: false)
        let changed = RefreshSnapshot(fingerprint: "new", isEnabled: true, isBusy: false)

        XCTAssertEqual(
            RefreshStabilityPolicy.decision(
                initial: initial,
                samples: [(450, changed), (500, changed)]
            ),
            .proceedStable
        )
    }

    func testChangedStateWithOnlyOneSampleKeepsWaiting() {
        let initial = RefreshSnapshot(fingerprint: "old", isEnabled: true, isBusy: false)
        let changed = RefreshSnapshot(fingerprint: "new", isEnabled: true, isBusy: false)

        XCTAssertEqual(
            RefreshStabilityPolicy.decision(initial: initial, samples: [(500, changed)]),
            .wait
        )
    }

    func testChangedStateDoesNotFinishWhileRefreshButtonIsBusy() {
        let initial = RefreshSnapshot(fingerprint: "old", isEnabled: true, isBusy: false)
        let busy = RefreshSnapshot(fingerprint: "new", isEnabled: false, isBusy: true)

        XCTAssertEqual(
            RefreshStabilityPolicy.decision(initial: initial, samples: [(500, busy), (550, busy)]),
            .wait
        )
    }

    func testContinuousChangesProceedAtThreeSecondSafetyLimit() {
        let initial = RefreshSnapshot(fingerprint: "old", isEnabled: true, isBusy: false)
        let changing = RefreshSnapshot(fingerprint: "newest", isEnabled: false, isBusy: true)

        XCTAssertEqual(
            RefreshStabilityPolicy.decision(initial: initial, samples: [(3000, changing)]),
            .proceedTimeout
        )
    }
}
