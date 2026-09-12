import XCTest
@testable import AutoReplyApp

@MainActor
final class FirstRunCoordinatorTests: XCTestCase {
    func testMissingPermissionWaitsWithoutContinuingToQianniu() async {
        let checks = FakeFirstRunChecks(
            permission: PermissionState(accessibility: false, screenCapture: true),
            qianniuReady: true,
            codexReady: true
        )
        let coordinator = FirstRunCoordinator(
            checks: checks,
            calibration: FakeCalibrationProvider(),
            prewarmer: FakeReadinessPrewarmer()
        )

        await coordinator.advance(
            operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
        )

        XCTAssertEqual(coordinator.phase, .permissionsPending)
        XCTAssertEqual(coordinator.blockingReason, "请开启辅助功能")
        XCTAssertFalse(coordinator.shouldAutoStart)
        let permissionChecks = await checks.permissionCheckCount()
        let qianniuChecks = await checks.qianniuCheckCount()
        XCTAssertEqual(permissionChecks, 1)
        XCTAssertEqual(qianniuChecks, 0)
    }

    func testReadyChainMergesCapabilitiesAndRequestsOneAutomaticStart() async {
        let calibrationCapability = CapabilityStatus(
            level: .verified, strategy: "legacy-static-rules", detail: "只读核对通过"
        )
        let prewarmCapability = CapabilityStatus(
            level: .verified, strategy: "persistent-top12", detail: "知识库已就绪"
        )
        let coordinator = FirstRunCoordinator(
            checks: FakeFirstRunChecks(
                permission: PermissionState(accessibility: true, screenCapture: true),
                qianniuReady: true,
                codexReady: true
            ),
            calibration: FakeCalibrationProvider(result: MachineCompatibilityProfile(
                schemaVersion: 1,
                profileID: UUID(),
                fingerprintDigest: "fixture",
                capabilities: ["receptionWindow": calibrationCapability],
                readOnlyPassedAt: nil,
                endToEndPassedAt: nil
            )),
            prewarmer: FakeReadinessPrewarmer(result: ["v2": prewarmCapability])
        )

        await coordinator.advance(
            operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
        )

        XCTAssertEqual(coordinator.phase, .readOnlyReady)
        XCTAssertNil(coordinator.blockingReason)
        XCTAssertTrue(coordinator.shouldAutoStart)
        XCTAssertEqual(coordinator.capabilities["receptionWindow"], calibrationCapability)
        XCTAssertEqual(coordinator.capabilities["v2"], prewarmCapability)
        XCTAssertNotNil(coordinator.profile?.readOnlyPassedAt)
    }

    func testMissingOperatorAliasStopsBeforeCodexCheck() async {
        let checks = FakeFirstRunChecks(
            permission: PermissionState(accessibility: true, screenCapture: true),
            qianniuReady: true,
            codexReady: true
        )
        let coordinator = FirstRunCoordinator(
            checks: checks,
            calibration: FakeCalibrationProvider(),
            prewarmer: FakeReadinessPrewarmer()
        )

        await coordinator.advance(
            operatorConfig: OperatorConfig(serviceAliases: [], autoStartWhenReady: true)
        )

        XCTAssertEqual(coordinator.phase, .operatorPending)
        let codexChecks = await checks.codexCheckCount()
        XCTAssertEqual(codexChecks, 0)
    }

    func testFreshInstallReadinessContract() async throws {
        let coordinator = FirstRunCoordinator(
            checks: FakeFirstRunChecks(
                permission: PermissionState(accessibility: true, screenCapture: true),
                qianniuReady: true,
                codexReady: true
            ),
            calibration: FakeCalibrationProvider(),
            prewarmer: FakeReadinessPrewarmer(result: [
                "ocr": CapabilityStatus(level: .verified, strategy: "warm", detail: "ready"),
                "v2": CapabilityStatus(level: .verified, strategy: "persistent", detail: "ready")
            ])
        )

        await coordinator.advance(
            operatorConfig: OperatorConfig(serviceAliases: ["fixture-agent"], autoStartWhenReady: false)
        )

        let readiness = coordinator.readinessStateExport()
        XCTAssertEqual(readiness.phase, .readOnlyReady)
        XCTAssertTrue(readiness.ocrPrepared)
        XCTAssertTrue(readiness.v2Prepared)
        XCTAssertTrue(readiness.profileCreated)
        XCTAssertFalse(readiness.endToEndVerified)
        let data = try JSONEncoder().encode(readiness)
        print("FRESH_READINESS_JSON=\(String(decoding: data, as: UTF8.self))")
    }

    func testAmbiguousSendControlsStillPrewarmAndReachReadOnlyReady() async throws {
        let profile = try AdaptiveCalibrationEngine.calibrate(
            snapshot: .colleagueB40Controls(exactSendLabel: false)
        )
        let prewarmer = CountingReadinessPrewarmer(result: [
            "ocr": CapabilityStatus(level: .verified, strategy: "warm", detail: "ready"),
            "v2": CapabilityStatus(level: .verified, strategy: "persistent", detail: "ready")
        ])
        let coordinator = FirstRunCoordinator(
            checks: FakeFirstRunChecks(
                permission: PermissionState(accessibility: true, screenCapture: true),
                qianniuReady: true,
                codexReady: true
            ),
            calibration: FakeCalibrationProvider(result: profile),
            prewarmer: prewarmer
        )

        await coordinator.advance(
            operatorConfig: OperatorConfig(serviceAliases: ["小甘"], autoStartWhenReady: true)
        )

        let callCount = await prewarmer.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(coordinator.phase, .readOnlyReady)
        XCTAssertEqual(coordinator.profile?.sendPolicy, .returnKeyOnce)
        XCTAssertEqual(coordinator.profile?.calibrationDiagnostics?.count, 1)
        XCTAssertTrue(coordinator.shouldAutoStart)
    }
}

private actor FakeFirstRunChecks: FirstRunChecking {
    private let permission: PermissionState
    private let qianniuReady: Bool
    private let codexReady: Bool
    private var permissionChecks = 0
    private var qianniuChecks = 0
    private var codexChecks = 0

    init(permission: PermissionState, qianniuReady: Bool, codexReady: Bool) {
        self.permission = permission
        self.qianniuReady = qianniuReady
        self.codexReady = codexReady
    }

    func permissionState() async -> PermissionState {
        permissionChecks += 1
        return permission
    }

    func qianniuReceptionReady() async -> Bool {
        qianniuChecks += 1
        return qianniuReady
    }

    func codexLoggedIn() async -> Bool {
        codexChecks += 1
        return codexReady
    }

    func permissionCheckCount() -> Int { permissionChecks }
    func qianniuCheckCount() -> Int { qianniuChecks }
    func codexCheckCount() -> Int { codexChecks }
}

private struct FakeCalibrationProvider: CalibrationProviding {
    let result: MachineCompatibilityProfile

    init(result: MachineCompatibilityProfile = .empty) {
        self.result = result
    }

    func calibrate() async throws -> MachineCompatibilityProfile { result }
}

private struct FakeReadinessPrewarmer: ReadinessPrewarming {
    let result: [String: CapabilityStatus]

    init(result: [String: CapabilityStatus] = [:]) {
        self.result = result
    }

    func prepare() async throws -> [String: CapabilityStatus] { result }
}

private actor CountingReadinessPrewarmer: ReadinessPrewarming {
    let result: [String: CapabilityStatus]
    private var calls = 0

    init(result: [String: CapabilityStatus]) {
        self.result = result
    }

    func prepare() async throws -> [String: CapabilityStatus] {
        calls += 1
        return result
    }

    func callCount() -> Int { calls }
}
