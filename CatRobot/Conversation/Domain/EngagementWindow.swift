import Foundation

struct EngagementWindow: Equatable, Sendable {
    static let inactive = Self()

    private static let softDuration: TimeInterval = 30
    private static let hardDuration: TimeInterval = 300

    private var armedAt: TimeInterval?
    private var softExpiresAt: TimeInterval?

    mutating func arm(at timestamp: TimeInterval) {
        armedAt = timestamp
        softExpiresAt = timestamp + Self.softDuration
    }

    func isActive(at timestamp: TimeInterval) -> Bool {
        guard let armedAt, let softExpiresAt else { return false }
        return timestamp < softExpiresAt && timestamp < armedAt + Self.hardDuration
    }

    mutating func refresh(afterReplyAt timestamp: TimeInterval) {
        guard armedAt != nil else { return }
        softExpiresAt = timestamp + Self.softDuration
    }

    mutating func clear() {
        armedAt = nil
        softExpiresAt = nil
    }
}
