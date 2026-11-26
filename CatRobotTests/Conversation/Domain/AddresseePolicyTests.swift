import XCTest
@testable import CatRobot

@MainActor
final class AddresseePolicyTests: XCTestCase {
    private let policy = AddresseePolicy()

    func testConfiguredPhraseMatchesAtAnyWordBoundaryByReading() {
        for name in ["猫ちゃん", "ねこちゃん", "ネコチャン"] {
            XCTAssertEqual(policy.route("ねこちゃん。", at: 0, engagement: .inactive, wakePhrase: name), .wakeOnly)
            XCTAssertEqual(policy.route("猫ちゃん明日は雨？", at: 0, engagement: .inactive, wakePhrase: name), .accept("猫ちゃん明日は雨？"))
            for addressed in ["ねえ猫ちゃん、元気？", "明日の天気は？ ねこちゃん"] {
                XCTAssertEqual(policy.route(addressed, at: 0, engagement: .inactive, wakePhrase: name), .accept(addressed))
            }
            for other in ["今日は猫ちゃんねるの日", "猫ちゃんねる", "明日は雨？"] {
                XCTAssertEqual(policy.route(other, at: 0, engagement: .inactive, wakePhrase: name), .ignore)
            }
        }
        XCTAssertEqual(policy.route("ＨＥＹ　ＭＩＫＥ！", at: 0, engagement: .inactive, wakePhrase: "hey mike"), .wakeOnly)
    }

    func testTheSelectedPhraseMayBeChangedAndSurvivesRelaunch() {
        let suite = "wake-phrase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SpeechVoiceSettings(defaults: defaults)
        XCTAssertEqual(settings.wakePhrase, "猫ちゃん")
        XCTAssertTrue(settings.saveWakePhrase("  ミケ！  "))
        XCTAssertFalse(settings.saveWakePhrase(" 、？ "))
        let saved = SpeechVoiceSettings(defaults: defaults).wakePhrase
        XCTAssertEqual(saved, "ミケ")
        XCTAssertEqual(policy.route("みけ、お願い", at: 0, engagement: .inactive, wakePhrase: saved), .accept("みけ、お願い"))
        XCTAssertEqual(policy.route("猫ちゃん、お願い", at: 0, engagement: .inactive, wakePhrase: saved), .ignore)
        defaults.set("！？", forKey: "speech.wakePhrase")
        XCTAssertEqual(SpeechVoiceSettings(defaults: defaults).wakePhrase, "猫ちゃん")
    }

    func testFaceOrActiveWindowAllowsOrdinarySpeechWhileFillerIsIgnored() {
        var window = EngagementWindow()
        window.arm(at: 0)
        func route(_ text: String, _ time: TimeInterval, facing: Bool = false) -> AddresseeRoute {
            policy.route(text, at: time, engagement: window, wakePhrase: "ロボット", isFacingScreen: facing)
        }
        XCTAssertEqual(route("続けて", 29), .accept("続けて"))
        XCTAssertEqual(route("続けて", 30), .ignore)
        XCTAssertEqual(route(" 教えて ", 30, facing: true), .accept("教えて"))
        for filler in ["……", "えっと", "  "] { XCTAssertEqual(route(filler, 2, facing: true), .ignore) }
        window.arm(at: 295)
        XCTAssertEqual(route("続けて", 324), .accept("続けて"))
        XCTAssertEqual(route("続けて", 325), .ignore)
    }
}
