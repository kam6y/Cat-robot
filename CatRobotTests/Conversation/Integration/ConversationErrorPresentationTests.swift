import XCTest
@testable import CatRobot

final class ConversationErrorPresentationTests: XCTestCase {

    func testMicrophoneDenialOffersTypedFallback() {
        let value = ConversationErrorPresentation(.microphoneDenied)

        XCTAssertEqual(
            value.message,
            "マイクを使えません。設定で許可するか、文字で話しかけてください。"
        )
        XCTAssertTrue(value.offersTypedInput)
        XCTAssertEqual(value.recoveries, [
            .init(title: "設定を開く", action: .openSettings),
            .init(title: "文字で話す", action: .showTypedInput),
        ])
    }

    /// 未設定・キーの拒否は、iOS の設定アプリではなくアプリ内の接続の欄へ案内する。
    func testHermesConfigurationFailuresOpenTheConnectionSettings() {
        let unconfigured = ConversationErrorPresentation(.modelUnavailable(.hermesNotConfigured))
        XCTAssertEqual(unconfigured.message, "返事に使う Hermes の接続先が設定されていません。設定で接続先と API キーを入力してください。")
        let rejected = ConversationErrorPresentation(.modelUnavailable(.hermesUnauthorized))
        XCTAssertEqual(rejected.message, "Hermes が API キーを受け付けませんでした。設定でキーを確かめるか、Hermes 側を直してから「もう一度確認」を押してください。")
        for value in [unconfigured, rejected] {
            XCTAssertEqual(value.recoveries, [.init(title: "接続を設定", action: .openConnectionSettings),
                                              .init(title: "もう一度確認", action: .retry)])
        }
    }

    /// 同じ会話が回復しない（Hermes の unknown run が後続を止める）ときは、期限切れの繰り返しで終わらせず新しい会話へ出られる。
    func testAnUnansweredTurnOffersANewConversation() {
        let value = ConversationErrorPresentation(.replyTimedOut)
        XCTAssertEqual(value.recoveries.map(\.action), [.retry, .showTypedInput, .startNewConversation])
        XCTAssertEqual(value.recoveries.last?.title, "新しい会話を始める")
        XCTAssertTrue(value.message.contains("新しい会話"), value.message)
    }

    /// Hermes（返事と宛先判定）の通信断や 429・503 では、続けられる会話を捨てさせない（新しい会話の出口は返事の期限切れだけ）。
    func testAnUnreachableModelDoesNotOfferANewConversation() {
        let value = ConversationErrorPresentation(.modelUnreachable)
        XCTAssertEqual(value.recoveries.map(\.action), [.retry, .showTypedInput])
        XCTAssertFalse(value.message.contains("新しい会話"), value.message)
    }

    func testUnrecognizedSpeechOffersRetryAndTyping() {
        let value = ConversationErrorPresentation(.speechUnrecognized)

        XCTAssertEqual(value.message, "うまく聞き取れませんでした")
        XCTAssertEqual(value.recoveries.map(\.action), [.retry, .showTypedInput])
    }

    func testEveryServiceErrorOffersRecoveryWithoutDebugDescriptions() {
        let errors: [ConversationServiceError] = [
            .microphoneDenied,
            .speechAssetsUnavailable,
            .speechLocaleUnsupported,
            .speechUnrecognized,
            .speechCaptureFailed,
            .speechCaptureAlreadyRunning,
            .speechVoiceUnavailable,
            .speechSynthesisFailed,
            .audioSessionFailed,
            .modelUnavailable(.available),
            .modelUnavailable(.hermesNotConfigured),
            .modelUnavailable(.hermesUnauthorized),
            .inputTooLong,
            .modelBusy,
            .modelGenerationFailed,
            .cancelled,
            .modelUnreachable,
            .replyTimedOut,
        ]

        for error in errors {
            let value = ConversationErrorPresentation(error)
            let debugDescription = String(describing: error)

            XCTAssertFalse(value.message.isEmpty, "\(error) needs user-facing copy")
            XCTAssertFalse(
                value.message.localizedCaseInsensitiveContains(debugDescription),
                "\(error) leaked its debug description"
            )
            XCTAssertFalse(value.recoveries.isEmpty, "\(error) needs a recovery")
        }
    }

    func testUnreachableReplyOffersTypingAndRetry() {
        let unreachable = ConversationErrorPresentation(.modelUnreachable)
        XCTAssertTrue(unreachable.offersTypedInput)
        XCTAssertTrue(unreachable.recoveries.contains { $0.action == .retry })
    }
}
