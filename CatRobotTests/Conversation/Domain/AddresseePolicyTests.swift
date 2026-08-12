import XCTest
@testable import CatRobot

final class AddresseePolicyTests: XCTestCase {
    func testWakeNameAcceptsAndStripsOnlyLeadingAddress() {
        let result = AddresseePolicy().route("猫ちゃん、今日どう？", at: 0, engagement: .inactive, pending: nil)
        XCTAssertEqual(result, .accept("今日どう？"))
    }

    func testEngagedTurnSkipsClassifierButHardExpiryDoesNotExtend() {
        var engagement = EngagementWindow()
        engagement.arm(at: 0)
        engagement.refresh(afterReplyAt: 290)
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 299, engagement: engagement, pending: nil), .accept("続けて"))
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 300, engagement: engagement, pending: nil), .classify("続けて"))
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 301, engagement: engagement, pending: nil), .classify("続けて"))
    }

    func testAffirmativeUsesPendingOriginalAndNegativeDropsIt() {
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)
        XCTAssertEqual(AddresseePolicy().route("うん", at: 2, engagement: .inactive, pending: pending), .accept("明日の予定は？"))
        XCTAssertEqual(AddresseePolicy().route("違う", at: 2, engagement: .inactive, pending: pending), .ignore)
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

    func testAllWakeNamesUseLeadingFastPath() {
        let cases: [(utterance: String, accepted: String)] = [
            ("ねこ、天気は？", "天気は？"),
            ("猫ちゃん 今日どう？", "今日どう？"),
            ("cAt rObOt: tell me", "tell me"),
            ("キャットロボット、元気？", "元気？")
        ]

        for testCase in cases {
            XCTAssertEqual(
                AddresseePolicy().route(testCase.utterance, at: 0, engagement: .inactive, pending: nil),
                .accept(testCase.accepted)
            )
        }
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
    }

    func testEmptyFillerAndWakeOnlySpeechAreIgnored() {
        for utterance in ["", "  \n", "えー", "えっと", "あの", "うーん", "猫ちゃん", "Cat Robot。"] {
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

    func testPendingClarificationRecognizesShortJapaneseYesAndNoTokens() {
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)

        for affirmative in ["はい", "ええ", "そう", "そうだよ", "そうです", "うん。"] {
            XCTAssertEqual(
                AddresseePolicy().route(affirmative, at: 2, engagement: .inactive, pending: pending),
                .accept("明日の予定は？")
            )
        }
        for negative in ["いいえ", "ううん", "いや", "ちがう", "違います", "そうじゃない。"] {
            XCTAssertEqual(
                AddresseePolicy().route(negative, at: 2, engagement: .inactive, pending: pending),
                .ignore
            )
        }
    }

    func testPendingClarificationTakesPriorityOverActiveEngagement() {
        var engagement = EngagementWindow()
        engagement.arm(at: 0)
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)

        XCTAssertEqual(
            AddresseePolicy().route("もう一度", at: 2, engagement: engagement, pending: pending),
            .confirmPending(original: "明日の予定は？")
        )
    }

    func testPendingCreatedAtTrimsOriginalAndExpiresAfterFifteenSeconds() {
        let pending = PendingClarification(utterance: "  明日の予定は？ \n", at: 10)

        XCTAssertEqual(
            AddresseePolicy().route("待って", at: 24.999, engagement: .inactive, pending: pending),
            .confirmPending(original: "明日の予定は？")
        )
        XCTAssertEqual(
            AddresseePolicy().route("待って", at: 25, engagement: .inactive, pending: pending),
            .classify("待って")
        )
    }
}
