import Foundation

struct EngagementWindow: Equatable, Sendable {
    static let inactive = Self()
    private static let followUpDuration: TimeInterval = 30
    private var expiresAt: TimeInterval?

    mutating func arm(at timestamp: TimeInterval) {
        expiresAt = timestamp + Self.followUpDuration
    }

    func isActive(at timestamp: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return timestamp < expiresAt
    }

    mutating func clear() {
        expiresAt = nil
    }
}
