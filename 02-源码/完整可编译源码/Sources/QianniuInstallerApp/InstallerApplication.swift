import AppKit
import SwiftUI

@main
struct InstallerApplication: App {
    var body: some Scene {
        WindowGroup("千牛全自动客服安装器") {
            InstallerView()
                .frame(width: 520, height: 300)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class InstallerViewModel: ObservableObject {
    @Published var status = "点击一次即可校验、安装并从固定位置启动。"
    @Published var working = false
    @Published var completed = false

    func installAndLaunch() {
        guard !working else { return }
        working = true
        status = "正在校验安装包…"
        Task { @MainActor in
            do {
                guard let resources = Bundle.main.resourceURL else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let payload = resources.appendingPathComponent(InstallationTransaction.appName)
                let manifestURL = resources.appendingPathComponent("distribution-manifest.json")
                let manifest = try JSONDecoder().decode(
                    DistributionManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                let receipt = try InstallationTransaction().install(payload: payload, manifest: manifest)
                status = "安装完成，正在启动…"
                guard NSWorkspace.shared.open(receipt.destinationURL) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                completed = true
                status = "已从 \(receipt.destinationURL.path) 启动。"
            } catch {
                status = "安装失败：\(error.localizedDescription)\n旧版本未被破坏。"
            }
            working = false
        }
    }
}

private struct InstallerView: View {
    @StateObject private var model = InstallerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("千牛全自动客服 · 版本 B").font(.title2.bold())
            Text("适用于 Apple Silicon Mac。安装器会先校验完整文件和签名，再保留旧版并原子替换。")
                .foregroundStyle(.secondary)
            Text(model.status).textSelection(.enabled)
            Spacer()
            Button(model.completed ? "已完成" : "安装并启动") {
                model.installAndLaunch()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.working || model.completed)
            if model.working { ProgressView() }
        }
        .padding(28)
    }
}
