import Foundation

@MainActor
public protocol OCRPrewarming: AnyObject, Sendable {
    func prepareOCR() async throws
}
