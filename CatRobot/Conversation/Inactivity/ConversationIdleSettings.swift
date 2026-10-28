import Foundation
import Observation

@MainActor @Observable
final class ConversationIdleSettings {
    static let sleepyRange = 1...1439
    static let sleepingRange = 2...1440
    @ObservationIgnored private let defaults: UserDefaults
    private static let sleepyKey = "conversation.sleepyMinutes"
    private static let sleepingKey = "conversation.sleepingMinutes"
    private var storedSleepy: Int
    private var storedSleeping: Int

    var sleepyMinutes: Int {
        get { storedSleepy }
        set {
            storedSleepy = min(Self.sleepyRange.upperBound, max(Self.sleepyRange.lowerBound, newValue))
            storedSleeping = max(storedSleeping, storedSleepy + 1)
            persist()
        }
    }

    var sleepingMinutes: Int {
        get { storedSleeping }
        set {
            storedSleeping = min(Self.sleepingRange.upperBound, max(Self.sleepingRange.lowerBound, newValue))
            storedSleepy = min(storedSleepy, storedSleeping - 1)
            persist()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let sleepy = min(Self.sleepyRange.upperBound, max(Self.sleepyRange.lowerBound,
            (defaults.object(forKey: Self.sleepyKey) as? Int) ?? 5))
        storedSleepy = sleepy
        storedSleeping = min(Self.sleepingRange.upperBound, max(sleepy + 1,
            (defaults.object(forKey: Self.sleepingKey) as? Int) ?? 10))
    }

    private func persist() {
        defaults.set(storedSleepy, forKey: Self.sleepyKey)
        defaults.set(storedSleeping, forKey: Self.sleepingKey)
    }
}
