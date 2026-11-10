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

    func testDefaultsAreOpusLow() {
        let settings = ConversationModelSettings(defaults: suite())
        XCTAssertEqual(
            settings.configuration,
            ConversationModelConfiguration(model: .opus5_5, effort: .low)
        )
    }

    func testRetiredDailyLimitKeyNoLongerShapesTheConfiguration() {
        // 日次上限は 2026-11-10 に撤去した。旧 key に値が残っていても設定はモデルとエフォートだけになる。
        let defaults = suite()
        defaults.set(1, forKey: "conversation.claude.dailyTurnLimit")
        let settings = ConversationModelSettings(defaults: defaults)
        XCTAssertEqual(settings.configuration, ConversationModelConfiguration(model: .opus5_5, effort: .low))
        settings.model = .haiku5_5
        XCTAssertEqual(ConversationModelSettings(defaults: defaults).configuration,
                       ConversationModelConfiguration(model: .haiku5_5, effort: .low))
    }

    func testEveryEffortOptionPersistsUsingItsAPIName() {
        XCTAssertEqual(ConversationEffort.allCases.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        let defaults = suite()

        for effort in ConversationEffort.allCases {
            let settings = ConversationModelSettings(defaults: defaults)
            settings.effort = effort

            XCTAssertEqual(defaults.string(forKey: "conversation.claude.effort"), effort.rawValue)
            XCTAssertEqual(ConversationModelSettings(defaults: defaults).configuration.effort, effort)
        }
    }

    func testSelectionsPersistAndInvalidValuesFallBack() {
        let defaults = suite()
        let first = ConversationModelSettings(defaults: defaults)
        first.model = .sonnet5_5
        first.effort = .medium

        let second = ConversationModelSettings(defaults: defaults)
        XCTAssertEqual(
            second.configuration,
            ConversationModelConfiguration(model: .sonnet5_5, effort: .medium)
        )

        defaults.set("unknown-model", forKey: "conversation.claude.model")
        defaults.set("unknown-effort", forKey: "conversation.claude.effort")
        let third = ConversationModelSettings(defaults: defaults)
        XCTAssertEqual(third.model, .opus5_5)
        XCTAssertEqual(third.effort, .low)

    }

    func testRawValuesAreAPIModelIDs() {
        XCTAssertEqual(
            ConversationModelChoice.allCases.map(\.rawValue),
            ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        )
    }
}
