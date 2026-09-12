import CoreGraphics
import Foundation

struct CalibrationAXNode: Codable, Equatable, Sendable {
    let id: Int
    let parentID: Int?
    let role: String
    let actionNames: [String]
    let labelCategory: String
    let relativeFrame: CGRect
    let hasValue: Bool
}

struct CalibrationWindow: Codable, Equatable, Sendable {
    let roleCategory: String
    let relativeFrame: CGRect
    let captureFrame: CGRect
    let minimized: Bool
    let focused: Bool
    let regionCategories: Set<String>
}

struct CalibrationDisplay: Codable, Equatable, Sendable {
    let relativeFrame: CGRect
    let scale: Double
}

struct CalibrationSnapshot: Codable, Equatable, Sendable {
    let macOSBuild: String
    let architecture: String
    let qianniuVersion: String
    let qianniuBuild: String
    let qianniuRuntimeArchitecture: String
    let displays: [CalibrationDisplay]
    let windows: [CalibrationWindow]
    let nodes: [CalibrationAXNode]
}

enum CalibrationLabelCategory {
    static func classify(rawLabel: String?, role: String, actions: [String]) -> String {
        let value = (rawLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if role == "AXTextArea" || role == "AXTextField" { return "input-control" }
        if value.isEmpty { return "blank" }
        if value.contains("正在接待") { return "正在接待买家列表" }
        if value.contains("消息记录") || value.contains("聊天记录区域") { return "chat-region" }
        if value.contains("接待") { return "reception-title" }
        if value == "[图片]" { return "image-marker" }
        if value == "发送" { return "send-control" }
        if role.contains("Button") && actions.contains("AXPress") { return "press-control" }
        if value.contains("联系人") || value.contains("聊天记录") { return "list-anchor" }
        return "identity-like"
    }
}
