import Foundation

public struct AXNodeCandidate: Equatable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let candidate: AXCandidate
    public let isSelected: Bool

    public init(id: Int, parentID: Int?, candidate: AXCandidate, isSelected: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.candidate = candidate
        self.isSelected = isSelected
    }
}
