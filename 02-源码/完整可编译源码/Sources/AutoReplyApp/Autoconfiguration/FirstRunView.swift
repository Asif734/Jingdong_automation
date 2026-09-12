import AppKit
import SwiftUI

enum SystemSettingsPane: Equatable, Sendable {
    case accessibility
    case screenRecording
}

@MainActor
protocol SystemSettingsOpening: AnyObject {
    func open(_ pane: SystemSettingsPane)
}

@MainActor
final class LiveSystemSettingsOpener: SystemSettingsOpening {
    func open(_ pane: SystemSettingsPane) {
        AutomationPermissions.openSettings(accessibility: pane == .accessibility)
    }
}

@MainActor
final class FirstRunViewModel: ObservableObject {
    @Published private(set) var loginStatusText = ""
    @Published private(set) var loginInProgress = false
    @Published var includeRawDiagnosticEvidence = false
    private(set) var startRequested = false

    private let settings: any SystemSettingsOpening
    private let deviceLogin: @Sendable () async throws -> Void

    convenience init() {
        self.init(settings: LiveSystemSettingsOpener())
    }

    init(
        settings: any SystemSettingsOpening,
        deviceLogin: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.settings = settings
        self.deviceLogin = deviceLogin
    }

    func openAccessibilitySettings() { settings.open(.accessibility) }
    func openScreenRecordingSettings() { settings.open(.screenRecording) }

    static func capabilitySummary(key: String, status: CapabilityStatus) -> String {
        let suffix = status.level == .fallback ? "；可继续运行" : ""
        return "\(key) · \(status.strategy) · \(status.detail)\(suffix)"
    }

    func beginDeviceLogin() {
        guard !loginInProgress else { return }
        loginInProgress = true
        loginStatusText = "正在等待 Codex 设备登录…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await deviceLogin()
                loginStatusText = "Codex 登录完成，正在继续自检"
            } catch {
                loginStatusText = "Codex 登录未完成：\(error.localizedDescription)"
            }
            loginInProgress = false
        }
    }
}

@MainActor
final class LiveFirstRunChecks: FirstRunChecking {
    private let native = NativeSession()
    private let codex: CodexLoginCoordinator

    init(codex: CodexLoginCoordinator) { self.codex = codex }

    func permissionState() async -> PermissionState {
        PermissionState(
            accessibility: AutomationPermissions.accessibility,
            screenCapture: AutomationPermissions.screenCapture
        )
    }

    func qianniuReceptionReady() async -> Bool {
        do {
            try native.check()
            _ = try native.snapshot()
            return true
        } catch {
            return false
        }
    }

    func codexLoggedIn() async -> Bool {
        (try? await codex.status()) == .loggedIn
    }
}

struct FirstRunView: View {
    @ObservedObject var model: AutomationAppModel
    @ObservedObject var coordinator: FirstRunCoordinator
    @ObservedObject var viewModel: FirstRunViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("千牛全自动客服 · 首次配置").font(.title2.bold())
            Text("完成一次设置后，本机以后会自动校验、预热并运行。")
                .foregroundStyle(.secondary)

            readinessSteps
            Divider()

            Text(coordinator.blockingReason ?? phaseDescription)
                .font(.headline)
                .foregroundStyle(coordinator.blockingReason == nil ? Color.primary : Color.orange)

            phaseActions

            Toggle(
                "全部就绪后自动开始回复",
                isOn: Binding(
                    get: { model.autoStartWhenReady },
                    set: model.setAutoStartWhenReady
                )
            )

            DisclosureGroup("高级能力详情") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.capabilities.keys.sorted(), id: \.self) { key in
                        if let status = coordinator.capabilities[key] {
                            HStack(alignment: .top) {
                                Image(systemName: status.level == .unavailable
                                      ? "xmark.circle" : "checkmark.circle")
                                    .foregroundStyle(
                                        status.level == .unavailable ? Color.red
                                            : (status.level == .fallback ? Color.orange : Color.green)
                                    )
                                Text(FirstRunViewModel.capabilitySummary(key: key, status: status))
                                    .font(.caption)
                            }
                        }
                    }
                    if coordinator.capabilities.isEmpty {
                        Text("完成只读校准后显示。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("本次导出包含原始证据（可能含客户信息）", isOn: $viewModel.includeRawDiagnosticEvidence)
                        .font(.caption)
                    Button("导出脱敏诊断包") {
                        model.exportDiagnosticBundle(
                            includeRawEvidence: viewModel.includeRawDiagnosticEvidence
                        )
                        viewModel.includeRawDiagnosticEvidence = false
                    }
                    if !model.diagnosticExportStatusText.isEmpty {
                        Text(model.diagnosticExportStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }.padding(.top, 6)
            }

            Spacer()
            Text("权限必须由你在 macOS 系统设置中开启；程序不会读取或复制个人 Codex 配置。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private var readinessSteps: some View {
        let steps: [(ReadinessPhase, String)] = [
            (.permissionsPending, "系统权限"),
            (.qianniuPending, "千牛接待中心"),
            (.operatorPending, "客服名称"),
            (.codexPending, "Codex 登录"),
            (.probing, "环境探测"),
            (.calibrating, "本机校准"),
            (.prewarming, "OCR / V2 / SenseVoice / Codex 预热"),
            (.readOnlyReady, "只读自检完成")
        ]
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                HStack {
                    Image(systemName: stepPassed(item.0) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(stepPassed(item.0) ? .green : .secondary)
                    Text("\(index + 1). \(item.1)")
                }
            }
        }
    }

    @ViewBuilder private var phaseActions: some View {
        switch coordinator.phase {
        case .permissionsPending:
            HStack {
                Button("请求辅助功能权限", action: AutomationPermissions.requestAccessibility)
                Button("打开辅助功能设置", action: viewModel.openAccessibilitySettings)
                Button("请求屏幕录制权限", action: AutomationPermissions.requestScreenCapture)
                Button("打开屏幕录制设置", action: viewModel.openScreenRecordingSettings)
            }
        case .qianniuPending:
            Text("请登录千牛，进入客服接待中心并保持窗口可见。")
        case .operatorPending:
            HStack {
                TextField("例如：小丹；多个名称用逗号分隔", text: Binding(
                    get: { model.serviceAliasesText },
                    set: model.setServiceAliasesText
                ))
                Button("保存并继续", action: model.applyServiceAliases)
            }
        case .codexPending:
            VStack(alignment: .leading) {
                Button("授权本机 Codex 账号", action: viewModel.beginDeviceLogin)
                    .disabled(viewModel.loginInProgress)
                if !viewModel.loginStatusText.isEmpty { Text(viewModel.loginStatusText).font(.caption) }
            }
        case .probing, .calibrating, .prewarming:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var phaseDescription: String {
        switch coordinator.phase {
        case .probing: "正在读取本机环境"
        case .calibrating: "正在校准千牛页面能力"
        case .prewarming: "正在预热 OCR、知识库、SenseVoice 和 Codex"
        case .readOnlyReady: "只读自检已完成"
        case .running: "自动客服正在运行"
        default: "等待下一项设置"
        }
    }

    private func stepPassed(_ step: ReadinessPhase) -> Bool {
        let order: [ReadinessPhase] = [
            .installed, .permissionsPending, .qianniuPending, .operatorPending,
            .codexPending, .probing, .calibrating, .prewarming, .readOnlyReady, .running
        ]
        guard let current = order.firstIndex(of: coordinator.phase),
              let target = order.firstIndex(of: step) else { return false }
        return current > target || coordinator.phase == .running
    }
}
