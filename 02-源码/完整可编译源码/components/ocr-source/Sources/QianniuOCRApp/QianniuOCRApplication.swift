import SwiftUI
import QianniuOCRAppSupport

@main
struct QianniuOCRApplication: App {
    @StateObject private var model = AppModel.live(runner: LiveOCRRunner())

    var body: some Scene {
        WindowGroup("千牛主聊天区 OCR · Plan B") {
            ContentView(model: model)
        }
        .defaultSize(width: 860, height: 650)
    }
}
