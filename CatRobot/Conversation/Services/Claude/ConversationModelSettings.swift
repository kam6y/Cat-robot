import Foundation
import Observation

enum ConversationModelChoice: String, CaseIterable, Codable, Sendable {
    case opus5_5 = "claude-opus-5-5"
    case sonnet5_5 = "claude-sonnet-5-5"
    case haiku5_5 = "claude-haiku-5-5"

    var displayName: String {
        switch self {
        case .opus5_5: "Claude Opus 5.5(推奨)"
        case .sonnet5_5: "Claude Sonnet 5.5"
        case .haiku5_5: "Claude Haiku 5.5"
        }
    }
}

enum ConversationEffort: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh

    var displayName: String { self == .low ? "low(推奨)" : rawValue }
}

struct ConversationModelConfiguration: Equatable, Sendable {
    var model: ConversationModelChoice = .opus5_5
    var effort: ConversationEffort = .low
}

@MainActor @Observable
final class ConversationModelSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let modelKey = "conversation.claude.model"
    private static let effortKey = "conversation.claude.effort"

    var model: ConversationModelChoice {
        didSet { defaults.set(model.rawValue, forKey: Self.modelKey) }
    }
    var effort: ConversationEffort {
        didSet { defaults.set(effort.rawValue, forKey: Self.effortKey) }
    }

    var configuration: ConversationModelConfiguration {
        ConversationModelConfiguration(model: model, effort: effort)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = ConversationModelConfiguration()
        model = defaults.string(forKey: Self.modelKey).flatMap(ConversationModelChoice.init(rawValue:)) ?? fallback.model
        effort = defaults.string(forKey: Self.effortKey).flatMap(ConversationEffort.init(rawValue:)) ?? fallback.effort
    }
}
