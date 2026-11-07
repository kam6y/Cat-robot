import XCTest
@testable import CatRobot

final class AddresseePolicyTests: XCTestCase {
    func testNamesAloneDoNotBypassClassifier() {
        for utterance in ["ねこ、天気は？", "猫ちゃん", "Cat Robot: hello", "キャットロボット今日どう？"] {
            XCTAssertEqual(AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
                           .classify(utterance))
        }
    }

    func testEngagedTurnSkipsClassifierButHardExpiryDoesNotExtend() {
        var engagement = EngagementWindow()
        engagement.arm(at: 0)
        engagement.refresh(afterReplyAt: 290)
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 299, engagement: engagement, pending: nil), .accept("続けて"))
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 300, engagement: engagement, pending: nil), .classify("続けて"))
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 301, engagement: engagement, pending: nil), .classify("続けて"))
    }

    func testPendingSpeechUsesActualWordsWithoutYesNoRewrite() {
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)
        // 短い肯定・否定も言い方の違う返事も、元の発言へ置き換えず、文脈つきの宛先判定へ渡す。
        for reply in ["はい", "うん。", "そうだよ", "いいえ", "ううん", "違う", "そうじゃない。",
                      "言ったよ", "違うよ、ママに言ったの", "猫ちゃん、別の質問"] {
            XCTAssertEqual(AddresseePolicy().route(reply, at: 2, engagement: .inactive, pending: pending),
                           .classify(reply), reply)
        }
    }

    func testEngagementUsesThirtySecondSoftExpiryAndCanBeCleared() {
        var engagement = EngagementWindow()
        engagement.arm(at: 0)
        engagement.refresh(afterReplyAt: 10)
        XCTAssertTrue(engagement.isActive(at: 39.999))
        XCTAssertFalse(engagement.isActive(at: 40))

        engagement.arm(at: 100)
        engagement.clear()
        XCTAssertFalse(engagement.isActive(at: 100))
    }

    func testWakeNameDoesNotMatchLaterTextOrConcatenatedWord() {
        XCTAssertEqual(
            AddresseePolicy().route("今日は猫ちゃんどう？", at: 0, engagement: .inactive, pending: nil),
            .classify("今日は猫ちゃんどう？")
        )

        for utterance in [
            "ねこまんまについて教えて",
            "猫ちゃんねるを見せて",
            "Cat Roboticsについて",
            "キャットロボット工房について"
        ] {
            XCTAssertEqual(
                AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
                .classify(utterance)
            )
        }

        XCTAssertEqual(
            AddresseePolicy().route("Cat Robot2について", at: 0, engagement: .inactive, pending: nil),
            .classify("Cat Robot2について")
        )
    }

    func testClassificationPreservesFullOriginalTranscript() {
        let utterance = "  ねこまんまについて教えて  "

        XCTAssertEqual(
            AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
            .classify(utterance)
        )
    }

    func testEmptyAndFillerSpeechAreIgnored() {
        for utterance in ["", "  \n", "えー", "えっと", "あの", "うーん"] {
            XCTAssertEqual(
                AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
                .ignore
            )
        }
    }

    func testPunctuationOnlyNoiseIsIgnored() {
        for utterance in ["…", "、", "。。。"] {
            XCTAssertEqual(
                AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
                .ignore
            )
        }
    }

    func testFillerDuringPendingIsIgnoredWithoutDismissingIt() {
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)

        XCTAssertEqual(
            AddresseePolicy().route("えっと", at: 2, engagement: .inactive, pending: pending),
            .ignore
        )
    }

    func testNonYesNoPendingResponseClassifiesCurrentUtteranceAsNaturalCorrection() {
        var engagement = EngagementWindow()
        engagement.arm(at: 0)
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)

        XCTAssertEqual(
            AddresseePolicy().route("もう一度", at: 2, engagement: engagement, pending: pending),
            .classify("もう一度")
        )
    }

    func testPendingCreatedAtTrimsOriginalAndExpiresAfterFifteenSeconds() {
        let pending = PendingClarification(utterance: "  明日の予定は？ \n", at: 10)
        var engagement = EngagementWindow()
        engagement.arm(at: 0)

        XCTAssertEqual(pending.utterance, "明日の予定は？")
        // 確認待ちの間は会話継続中でも宛先判定へ回し、期限ちょうどからは従来の振り分けへ戻る。
        XCTAssertEqual(
            AddresseePolicy().route("うん", at: 24.999, engagement: engagement, pending: pending),
            .classify("うん")
        )
        XCTAssertEqual(
            AddresseePolicy().route("うん", at: 25, engagement: engagement, pending: pending),
            .accept("うん")
        )
    }
}
