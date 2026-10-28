import Foundation

/// Completion belongs to this installation; reviewing the explanation never changes it.
@MainActor
final class OnboardingSettings {
    static let completedKey = "onboarding.completed"
    private let defaults: UserDefaults
    private(set) var isCompleted: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompleted = defaults.bool(forKey: Self.completedKey)
    }

    func markCompleted() {
        isCompleted = true
        defaults.set(true, forKey: Self.completedKey)
    }
}
