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

    /// 声の宛先判定（Claude Haiku）が使えなくても、文字の会話は Hermes だけで続けられる。
    func testVoiceAddressingFailuresOfferTypingBesideTheRecheck() {
        for availability in [ModelAvailability.claudeCredentialMissing, .claudeAttestationUnsupported, .claudeAttestationFailed, .claudeUnreachable] {
            let value = ConversationErrorPresentation(.modelUnavailable(availability))
            XCTAssertEqual(value.recoveries, [.init(title: "もう一度確認", action: .retry), .init(title: "文字で話す", action: .showTypedInput)],
                           "\(availability)")
            XCTAssertTrue(value.message.contains("声"), "the message says only voice addressing is affected: \(value.message)")
        }
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

    /// 宛先判定（Claude Haiku）の通信断や Hermes の 429・503 では、続けられる会話を捨てさせない（新しい会話の出口は返事の期限切れだけ）。
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
            .modelUnavailable(.claudeCredentialMissing),
            .modelUnavailable(.claudeAttestationUnsupported),
            .modelUnavailable(.claudeAttestationFailed),
            .modelUnavailable(.claudeUnreachable),
            .modelUnavailable(.hermesNotConfigured),
            .modelUnavailable(.hermesUnauthorized),
            .modelLocaleUnsupported,
            .guardrailViolation,
            .refusal,
            .contextExceeded,
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

    func testClaudeAvailabilityMessagesNameTheCause() {
        XCTAssertTrue(ConversationErrorPresentation(.modelUnavailable(.claudeCredentialMissing)).message.contains("App Attest"))
        XCTAssertTrue(ConversationErrorPresentation(.modelUnavailable(.claudeAttestationUnsupported)).message.contains("実機"))
        XCTAssertTrue(ConversationErrorPresentation(.modelUnavailable(.claudeAttestationFailed)).message.contains("ネットワーク"))
        XCTAssertTrue(ConversationErrorPresentation(.modelUnavailable(.claudeUnreachable)).message.contains("接続"))
        let unreachable = ConversationErrorPresentation(.modelUnreachable)
        XCTAssertTrue(unreachable.offersTypedInput)
        XCTAssertTrue(unreachable.recoveries.contains { $0.action == .retry })
    }
}
