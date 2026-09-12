import CoreGraphics
import Foundation

public struct SenderAXNode: Equatable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let role: String
    public let title: String?
    public let description: String?
    public let value: String?
    public let frame: CGRect
    public let isEnabled: Bool

    public init(
        id: Int,
        parentID: Int?,
        role: String,
        title: String?,
        description: String?,
        value: String?,
        frame: CGRect,
        isEnabled: Bool
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.title = title
        self.description = description
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
    }

    public var labels: [String] {
        [title, description, value]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
