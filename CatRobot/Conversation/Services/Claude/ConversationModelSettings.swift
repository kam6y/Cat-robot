import Foundation
import Observation

enum ConversationModelChoice: String, CaseIterable, Codable, Sendable {
    case opus5_5 = "claude-opus-5-5"
    case sonnet5_5 = "claude-sonnet-5-5"
    case haiku5_5 = "claude-haiku-5-5"

    var displayName: String {
        switch self {
        case .opus5_5: "Claude Opus 5.5（既定）"
        case .sonnet5_5: "Claude Sonnet 5.5"
        case .haiku5_5: "Claude Haiku 5.5"
        }
    }
}

enum ConversationEffort: String, CaseIterable, Codable, Sendable {
    case low, medium

    var displayName: String { self == .low ? "速さ優先（既定）" : "少し考える" }
}

struct ConversationModelConfiguration: Equatable, Sendable {
    var model: ConversationModelChoice = .opus5_5
    var effort: ConversationEffort = .low
    var dailyTurnLimit: Int = 300
}

@MainActor @Observable
final class ConversationModelSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let modelKey = "conversation.claude.model"
    private static let effortKey = "conversation.claude.effort"
    private static let limitKey = "conversation.claude.dailyTurnLimit"

    var model: ConversationModelChoice {
        didSet { defaults.set(model.rawValue, forKey: Self.modelKey) }
    }
    var effort: ConversationEffort {
        didSet { defaults.set(effort.rawValue, forKey: Self.effortKey) }
    }
    var dailyTurnLimit: Int {
        didSet { defaults.set(dailyTurnLimit, forKey: Self.limitKey) }
    }

    var configuration: ConversationModelConfiguration {
        ConversationModelConfiguration(model: model, effort: effort, dailyTurnLimit: dailyTurnLimit)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: Self.modelKey).flatMap(ConversationModelChoice.init(rawValue:)) ?? .opus5_5
        effort = defaults.string(forKey: Self.effortKey).flatMap(ConversationEffort.init(rawValue:)) ?? .low
        let stored = defaults.integer(forKey: Self.limitKey)
        dailyTurnLimit = stored > 0 ? stored : 300
    }
}
