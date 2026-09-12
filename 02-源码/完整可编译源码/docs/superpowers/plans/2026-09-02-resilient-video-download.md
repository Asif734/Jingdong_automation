# Resilient Customer Video Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make exact-105 customer videos survive transient CDN/DNS failures, application relaunches, and validation failures without silent loss, repeated player clicks, duplicate replies, or blocking other customers.

**Architecture:** Add one durable transfer state machine below the existing exact-105 router, replace the single `URLSession.shared` call with bounded system-route and alternate-route strategies, and relay both successful downloads and bounded failures into the existing scheduler. Opening, downloading, evidence preparation, AI admission, and customer acknowledgement become distinct idempotent states.

**Tech Stack:** Swift 5.9, Foundation `URLSession`, `Process`, CryptoKit, AVFoundation, Swift concurrency actors/task groups, XCTest, existing Qianniu OCR/video-probe packages.

**Spec:** `docs/superpowers/specs/2026-09-02-resilient-video-download-design.md`

## Global Constraints

- Platform remains macOS 14+ and Apple Silicon; no Homebrew dependency.
- Only exact `105`/`MESSAGETEMPLATETYPE_VIDEO` enters this pipeline; `101`/`IMAGETEXT` remains on the established visual path.
- Raw signed URLs and raw message IDs never enter journals, ordinary logs, prompts, exported diagnostics, or filenames.
- Normal successful download uses a 5-second connect timeout and a 15-second total first-attempt timeout.
- Immediate recovery is bounded to 30 seconds total and no more than three alternate addresses.
- Scheduled recovery delays are 60, 180, and 600 seconds with at most 10% jitter.
- Failure of one video must not retain the Qianniu UI lease, consume a Codex slot, pause discovery, or block another customer.
- A validated MP4 and a fallback acknowledgement may each be admitted at most once per message hash.
- Preserve the currently installed app, all customer history, downloaded videos, and diagnostics during migration and rollback.

---

## File Structure

New focused files:

- `components/ocr-source/Sources/QianniuOCRAppSupport/VideoTransferState.swift` — durable transfer phases, failure categories, records, atomic store, migration.
- `components/ocr-source/Sources/QianniuOCRAppSupport/ResilientVideoDownloader.swift` — system-route attempt, validation boundary, strategy composition.
- `components/ocr-source/Sources/QianniuOCRAppSupport/VideoAlternateRoute.swift` — bounded DNS probes, validated addresses, `/usr/bin/curl --resolve` execution and cancellation.
- `components/ocr-source/Sources/QianniuOCRAppSupport/VideoTransferCoordinator.swift` — immediate attempts, delayed retries, leases, restart recovery, terminal event relay.
- `Sources/AutoReplyApp/VideoDownloadFallbackReply.swift` — exact truthful reply used when immediate download routes fail.

Existing files changed:

- `components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoTransfer.swift` — retain log watcher/armer facade, delegate transfer work to the new coordinator, preserve completion compatibility.
- `components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoOpenOnly.swift` — distinguish physical open attempts from in-flight/terminal business state.
- `components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift` — inject transfer coordinator and report in-flight state without reopening.
- `Sources/AutoReplyApp/QianniuMediaLogResolver.swift` — stop treating a detected video as completed before transfer completion.
- `Sources/AutoReplyApp/VideoAnalysisInbox.swift` — accept transfer events, enqueue download fallback once, retain existing evidence flow.
- `Sources/AutoReplyApp/AutomationAppModel.swift` — construct, resume, and observe the coordinator; migrate old journals.
- `Sources/AutoReplyApp/Autoconfiguration/VideoTransferCapabilityProbe.swift` — detect system and alternate-route helpers without opening customer media.
- `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift` and `AdaptiveCalibrationEngine.swift` — persist video-transfer capabilities in the machine profile.
- `Sources/AutoReplyApp/AutomationAppModel.swift` — publish concise transfer recovery state through the existing floating progress model.

---

### Task 1: Durable Video Transfer State and Legacy Migration

**Files:**
- Create: `components/ocr-source/Sources/QianniuOCRAppSupport/VideoTransferState.swift`
- Create: `components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoTransferStateTests.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoTransfer.swift`

**Interfaces:**
- Produces: `VideoTransferKey`, `DurableVideoTransferPhase`, `VideoTransferFailureCategory`, `DurableVideoTransferRecord`, and actor `DurableVideoTransferStore`.
- Produces: `beginOrRead`, `record`, `recordsByMessageHash`, `disposition`, `transition`, `claimLease`, `releaseLease`, `dueRecords`, `markFallbackAdmitted`, and `migrateLegacyJournals`.
- Consumes: the existing SHA-256 message hashing convention and atomic JSON storage directory.

- [ ] **Step 1: Write failing state, atomicity, and migration tests**

```swift
func testOpeningIsNotTerminalAndWaitingForRetryRemainsDueAfterRelaunch() async throws {
    let store = DurableVideoTransferStore(url: stateURL, now: { now })
    let key = VideoTransferKey(customerHash: "customer", messageHash: "message")
    _ = try await store.beginOrRead(key: key, customerUID: "buyer")
    try await store.transition(key, to: .opening)
    try await store.transition(key, to: .waitingForRetry,
                               failure: .connectTimeout,
                               nextAttemptAt: now.addingTimeInterval(60))
    let restored = DurableVideoTransferStore(url: stateURL, now: { now.addingTimeInterval(61) })
    XCTAssertEqual(try await restored.dueRecords().map(\.key), [key])
}

func testLegacyFailedDownloadMigratesToWaitingForRetryButDownloadedStaysCompleted() async throws {
    try legacyJSON.write(to: legacyURL)
    try processedJSON.write(to: processedURL)
    try await store.migrateLegacyJournals(downloadURL: legacyURL, processedURL: processedURL)
    let records = try await store.recordsByMessageHash()
    XCTAssertEqual(records["failed-hash"]?.phase, .waitingForRetry)
    XCTAssertEqual(records["downloaded-hash"]?.phase, .downloaded)
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
swift test --package-path components/ocr-source --filter VideoTransferStateTests
```

Expected: compile failure because the durable types and store do not exist.

- [ ] **Step 3: Implement the minimal state model and store**

```swift
public struct VideoTransferKey: Codable, Hashable, Sendable {
    public let customerHash: String
    public let messageHash: String
}

public enum DurableVideoTransferPhase: String, Codable, Sendable {
    case discovered, opening, addressCaptured, downloading, validating
    case downloaded, preparingEvidence, readyForAI, admittedToAI, completed
    case waitingForRetry, terminalFailure
}

public enum VideoTransferFailureCategory: String, Codable, Sendable {
    case addressUnavailable, dnsResolution, connectTimeout, tlsFailure
    case offline, connectionReset, httpRejected, redirectRejected
    case responseTimeout, invalidContent, invalidVideo, localFile
    case retryBudgetExhausted
}

public enum VideoTransferDisposition: Sendable {
    case needsOpen
    case inFlight
    case waitingUntil(Date)
    case terminal
}

public struct DurableVideoTransferRecord: Codable, Equatable, Sendable {
    public let key: VideoTransferKey
    public var customerUID: String?
    public var phase: DurableVideoTransferPhase
    public var attemptCount: Int
    public var scheduledRetryIndex: Int
    public var nextAttemptAt: Date?
    public var leaseUntil: Date?
    public var needsFreshAddress: Bool
    public var fallbackAdmitted: Bool
    public var fileName: String?
    public var failure: VideoTransferFailureCategory?
    public var updatedAt: Date
}

public actor DurableVideoTransferStore {
    public func beginOrRead(key: VideoTransferKey,
                            customerUID: String) throws -> DurableVideoTransferRecord
    public func bindCustomerUID(_ customerUID: String,
                                to key: VideoTransferKey) throws
    public func record(_ key: VideoTransferKey) throws -> DurableVideoTransferRecord?
    public func recordsByMessageHash() throws -> [String: DurableVideoTransferRecord]
    public func disposition(for key: VideoTransferKey) throws -> VideoTransferDisposition
    public func transition(_ key: VideoTransferKey, to phase: DurableVideoTransferPhase,
                           failure: VideoTransferFailureCategory? = nil,
                           nextAttemptAt: Date? = nil) throws
    public func claimLease(_ key: VideoTransferKey, duration: TimeInterval = 60) throws -> Bool
    public func releaseLease(_ key: VideoTransferKey) throws
    public func dueRecords() throws -> [DurableVideoTransferRecord]
    public func markFallbackAdmitted(_ key: VideoTransferKey) throws
    public func markAnalysisCompleted(messageHash: String) throws
    public func migrateLegacyJournals(downloadURL: URL, processedURL: URL) throws
}
```

Use schema version 2, sorted-key JSON, ISO-8601 dates, `.atomic` writes, a maximum of 10,000 records, and no raw URL/message ID fields. Validate `customerUID` with the same filesystem-safe rules already used by the scheduler, verify its SHA-256 equals `key.customerHash`, keep it local-only, and hash or omit it from exported diagnostics. Migration joins legacy download and processed-event entries by message hash to recover `customerHash`; those old formats do not contain the raw customer UID, so the migrated record keeps `customerUID=nil` and cannot request UI work. When the same exact log event is later observed, call `bindCustomerUID` only after its hash matches. Never invent a runnable customer identity.

- [ ] **Step 4: Run state tests and existing transfer tests**

```bash
swift test --package-path components/ocr-source --filter VideoTransferStateTests
swift test --package-path components/ocr-source --filter QianniuVideoTransferTests
```

Expected: both suites pass; existing journal privacy assertions remain green.

- [ ] **Step 5: Commit**

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/VideoTransferState.swift \
        components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoTransfer.swift \
        components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoTransferStateTests.swift
git commit -m "feat: persist recoverable video transfer state"
```

---

### Task 2: Bounded System-route Downloader and Exact Error Taxonomy

**Files:**
- Create: `components/ocr-source/Sources/QianniuOCRAppSupport/ResilientVideoDownloader.swift`
- Create: `components/ocr-source/Tests/QianniuOCRAppSupportTests/ResilientVideoDownloaderTests.swift`
- Modify: `Tools/QianniuVideoDirectProbe/Sources/QianniuVideoProbeCore/Module.swift`
- Modify: `Tools/QianniuVideoDirectProbe/Tests/QianniuVideoProbeCoreTests/VideoLogProbeTests.swift`

**Interfaces:**
- Produces: protocol `VideoDownloadAttempting` and `SystemRouteVideoDownloader`.
- Produces: `VideoDownloadAttemptResult` and typed `VideoTransferAttemptError` with sanitized category.
- Consumes: `VideoTransferInspection` and `VideoFileInspector`.

- [ ] **Step 1: Write failing URL validation, timeout mapping, and privacy tests**

```swift
func testConnectTimeoutPreservesCategoryWithoutLeakingURL() async throws {
    let downloader = SystemRouteVideoDownloader(session: .failing(.timedOut))
    do {
        _ = try await downloader.download(approvedURL, to: destination)
        XCTFail("expected timeout")
    } catch let error as VideoTransferAttemptError {
        XCTAssertEqual(error.category, .connectTimeout)
        XCTAssertFalse(error.sanitizedDescription.contains("auth_key"))
    }
}

func testRedirectToUnapprovedHostIsRejected() async throws {
    let result = await attempt(redirect: "https://example.invalid/video.mp4")
    XCTAssertEqual(result.failure, .redirectRejected)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test --package-path components/ocr-source --filter ResilientVideoDownloaderTests
swift test --package-path Tools/QianniuVideoDirectProbe --filter VideoLogProbeTests
```

Expected: compile failure for the new downloader interfaces.

- [ ] **Step 3: Implement a dedicated ephemeral-session attempt**

```swift
public protocol VideoDownloadAttempting: Sendable {
    func download(_ source: URL, to destination: URL) async throws -> VideoDownloadAttemptResult
}

public struct VideoDownloadAttemptResult: Sendable {
    public let statusCode: Int
    public let elapsedMilliseconds: Int
    public let bytes: Int64
}

public struct SystemRouteVideoDownloader: VideoDownloadAttempting {
    public func download(_ source: URL, to destination: URL) async throws -> VideoDownloadAttemptResult
}
```

Construct a new `URLSessionConfiguration.ephemeral` per call, set request timeout to 5 seconds and resource timeout to 15 seconds, disable waits-for-connectivity, validate HTTPS and the exact allowlisted host, reject unapproved redirects, map `URLError` codes into the durable taxonomy, and invalidate the session in `defer`.

- [ ] **Step 4: Run tests and confirm GREEN**

```bash
swift test --package-path components/ocr-source --filter ResilientVideoDownloaderTests
swift test --package-path Tools/QianniuVideoDirectProbe --filter VideoLogProbeTests
```

Expected: pass with no signed URL present in serialized errors.

- [ ] **Step 5: Commit**

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/ResilientVideoDownloader.swift \
        components/ocr-source/Tests/QianniuOCRAppSupportTests/ResilientVideoDownloaderTests.swift \
        Tools/QianniuVideoDirectProbe/Sources/QianniuVideoProbeCore/Module.swift \
        Tools/QianniuVideoDirectProbe/Tests/QianniuVideoProbeCoreTests/VideoLogProbeTests.swift
git commit -m "feat: classify bounded video download failures"
```

---

### Task 3: Alternate CDN Address Resolution and First-success Race

**Files:**
- Create: `components/ocr-source/Sources/QianniuOCRAppSupport/VideoAlternateRoute.swift`
- Create: `components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoAlternateRouteTests.swift`

**Interfaces:**
- Produces: `AlternateVideoRouteProviding.candidates(for:)`.
- Produces: `CurlResolvedVideoDownloader.download(source:resolvedAddress:destination:)`.
- Produces: `AlternateRouteRace.downloadFirstValid(...)`.
- Consumes: approved hostname, sanitized failure taxonomy, and injected `ProcessRunning` for tests.

- [ ] **Step 1: Write failing resolver, argument-safety, and race tests**

```swift
func testResolverReturnsAtMostThreeDistinctPublicAddressesAcrossPools() async throws {
    let values = try await resolver.candidates(for: "msg2.cloudvideocdn.taobao.com")
    XCTAssertEqual(values.count, 3)
    XCTAssertGreaterThanOrEqual(Set(values.map(\.poolID)).count, 2)
    XCTAssertTrue(values.allSatisfy(\.isPublicAddress))
}

func testCurlUsesArgumentArrayAndNeverLogsSignedURL() async throws {
    _ = try await downloader.download(source: signedURL, resolvedAddress: "93.184.216.34", to: output)
    XCTAssertEqual(process.executable, "/usr/bin/curl")
    XCTAssertTrue(process.arguments.contains("--resolve"))
    XCTAssertFalse(process.arguments.joined(separator: " ").contains("auth_key"))
    XCTAssertTrue(process.receivedSensitiveStdin)
    XCTAssertFalse(logger.text.contains("auth_key"))
}

func testRaceCancelsLosingDownloadsAndPublishesOneWinner() async throws {
    let receipt = try await race.downloadFirstValid(candidates: threeRoutes)
    XCTAssertEqual(receipt.routeID, "fast")
    XCTAssertEqual(processes.cancelledIDs.sorted(), ["slow-a", "slow-b"])
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test --package-path components/ocr-source --filter VideoAlternateRouteTests
```

Expected: compile failure because the alternate-route interfaces do not exist.

- [ ] **Step 3: Implement the bounded helper**

```swift
struct AlternateVideoRoute: Hashable, Sendable {
    let address: String
    let poolID: String
    let family: AddressFamily
}

enum AddressFamily: Sendable {
    case ipv4
    case ipv6
}

struct SanitizedProcessResult: Sendable {
    let exitStatus: Int32
    let stderrCategory: VideoTransferFailureCategory?
}

protocol RunningProcess: Sendable {
    var processGroupID: Int32 { get }
    func wait() async -> SanitizedProcessResult
    func terminate(grace: Duration) async
}

protocol ProcessRunning: Sendable {
    func spawn(executable: String, arguments: [String],
               sensitiveStandardInput: Data?, processGroup: Bool) throws -> any RunningProcess
}

protocol AlternateVideoRouteProviding: Sendable {
    func candidates(for approvedHost: String) async throws -> [AlternateVideoRoute]
}

struct CurlResolvedVideoDownloader: Sendable {
    func download(source: URL, resolvedAddress: String,
                  destination: URL) async throws -> VideoDownloadAttemptResult
}
```

Use `/usr/bin/dig` with argument arrays against `223.5.5.5` and `119.29.29.29`, a 3-second per-resolver deadline, exact host matching, `inet_pton` validation, and rejection of loopback/private/link-local/multicast/reserved addresses. Execute `/usr/bin/curl` with `--config -`, `--fail-with-body`, `--silent`, `--show-error`, `--connect-timeout 5`, `--max-time 15`, and `--resolve host:443:address`. Pass the escaped `url = "..."` config line through a non-logged stdin pipe so the signed URL never appears in the process argument list or `ps`; reject quotes, backslashes, CR/LF, or other unexpected URL characters before encoding. Capture only exit code and sanitized stderr category. Implement `SanitizedProcessResult` without preserving the argument vector or sensitive stdin. Launch curl through a `posix_spawn` runner with `POSIX_SPAWN_SETPGROUP`; use a throwing task group and call `RunningProcess.terminate(grace:)`, which sends `SIGTERM` and then bounded `SIGKILL`, for every loser after the first inspected winner.

- [ ] **Step 4: Run focused tests and leak scan**

```bash
swift test --package-path components/ocr-source --filter VideoAlternateRouteTests
rg -n "auth_key=|msg2\.cloudvideocdn.*\.mp4\?" components/ocr-source/.build || true
```

Expected: tests pass; leak scan prints no generated logs or fixtures containing a real signed URL.

- [ ] **Step 5: Commit**

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/VideoAlternateRoute.swift \
        components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoAlternateRouteTests.swift
git commit -m "feat: recover video downloads across CDN routes"
```

---

### Task 4: Background Coordinator, Immediate Budget, and Scheduled Recovery

**Files:**
- Create: `components/ocr-source/Sources/QianniuOCRAppSupport/VideoTransferCoordinator.swift`
- Create: `components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoTransferCoordinatorTests.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoTransfer.swift`

**Interfaces:**
- Produces: `VideoTransferEvent.downloaded`, `.immediateRoutesExhausted`, `.freshAddressNeeded`, and `.stateChanged`.
- Produces: actor `VideoTransferCoordinator.start`, `resume`, `observe`, and `submitCapturedAddress`.
- Consumes: durable store, system downloader, alternate race, inspector, clock/sleeper, output directory.

- [ ] **Step 1: Write failing orchestration and restart tests**

```swift
func testSystemTimeoutThenAlternateSuccessEmitsOneDownloadedEvent() async throws {
    let coordinator = makeCoordinator(system: .failure(.connectTimeout), alternate: .success(video))
    await coordinator.submitCapturedAddress(key: key, source: signedURL, customerUID: "buyer")
    XCTAssertEqual(await events.downloaded.count, 1)
    XCTAssertEqual(try await store.record(key)?.phase, .downloaded)
}

func testImmediateExhaustionEmitsOneFallbackAndSchedulesSixtySecondRetry() async throws {
    await coordinator.submitCapturedAddress(key: key, source: signedURL, customerUID: "buyer")
    XCTAssertEqual(await events.exhausted.count, 1)
    XCTAssertEqual(try await store.record(key)?.nextAttemptAt, now.addingTimeInterval(60))
}

func testRelaunchClaimsExpiredLeaseAndResumesWithoutDuplicateCompletion() async throws {
    try await seedWaitingRecord(leaseExpired: true)
    await restored.resume()
    XCTAssertEqual(await events.downloaded.count, 1)
    XCTAssertEqual(await events.fallback.count, 0)
}

func testDueRetryWithoutInMemoryURLRequestsOneFreshAddressCapture() async throws {
    try await seedWaitingRecord(customerUID: "buyer", leaseExpired: true)
    await restored.resume()
    XCTAssertEqual(await events.freshAddressRequests.map(\.customerUID), ["buyer"])
    await restored.resume()
    XCTAssertEqual(await events.freshAddressRequests.count, 1)
}

func testUnboundLegacyRetryNeverRequestsUIUntilMatchingUIDIsBound() async throws {
    try await seedWaitingRecord(customerUID: nil, leaseExpired: true)
    await restored.resume()
    XCTAssertEqual(await events.freshAddressRequests.count, 0)
    try await store.bindCustomerUID("buyer", to: key)
    await restored.resume()
    XCTAssertEqual(await events.freshAddressRequests.map(\.customerUID), ["buyer"])
}

func testRelaunchReemitsUnadmittedFallbackButNotAdmittedFallback() async throws {
    try await seedWaitingRecord(customerUID: "buyer", fallbackAdmitted: false)
    await restored.resume()
    XCTAssertEqual(await events.exhausted.count, 1)
    try await store.markFallbackAdmitted(key)
    await makeSecondRestoredCoordinator().resume()
    XCTAssertEqual(await events.exhausted.count, 1)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test --package-path components/ocr-source --filter VideoTransferCoordinatorTests
```

- [ ] **Step 3: Implement orchestration with injected time**

```swift
public enum VideoTransferEvent: Sendable {
    case downloaded(DownloadedCustomerVideo)
    case immediateRoutesExhausted(VideoTransferFailureNotice)
    case freshAddressNeeded(VideoTransferFreshAddressRequest)
    case stateChanged(VideoTransferPublicStatus)
}

public struct VideoTransferFreshAddressRequest: Sendable {
    public let customerUID: String
    public let messageHash: String
}

public struct VideoTransferFailureNotice: Sendable {
    public let customerUID: String
    public let messageHash: String
    public let category: VideoTransferFailureCategory
}

public struct VideoTransferPublicStatus: Sendable {
    public let customerUID: String
    public let messageHash: String
    public let phase: DurableVideoTransferPhase
    public let attempt: Int
}

public actor VideoTransferCoordinator {
    public func submitCapturedAddress(key: VideoTransferKey, source: URL,
                                      customerUID: String) async
    public func resume() async
    public func observe(_ handler: @escaping @Sendable (VideoTransferEvent) async -> Void)
}
```

Run system route first, then alternate race only for retryable transport failures. Enforce the 30-second total deadline. Persist 60/180/600-second due dates with injected jitter. Do not sleep while holding the actor or any UI lease: register a detached wake task, re-enter the actor, claim the renewable lease, and execute one due job. Publish through a unique partial file and call completion exactly once.

For a relaunched record without an in-memory signed URL, set `needsFreshAddress = true` and emit one leased `.freshAddressNeeded` request. The app relays that request into a scheduler-owned external discovery for the stored validated customer UID. During that capture, the exact-105 resolver rescans recent logs, matches the durable message hash, and the opener supplies the raw message ID again. Never synthesize a URL or store it on disk. If automation is stopped or another UI job owns the lane, retain the durable request and try again later without blocking other customers.

- [ ] **Step 4: Run focused and existing transfer tests**

```bash
swift test --package-path components/ocr-source --filter VideoTransferCoordinatorTests
swift test --package-path components/ocr-source --filter QianniuVideoTransferTests
```

- [ ] **Step 5: Commit**

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/VideoTransferCoordinator.swift \
        components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoTransfer.swift \
        components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoTransferCoordinatorTests.swift
git commit -m "feat: coordinate recoverable video transfers"
```

---

### Task 5: Separate Physical Open from Business Completion

**Files:**
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoOpenOnly.swift`
- Modify: `components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift`
- Modify: `Sources/AutoReplyApp/QianniuMediaLogResolver.swift`
- Modify: `components/ocr-source/Tests/QianniuOCRAppSupportTests/QianniuVideoOpenOnlyTests.swift`
- Modify: `Tests/AutoReplyAppTests/QianniuMediaLogResolverTests.swift`

**Interfaces:**
- Consumes: `DurableVideoTransferStore.disposition(for:)` returning `.needsOpen`, `.inFlight`, `.waitingUntil(Date)`, or `.terminal`.
- Produces: media actions `.openVideo`, `.videoInFlight`, and existing `.copy`.
- Preserves: one physical click per active open attempt and exact-105 routing.

- [ ] **Step 1: Write failing non-reopen and retry-eligibility tests**

```swift
func testOpenedButDownloadingVideoDoesNotReopen() async throws {
    try await store.seed(key, phase: .downloading)
    let result = await opener.open(messageID: rawID, customerUID: "buyer", boxes: boxes,
                                   panel: panel, imageSize: size)
    XCTAssertEqual(result, .inFlight)
    XCTAssertEqual(environment.clicks, [])
}

func testFailedLegacyAttemptCanOpenWhenDurableRetryIsDue() async throws {
    try await legacyAttempts.mark(.opened, for: rawID)
    try await store.seed(key, phase: .waitingForRetry, nextAttemptAt: past)
    _ = await opener.open(messageID: rawID, customerUID: "buyer", boxes: boxes,
                          panel: panel, imageSize: size)
    XCTAssertEqual(environment.clicks.count, 1)
}

func testResolverDoesNotRecordVideoAsProcessedBeforeTransferTerminalState() async throws {
    let resolution = await resolver.resolve(customerUID: "buyer", now: now)
    XCTAssertEqual(resolution, .openVideo(messageID: "video-id"))
    XCTAssertFalse(try persistedProcessedJournal.contains("video-id-hash"))
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test --package-path components/ocr-source --filter QianniuVideoOpenOnlyTests
swift test --filter QianniuMediaLogResolverTests
```

- [ ] **Step 3: Implement disposition-aware routing**

Change `QianniuMediaLogResolver` so image events retain existing bookkeeping, while video events consult durable transfer disposition and are not written to the old processed journal at discovery. Change `QianniuVideoOpener` so the old attempt journal prevents duplicate clicks only during a non-expired physical attempt; a durable due retry explicitly authorizes one fresh click. `LiveOCRRunner` returns a non-generating in-flight observation without entering image copy.

Use the `VideoTransferDisposition` defined in Task 1; do not add a second routing state model.

- [ ] **Step 4: Run OCR and root media tests**

```bash
swift test --package-path components/ocr-source --filter QianniuVideoOpenOnlyTests
swift test --filter QianniuMediaLogResolverTests
```

- [ ] **Step 5: Commit**

```bash
git add components/ocr-source/Sources/QianniuOCRAppSupport/QianniuVideoOpenOnly.swift \
        components/ocr-source/Sources/QianniuOCRAppSupport/LiveOCRRunner.swift \
        Sources/AutoReplyApp/QianniuMediaLogResolver.swift \
        components/ocr-source/Tests/QianniuOCRAppSupportTests/QianniuVideoOpenOnlyTests.swift \
        Tests/AutoReplyAppTests/QianniuMediaLogResolverTests.swift
git commit -m "fix: keep failed videos eligible for recovery"
```

---

### Task 6: One-time Prepared Customer Fallback and Successful AI Handoff

**Files:**
- Create: `Sources/AutoReplyApp/VideoDownloadFallbackReply.swift`
- Create: `Tests/AutoReplyAppTests/VideoDownloadFallbackReplyTests.swift`
- Modify: `Sources/AutoReplyCore/AutoReplyScheduler.swift`
- Modify: `Sources/AutoReplyCore/SchedulerModels.swift`
- Modify: `Tests/AutoReplyCoreTests/SchedulerTests.swift`
- Modify: `Sources/AutoReplyApp/VideoAnalysisInbox.swift`
- Modify: `Tests/AutoReplyAppTests/VideoAnalysisInboxTests.swift`
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`

**Interfaces:**
- Consumes: `VideoTransferEvent` from Task 4.
- Produces: scheduler revisions `video-download-fallback:\(messageHash)` and existing `video-analysis:\(messageHash)`.
- Produces: `PreparedReplyAdmission` and `AutoReplyScheduler.admitPreparedReply(uid:customerRevision:historyJSONL:reply:) async -> PreparedReplyAdmission`.
- Produces: `AutoReplyScheduler.admitExternalDiscovery(uid:sourceRevision:) async -> Bool` for a due fresh-address capture.
- Produces: scheduler terminal-delivery callback `(uid, customerRevision, outcome)` for external jobs.
- Consumes: `scheduler.admitExternalSnapshot` deduplication and existing video evidence coordinator.

- [ ] **Step 1: Write failing one-time fallback and eventual-success tests**

```swift
func testImmediateFailureAdmitsTruthfulFallbackExactlyOnce() async throws {
    await coordinator.receive(.immediateRoutesExhausted(notice))
    await coordinator.receive(.immediateRoutesExhausted(notice))
    XCTAssertEqual(await readyRecords.map(\.customerRevision), ["video-download-fallback:hash"])
    XCTAssertEqual(await readyRecords[0].reply?.replyText,
                   "亲，视频暂时加载失败，麻烦您重新发送一次或简单描述一下问题，我这边继续帮您查看。")
    XCTAssertEqual(await generator.requestCount, 0)
}

func testPreparedReplyCarriesSnapshotAndCanReachDelivery() async throws {
    let result = await scheduler.admitPreparedReply(
        uid: "buyer", customerRevision: "video-download-fallback:hash",
        historyJSONL: fallbackHistory, reply: fallbackEnvelope
    )
    XCTAssertEqual(result, .inserted)
    XCTAssertNotNil(scheduler.records.first?.snapshot)
    await scheduler.tick()
    XCTAssertEqual(driver.sentTexts, [VideoDownloadFallbackReply.text])
}

func testLaterDownloadAfterFallbackStillAdmitsEvidenceAnswerOnce() async throws {
    await coordinator.receive(.immediateRoutesExhausted(notice))
    await coordinator.receive(.downloaded(receipt))
    await coordinator.receive(.downloaded(receipt))
    XCTAssertEqual(Set(await admitted.map(\.customerRevision)),
                   ["video-download-fallback:hash", "video-analysis:hash"])
}


func testConfirmedVideoAnalysisDeliveryCompletesDurableTransfer() async throws {
    await deliveryObserver("buyer", "video-analysis:hash", .sent)
    XCTAssertEqual(try await transferStore.recordsByMessageHash()["hash"]?.phase,
                   .completed)
}

func testFreshAddressRequestQueuesOneDiscoveryWithoutGenerating() async throws {
    let first = await scheduler.admitExternalDiscovery(
        uid: "buyer", sourceRevision: "video-address-refresh:hash"
    )
    let second = await scheduler.admitExternalDiscovery(
        uid: "buyer", sourceRevision: "video-address-refresh:hash"
    )
    XCTAssertTrue(first)
    XCTAssertFalse(second)
    XCTAssertEqual(scheduler.records.filter { $0.state == .discovered }.count, 1)
    XCTAssertEqual(generator.requestCount, 0)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test --filter VideoDownloadFallbackReplyTests
swift test --filter VideoAnalysisInboxTests
swift test --filter SchedulerTests
```

- [ ] **Step 3: Implement prepared fallback admission and event relay**

```swift
enum VideoDownloadFallbackReply {
    static let text = "亲，视频暂时加载失败，麻烦您重新发送一次或简单描述一下问题，我这边继续帮您查看。"
}
```

Add `PreparedReplyAdmission` with `.inserted`, `.alreadyPresent`, and `.rejected`, then add `admitPreparedReply` beside `admitExternalSnapshot`. It inserts a `.ready` scheduler record with both a low-risk `.autoSend` `ReplyEnvelope` and a minimal `CaptureSnapshot` containing the UID, synthetic video-download failure JSONL, the same line in `targetCustomerJSONL`, revision, and `hasUnansweredCustomer=true`; otherwise the existing delivery guard would silently skip it. The prepared path never calls `ReplyGenerating`. Route successful downloads through the existing `VideoAnalysisCoordinator`. Mark fallback admission in the durable store only for `.inserted` or `.alreadyPresent`; `.rejected` remains recoverable and is retried without pretending the fallback was queued. Normal scheduler delivery retry handles send failures.

Add `admitExternalDiscovery` as a deduplicated `.discovered` record that uses the ordinary shared UI lane and performs no generation by itself; preserve `sourceRevision` on `SchedulerRecord` so repeated coordinator wakeups cannot create duplicates before capture. AutomationAppModel maps `.freshAddressNeeded` into this method and acknowledges the coordinator lease only after insertion or an already-present matching discovery.

Add an async scheduler callback that runs only after a job has durably reached terminal delivery accounting and supplies `uid`, `customerRevision`, and `SchedulerDeliveryOutcome`. Wire `video-analysis:<messageHash>` revisions to both `VideoAnalysisInbox.markCompleted` and `DurableVideoTransferStore.markAnalysisCompleted`. Treat `.sent` and `.uncertain` as terminal for this transfer: the scheduler deliberately forbids automatic resend after an uncertain click, so the transfer must not create a second evidence answer. A safely failed-before-send reply stays `.ready` and does not fire the callback. A fallback revision only updates scheduler delivery state; it must not stop background video recovery.

- [ ] **Step 4: Run focused tests and scheduler regression tests**

```bash
swift test --filter VideoDownloadFallbackReplyTests
swift test --filter VideoAnalysisInboxTests
swift test --filter SchedulerTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoReplyApp/VideoDownloadFallbackReply.swift \
        Sources/AutoReplyApp/VideoAnalysisInbox.swift \
        Sources/AutoReplyApp/AutomationAppModel.swift \
        Sources/AutoReplyCore/AutoReplyScheduler.swift \
        Sources/AutoReplyCore/SchedulerModels.swift \
        Tests/AutoReplyAppTests/VideoDownloadFallbackReplyTests.swift \
        Tests/AutoReplyAppTests/VideoAnalysisInboxTests.swift \
        Tests/AutoReplyCoreTests/SchedulerTests.swift
git commit -m "feat: acknowledge failed video downloads without silence"
```

---

### Task 7: Startup Recovery, Capability Detection, and Operator Status

**Files:**
- Modify: `Sources/AutoReplyApp/AutomationAppModel.swift`
- Create: `Sources/AutoReplyApp/Autoconfiguration/VideoTransferCapabilityProbe.swift`
- Create: `Tests/AutoReplyAppTests/VideoTransferCapabilityProbeTests.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift`
- Modify: `Tests/AutoReplyAppTests/AutoconfigurationStoreTests.swift`
- Modify: `Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift`
- Modify: `Tests/AutoReplyAppTests/AutomationAppModelTests.swift`

**Interfaces:**
- Consumes: `VideoTransferCoordinator.resume()` and `VideoTransferPublicStatus`.
- Produces: compatibility fields `systemVideoDownloadAvailable`, `alternateVideoRouteAvailable`, and sanitized `videoTransferMode`.
- Produces: floating UI status strings specified by the design.

- [ ] **Step 1: Write failing capability, schema-migration, and recovery-status tests**

Add these assertions to the named test files:

```swift
XCTAssertTrue(profile.systemVideoDownloadAvailable)
XCTAssertTrue(profile.alternateVideoRouteAvailable)
XCTAssertEqual(model.videoStatus, "CDN线路不可达，正在换线路")
XCTAssertEqual(coordinator.resumeCallCount, 1)
```

- [ ] **Step 2: Run the exact newly edited tests and confirm RED**

```bash
swift test --filter VideoTransferCapabilityProbeTests
swift test --filter AutoconfigurationStoreTests
swift test --filter CompatibilityFixtureReplayTests
swift test --filter AutomationAppModelTests
```

- [ ] **Step 3: Implement capability probe and startup wiring**

Add `VideoTransferCapabilityProbe.probe(fileManager:runner:)` that checks executable/readability of `/usr/bin/curl` and `/usr/bin/dig` and performs only a bounded hostname connectivity probe, never opening media during setup. Bump `MachineCompatibilityProfile.schemaVersion` from 3 to 4 and add computed accessors backed by capability keys `videoDownloadSystem` and `videoDownloadAlternate`. Extend `AdaptiveCalibrationEngine` with an injected asynchronous video capability provider and merge its results into `capabilities`. At `AutomationAppModel.live()` startup, migrate legacy transfer records, install the transfer event relay, resume the transfer coordinator, then resume the evidence inbox. Map sanitized transfer state changes into the existing `message`, `stages`, and stage journal without writing every idle poll.

- [ ] **Step 4: Run focused tests**

```bash
swift test --filter VideoTransferCapabilityProbeTests
swift test --filter AutoconfigurationStoreTests
swift test --filter CompatibilityFixtureReplayTests
swift test --filter AutomationAppModelTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoReplyApp/AutomationAppModel.swift \
        Sources/AutoReplyApp/Autoconfiguration/VideoTransferCapabilityProbe.swift \
        Sources/AutoReplyApp/Autoconfiguration/AutoconfigurationModels.swift \
        Sources/AutoReplyApp/Autoconfiguration/AdaptiveCalibrationEngine.swift \
        Tests/AutoReplyAppTests/VideoTransferCapabilityProbeTests.swift \
        Tests/AutoReplyAppTests/AutoconfigurationStoreTests.swift \
        Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift \
        Tests/AutoReplyAppTests/AutomationAppModelTests.swift
git commit -m "feat: resume and report resilient video transfers"
```

---

### Task 8: Full Regression, Fault Injection, Migration, and Local Live Acceptance

**Files:**
- Create: `docs/operations/resilient-video-download-runbook.md`
- Create: `components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoTransferFaultInjectionTests.swift`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: repeatable fault-injection commands and sanitized acceptance evidence.

- [ ] **Step 1: Add a deterministic fault-injection harness**

The harness must inject transport behavior through protocols, not alter `/etc/hosts`, DNS settings, or the installed app. Define private test-only `VideoTransferScenario`, `ManualClock`, scripted downloader, scripted route provider, event recorder, and valid/corrupt MP4 fixtures inside `VideoTransferFaultInjectionTests.swift`. Cover system timeout → alternate success, total immediate failure → fallback, delayed success, process relaunch, corrupt MP4, and two simultaneous videos.

```swift
let scenario = VideoTransferScenario(
    system: [.failure(.connectTimeout)],
    alternate: [.failure(.connectTimeout), .success(validFixture)],
    clock: ManualClock(start: fixtureDate)
)
XCTAssertEqual(await scenario.run().downloadedCount, 1)
XCTAssertEqual(await scenario.run().duplicateAdmissions, 0)
```

- [ ] **Step 2: Run every automated suite**

```bash
swift test --package-path components/ocr-source
swift test --package-path Tools/QianniuVideoDirectProbe
swift test --package-path components/batch-source
swift test --package-path components/sender-source
swift test --package-path components/unread-source
swift test
```

Expected: zero failures; existing documented skips only.

- [ ] **Step 3: Run leak, build, and signature checks**

```bash
rg -n "auth_key=|msg2\.cloudvideocdn.*\.mp4\?" \
  "$HOME/Library/Application Support/QianniuAutoReplyTaskIsolationCandidate/AI客服记录-任务隔离候选版/运行状态" \
  output-video-analysis || true
swift build -c release
codesign --verify --deep --strict /Applications/千牛全自动客服-通用自适应版.app
```

Expected: no signed URL leakage; release build and signature verification succeed.

- [ ] **Step 4: Back up, install, and run local test-account acceptance**

Before replacing the bundle, copy it to a timestamped rollback directory. Preserve the runtime root. Start with automatic sending stopped, confirm OCR/V2/Codex readiness and migrated video state, then use the authorized test buyer account for:

1. one normal video;
2. one injected first-route failure followed by alternate success;
3. one total immediate failure producing one fallback;
4. one later successful recovery producing one evidence answer;
5. text sent during a waiting video retry.

Record MP4 existence, inspection metadata, evidence manifest, scheduler revision, CLI trace, send-attempt result, and absence of duplicate opens/replies.

- [ ] **Step 5: Write the operations runbook and commit**

Document state meanings, retry schedule, log locations, diagnostic export, how to disable alternate routing, how Codex on a colleague machine distinguishes external CDN failure from application failure, and exact rollback steps.

```bash
git add docs/operations/resilient-video-download-runbook.md \
        components/ocr-source/Tests/QianniuOCRAppSupportTests/VideoTransferFaultInjectionTests.swift
git commit -m "test: verify resilient video download recovery"
```

---

### Task 9: Colleague A/B Acceptance and Universal Release Package

**Files:**
- Modify: `docs/把这个文件交给Codex-项目完整接管与Debug手册.md`.
- Create: timestamped DMG and complete development ZIP under the established Desktop release directory.

**Interfaces:**
- Consumes: verified release build and runbook.
- Produces: one universal signed application payload, DMG, source/debug ZIP, checksums, and A/B sanitized reports.

- [ ] **Step 1: Build one universal candidate; do not fork A/B variants**

Use the existing `scripts/build-distribution-dmg.sh` and `scripts/build-developer-handoff.sh` paths. The first script builds the signed payload and installer before creating the DMG; the second copies the DMG, source tree, Git bundle, handoff guide, and checksums into the development ZIP.

The package must contain the same executable and source commit for local, colleague A, and colleague B machines.

Before packaging, update `docs/把这个文件交给Codex-项目完整接管与Debug手册.md` with the durable state-file locations, sanitized failure categories, 60/180/600-second retry policy, capability-profile keys, no-raw-URL rule, fault-injection commands, diagnostic export steps, and exact rollback procedure. Commit that guide so the ZIP contains the instructions matching its executable.

- [ ] **Step 2: Run colleague B acceptance**

Use the one-click installer, grant required macOS permissions manually, allow automatic calibration, then send at least 20 videos plus text-during-retry cases. Export only sanitized compatibility, transfer, evidence, scheduler, and delivery summaries.

Expected: zero silent losses, duplicate opens, duplicate fallback acknowledgements, duplicate AI admissions, or queue stalls.

- [ ] **Step 3: Run colleague A acceptance**

Repeat the exact colleague B protocol without source or parameter edits. A machine-specific compatibility profile may differ; the app binary and committed source may not.

- [ ] **Step 4: Produce final artifacts and checksums**

Create these names, where `release_stamp` is assigned once by `date '+%Y%m%d-%H%M%S'`:

```text
千牛全自动客服-视频下载可靠性V2.dmg
千牛全自动客服-视频下载可靠性V2-完整开发交付包-$release_stamp.zip
千牛全自动客服-视频下载可靠性V2.sha256.txt
```

Include the runbook, architecture/debug handoff, exact source commit, migration notes, and rollback bundle reference. Exclude customer histories, credentials, raw signed URLs, `.git` worktrees, and build caches.

- [ ] **Step 5: Final verification and release commit**

```bash
release_stamp=$(date '+%Y%m%d-%H%M%S')
release_dir="/Users/scy/Desktop/千牛视频下载可靠性V2-$release_stamp"
mkdir -p "$release_dir"
AUTOREPLY_OUTPUT_DIR="$release_dir" scripts/build-distribution-dmg.sh
built_dmg="$release_dir/千牛全自动客服-通用自适应版.dmg"
dmg_path="$release_dir/千牛全自动客服-视频下载可靠性V2.dmg"
mv "$built_dmg" "$dmg_path"
scripts/build-developer-handoff.sh --dmg "$dmg_path" --output "$release_dir"
handoff_zip=$(find "$release_dir" -maxdepth 1 -name '千牛全自动客服-通用自适应版-完整开发交付包-*.zip' -print -quit)
zip_path="$release_dir/千牛全自动客服-视频下载可靠性V2-完整开发交付包-$release_stamp.zip"
mv "$handoff_zip" "$zip_path"
checksum_path="$release_dir/千牛全自动客服-视频下载可靠性V2.sha256.txt"
shasum -a 256 "$dmg_path" "$zip_path" > "$checksum_path"
hdiutil verify "$dmg_path"
unzip -t "$zip_path"
git status --short
git log -10 --oneline
```

Expected: artifact verification succeeds; only explicitly retained diagnostic/build output directories remain untracked; release commit identifies the exact tested source.

Commit the updated handoff guide before recording the final source commit:

```bash
git add docs/把这个文件交给Codex-项目完整接管与Debug手册.md
git commit -m "docs: hand off resilient video download operations"
```
