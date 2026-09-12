import Foundation
import QianniuSenderAppSupport

protocol LegacyCapabilityProbing: Sendable {
    func receptionWindowAvailable() async -> Bool
    func conversationListAvailable() async -> Bool
    func composerAvailable() async -> Bool
}

struct LegacyCalibrationProvider: CalibrationProviding {
    let probe: any LegacyCapabilityProbing

    func calibrate() async throws -> MachineCompatibilityProfile {
        async let reception = probe.receptionWindowAvailable()
        async let conversationList = probe.conversationListAvailable()
        async let composer = probe.composerAvailable()

        let capabilities = [
            "receptionWindow": status(available: await reception, name: "接待中心窗口"),
            "conversationList": status(available: await conversationList, name: "客户列表"),
            "composer": status(available: await composer, name: "输入框与发送控件")
        ]
        let fingerprint = capabilities.keys.sorted().map { key in
            "\(key)=\(capabilities[key]!.level.rawValue)"
        }.joined(separator: ";")
        return MachineCompatibilityProfile(
            schemaVersion: 2,
            profileID: UUID(),
            fingerprintDigest: fingerprint,
            capabilities: capabilities,
            readOnlyPassedAt: nil,
            endToEndPassedAt: nil
        )
    }

    private func status(available: Bool, name: String) -> CapabilityStatus {
        CapabilityStatus(
            level: available ? .verified : .unavailable,
            strategy: "legacy-static-rules",
            detail: available ? "\(name)只读核对通过" : "\(name)当前不可用"
        )
    }
}

@MainActor
final class LiveLegacyCapabilityProbe: LegacyCapabilityProbing {
    private let native: NativeSession
    private let sender: QianniuAXSession

    init() {
        native = NativeSession()
        sender = QianniuAXSession()
    }

    init(native: NativeSession, sender: QianniuAXSession) {
        self.native = native
        self.sender = sender
    }

    func receptionWindowAvailable() async -> Bool {
        do {
            try native.check()
            return true
        } catch {
            return false
        }
    }

    func conversationListAvailable() async -> Bool {
        do {
            try native.check()
            _ = try native.snapshot()
            return true
        } catch {
            return false
        }
    }

    func composerAvailable() async -> Bool {
        (try? await sender.composerAvailableReadOnly()) == true
    }
}
