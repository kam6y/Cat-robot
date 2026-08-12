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

    func testAllWakeNamesWithoutContentRouteToWakeOnly() {
        for utterance in ["ねこ", "猫ちゃん。", "cAt rObOt？", "キャットロボット、、、"] {
            XCTAssertEqual(
                AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
                .wakeOnly
            )
        }
    }

    func testAllWakeNamesAcceptUndelimitedJapaneseStarter() {
        for utterance in [
            "ねこ今日どう？",
            "猫ちゃん今日どう？",
            "cAt rObOt今日どう？",
            "キャットロボット今日どう？"
        ] {
            XCTAssertEqual(
                AddresseePolicy().route(utterance, at: 0, engagement: .inactive, pending: nil),
                .accept("今日どう？")
            )
        }
    }

    func testUndelimitedWakeNameUsesOnlyDocumentedConversationalStarters() {
        let cases: [(utterance: String, accepted: String)] = [
            ("ねこ今日の天気", "今日の天気"),
            ("ねこ今何時", "今何時"),
            ("ねこ明日の予定", "明日の予定"),
            ("ねこどう思う", "どう思う"),
            ("ねこ何してる", "何してる"),
            ("ねこなにしてる", "なにしてる"),
            ("ねこいつ会える", "いつ会える"),
            ("ねこどこにいる", "どこにいる"),
            ("ねこ誰が来る", "誰が来る"),
            ("ねこだれが来る", "だれが来る"),
            ("ねこなぜ空は青い", "なぜ空は青い"),
            ("ねこなんで笑うの", "なんで笑うの"),
            ("ねこ元気？", "元気？"),
            ("ねこ教えて", "教えて"),
            ("ねこ聞いて", "聞いて"),
            ("ねこお願い", "お願い"),
            ("ねこおはよう", "おはよう"),
            ("ねここんにちは", "こんにちは"),
            ("ねここんばんは", "こんばんは")
        ]

        for testCase in cases {
            XCTAssertEqual(
                AddresseePolicy().route(testCase.utterance, at: 0, engagement: .inactive, pending: nil),
                .accept(testCase.accepted)
            )
        }

        XCTAssertEqual(
            AddresseePolicy().route("ねこ質問がある", at: 0, engagement: .inactive, pending: nil),
            .classify("ねこ質問がある")
        )
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
