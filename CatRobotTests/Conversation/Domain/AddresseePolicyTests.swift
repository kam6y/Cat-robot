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

    /// 初期値は名前の読み「キャロット」。音声認識は同じ名前を CaRot・Carrot・キャロット とも書き、
    /// 平仮名の「きゃろっと」はトークナイザが細かく区切る。どの書き方で保存しても、どの書き方で聞こえても一致する。
    func testTheNameMatchesEveryWaySpeechRecognitionWritesIt() {
        XCTAssertEqual(AddresseePolicy.defaultWakePhrase, "キャロット")
        for spelling in ["キャロット", "きゃろっと", "ｷｬﾛｯﾄ", "CaRot", "CAROT", "Carrot", "carrot"] {
            XCTAssertEqual(policy.route(spelling + "。", at: 0, engagement: .inactive, wakePhrase: "キャロット"), .wakeOnly, spelling)
            XCTAssertEqual(policy.route("キャロット", at: 0, engagement: .inactive, wakePhrase: spelling), .wakeOnly, spelling)
        }
        for addressed in ["ねえCaRot、明日は雨？", "明日の天気は？ キャロット", "Carrot元気？", "きゃろっと、おはよう"] {
            XCTAssertEqual(policy.route(addressed, at: 0, engagement: .inactive, wakePhrase: "キャロット"), .accept(addressed))
        }
        for other in ["キャロに会った", "carrots are orange", "人参が好き", "Ca Rot"] {
            XCTAssertEqual(policy.route(other, at: 0, engagement: .inactive, wakePhrase: "キャロット"), .ignore)
        }
    }

    func testTheSelectedPhraseMayBeChangedAndSurvivesRelaunch() {
        let suite = "wake-phrase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SpeechVoiceSettings(defaults: defaults)
        XCTAssertEqual(settings.wakePhrase, "キャロット")
        XCTAssertTrue(settings.saveWakePhrase("  ミケ！  "))
        XCTAssertFalse(settings.saveWakePhrase(" 、？ "))
        let saved = SpeechVoiceSettings(defaults: defaults).wakePhrase
        XCTAssertEqual(saved, "ミケ")
        XCTAssertEqual(policy.route("みけ、お願い", at: 0, engagement: .inactive, wakePhrase: saved), .accept("みけ、お願い"))
        XCTAssertEqual(policy.route("キャロット、お願い", at: 0, engagement: .inactive, wakePhrase: saved), .ignore)
        defaults.set("！？", forKey: "conversation.wakePhrase")
        XCTAssertEqual(SpeechVoiceSettings(defaults: defaults).wakePhrase, "キャロット")
    }

    /// 改名の前の版が保存した言葉（key は speech.wakePhrase）は読まない。キャロットから始め、保存し直した言葉を使う。
    func testAPhraseSavedByAnEarlierBuildIsNotUsed() {
        let suite = "wake-phrase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("猫ちゃん", forKey: "speech.wakePhrase")
        let settings = SpeechVoiceSettings(defaults: defaults)
        XCTAssertEqual(settings.wakePhrase, "キャロット")
        XCTAssertEqual(policy.route("猫ちゃん、お願い", at: 0, engagement: .inactive, wakePhrase: settings.wakePhrase), .ignore)
        XCTAssertTrue(settings.saveWakePhrase("ミケ"))
        XCTAssertEqual(SpeechVoiceSettings(defaults: defaults).wakePhrase, "ミケ")
        XCTAssertEqual(defaults.string(forKey: "speech.wakePhrase"), "猫ちゃん", "the earlier value is neither read nor rewritten")
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
