import Foundation
import CoreGraphics

public struct AXNode: Sendable, Equatable {
    public let id: Int
    public let parent: Int?
    public let role: String
    public let title: String
    public let value: String
    public let description: String
    public let frame: CGRect
    public init(id: Int, parent: Int? = nil, role: String, title: String = "", value: String = "", description: String = "", frame: CGRect) {
        self.id = id; self.parent = parent; self.role = role; self.title = title; self.value = value; self.description = description; self.frame = frame
    }
    public var labels: [String] { [title, value, description].filter { !$0.isEmpty } }
}
public struct ConversationRow: Sendable, Equatable {
    public let nodeID: Int
    public let uid: String
    public let nickname: String?
    public let frame: CGRect
    public let latestPreviewIsImage: Bool
    public init(nodeID: Int, uid: String, nickname: String? = nil, frame: CGRect, latestPreviewIsImage: Bool = false) {
        self.nodeID = nodeID
        self.uid = uid
        self.nickname = nickname
        self.frame = frame
        self.latestPreviewIsImage = latestPreviewIsImage
    }
}
public struct PixelImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }
}
public enum AssistantError: Error, LocalizedError, Equatable {
    case unsafe(String)
    public var errorDescription: String? { if case .unsafe(let text) = self { return text }; return nil }
}
