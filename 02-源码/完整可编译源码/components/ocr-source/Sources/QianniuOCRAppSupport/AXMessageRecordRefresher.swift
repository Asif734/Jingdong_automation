import ApplicationServices
import Foundation
import QianniuOCRCore

@MainActor
protocol MessageRecordRefreshing {
    func refreshAndWait() async throws
}

@MainActor
final class AXMessageRecordRefresher: MessageRecordRefreshing {
    private let reader: AXWindowReader
    private let pollIntervalNanoseconds: UInt64 = 50_000_000

    init(reader: AXWindowReader) {
        self.reader = reader
    }

    func refreshAndWait() async throws {
        let initialTarget = try await findRefreshTarget()
        let initial = makeRefreshSnapshot(
            windowSnapshot: initialTarget.snapshot,
            panelAnchor: initialTarget.panel,
            refreshEntry: initialTarget.refreshEntry
        )

        let pressResult = AXUIElementPerformAction(
            initialTarget.refreshEntry.element,
            kAXPressAction as CFString
        )
        guard pressResult == .success else {
            throw OCRAppError.refreshFailed("AX 刷新操作失败（\(pressResult.rawValue)）")
        }

        let start = ContinuousClock.now
        var samples: [(elapsedMilliseconds: Int, snapshot: RefreshSnapshot)] = []

        while true {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            let current = try reader.read()
            let panel = TargetSelection.messagePanel(
                from: current.candidates,
                inside: current.window.frame
            ) ?? initialTarget.panel
            let refreshCandidate = TargetSelection.refreshButton(
                from: current.candidates,
                nextTo: panel,
                inside: current.window.frame
            )
            let refreshEntry = refreshCandidate.flatMap { current.entry(matching: $0) }
            let sample = makeRefreshSnapshot(
                windowSnapshot: current,
                panelAnchor: panel,
                refreshEntry: refreshEntry
            )
            samples.append((elapsedMilliseconds(from: start), sample))

            switch RefreshStabilityPolicy.decision(initial: initial, samples: samples) {
            case .wait:
                continue
            case .proceedNoChange, .proceedStable, .proceedTimeout:
                return
            }
        }
    }

    private func findRefreshTarget() async throws -> (
        snapshot: AXWindowSnapshot,
        panel: AXCandidate,
        refreshEntry: AXElementEntry
    ) {
        for attempt in 0..<3 {
            let snapshot = try reader.read()
            if let panel = TargetSelection.messagePanel(
                from: snapshot.candidates,
                inside: snapshot.window.frame
            ), let refresh = TargetSelection.refreshButton(
                from: snapshot.candidates,
                nextTo: panel,
                inside: snapshot.window.frame
            ), let refreshEntry = snapshot.entry(matching: refresh) {
                return (snapshot, panel, refreshEntry)
            }

            if attempt < 2 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw OCRAppError.refreshButtonNotFound
    }

    private func makeRefreshSnapshot(
        windowSnapshot: AXWindowSnapshot,
        panelAnchor: AXCandidate,
        refreshEntry: AXElementEntry?
    ) -> RefreshSnapshot {
        let panelFrame = TargetSelection.expandedMessagePanelFrame(
            anchor: panelAnchor.frame,
            window: windowSnapshot.window.frame
        ) ?? panelAnchor.frame

        let fingerprint = windowSnapshot.entries
            .filter { entry in
                let intersection = entry.candidate.frame.intersection(panelFrame)
                return !intersection.isNull && intersection.width > 0 && intersection.height > 0
            }
            .sorted { lhs, rhs in
                let left = lhs.candidate
                let right = rhs.candidate
                if left.frame.minY != right.frame.minY { return left.frame.minY < right.frame.minY }
                if left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
                if left.role != right.role { return left.role < right.role }
                return label(of: left) < label(of: right)
            }
            .map { entry in
                let candidate = entry.candidate
                return [
                    candidate.role,
                    candidate.title ?? "",
                    candidate.description ?? "",
                    candidate.value ?? "",
                    coordinate(candidate.frame.minX),
                    coordinate(candidate.frame.minY),
                    coordinate(candidate.frame.width),
                    coordinate(candidate.frame.height),
                    entry.isEnabled ? "1" : "0",
                    entry.isBusy ? "1" : "0",
                ].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")

        return RefreshSnapshot(
            fingerprint: fingerprint,
            isEnabled: refreshEntry?.isEnabled ?? false,
            isBusy: refreshEntry?.isBusy ?? true
        )
    }

    private func label(of candidate: AXCandidate) -> String {
        [candidate.title, candidate.description, candidate.value]
            .compactMap { $0 }
            .joined(separator: "\u{1F}")
    }

    private func coordinate(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func elapsedMilliseconds(from start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
