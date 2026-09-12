import Foundation
import QianniuOCRCore

@MainActor
public protocol OCRCycleRunning: AnyObject {
    func runOnce() async throws -> OCRCycleOutcome
}

public struct OCRCycleOutcome: Sendable {
    public let queueEntryURL: URL?
    public let uid: String?
    public let elapsedMilliseconds: Double

    public init(
        queueEntryURL: URL?,
        uid: String?,
        elapsedMilliseconds: Double
    ) {
        self.queueEntryURL = queueEntryURL
        self.uid = uid
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

@MainActor
public final class OCRCycleService: OCRCycleRunning {
    private var runner: (any OCRRunning)?
    private let makeRunner: @MainActor () -> any OCRRunning
    private let exporter: any CustomerRequestExporting
    private let now: () -> Date
    private let canReleaseRunner: Bool
    private var isRunning = false
    private var lastUsedAt: Date?

    public init() {
        runner = nil
        makeRunner = { LiveOCRRunner() }
        exporter = CustomerRequestPackageExporter(queueTrigger: nil)
        now = Date.init
        canReleaseRunner = true
    }

    init(
        runner: any OCRRunning,
        exporter: any CustomerRequestExporting
    ) {
        self.runner = runner
        makeRunner = { runner }
        self.exporter = exporter
        now = Date.init
        canReleaseRunner = false
    }

    init(
        makeRunner: @escaping @MainActor () -> any OCRRunning,
        exporter: any CustomerRequestExporting,
        now: @escaping () -> Date
    ) {
        runner = nil
        self.makeRunner = makeRunner
        self.exporter = exporter
        self.now = now
        canReleaseRunner = true
    }

    public func runOnce() async throws -> OCRCycleOutcome {
        isRunning = true
        defer {
            isRunning = false
            lastUsedAt = now()
        }
        let activeRunner: any OCRRunning
        if let runner {
            activeRunner = runner
        } else {
            let created = makeRunner()
            runner = created
            activeRunner = created
        }
        let start = ContinuousClock.now
        let result = try await activeRunner.run { _ in }
        let queueEntryURL = try await exporter.export(result: result)
        let ocrCandidate = result.identityCandidates.ocr
            ?? CustomerIdentityExtractor.detectedValue(
                from: result.lines,
                imageHeight: result.sourceImageSize.height
            )
        let resolved = CustomerIdentityResolver.resolve(
            candidates: CustomerIdentityCandidates(
                axHeader: result.identityCandidates.axHeader,
                axSessionList: result.identityCandidates.axSessionList,
                ocr: ocrCandidate
            ),
            requestID: "ocr-cycle"
        )
        let duration = start.duration(to: .now)
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000

        return OCRCycleOutcome(
            queueEntryURL: queueEntryURL,
            uid: resolved.identity.value,
            elapsedMilliseconds: milliseconds
        )
    }

    @discardableResult
    public func releaseEngineIfIdle(
        since currentDate: Date = Date(),
        idleThreshold: TimeInterval = 15 * 60
    ) -> Bool {
        guard canReleaseRunner,
              !isRunning,
              runner != nil,
              let lastUsedAt,
              currentDate.timeIntervalSince(lastUsedAt) >= idleThreshold else {
            return false
        }
        runner = nil
        return true
    }
}
