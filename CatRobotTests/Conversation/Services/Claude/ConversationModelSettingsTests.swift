import XCTest
@testable import CatRobot

@MainActor
final class ConversationModelSettingsTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "ConversationModelSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultsAreOpusLowAnd300() {
        let settings = ConversationModelSettings(defaults: suite())
        XCTAssertEqual(
            settings.configuration,
            ConversationModelConfiguration(model: .opus5_5, effort: .low, dailyTurnLimit: 300)
        )
    }

    func testSelectionsPersistAndInvalidValuesFallBack() {
        let defaults = suite()
        let first = ConversationModelSettings(defaults: defaults)
        first.model = .sonnet5_5
        first.effort = .medium
        first.dailyTurnLimit = 50

        let second = ConversationModelSettings(defaults: defaults)
        XCTAssertEqual(
            second.configuration,
            ConversationModelConfiguration(model: .sonnet5_5, effort: .medium, dailyTurnLimit: 50)
        )

        defaults.set("unknown-model", forKey: "conversation.claude.model")
        defaults.set("unknown-effort", forKey: "conversation.claude.effort")
        defaults.set(-3, forKey: "conversation.claude.dailyTurnLimit")
        let third = ConversationModelSettings(defaults: defaults)
        XCTAssertEqual(third.model, .opus5_5)
        XCTAssertEqual(third.effort, .low)
        XCTAssertEqual(third.dailyTurnLimit, 300)

        defaults.set(0, forKey: "conversation.claude.dailyTurnLimit")
        XCTAssertEqual(ConversationModelSettings(defaults: defaults).dailyTurnLimit, 300)
    }

    func testRawValuesAreAPIModelIDs() {
        XCTAssertEqual(
            ConversationModelChoice.allCases.map(\.rawValue),
            ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        )
    }
}
