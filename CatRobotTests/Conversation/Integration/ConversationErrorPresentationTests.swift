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

    func testModelPreparingOffersRetry() {
        let value = ConversationErrorPresentation(.modelUnavailable(.modelNotReady))

        XCTAssertEqual(
            value.recoveries,
            [.init(title: "もう一度確認", action: .retry)]
        )
    }

    func testUnrecognizedSpeechOffersRetryAndTyping() {
        let value = ConversationErrorPresentation(.speechUnrecognized)

        XCTAssertEqual(value.message, "うまく聞き取れませんでした")
        XCTAssertEqual(value.recoveries.map(\.action), [.retry, .showTypedInput])
    }

    func testEveryServiceErrorOffersRecoveryWithoutDebugDescriptions() {
        let dailyLimit = ConversationErrorPresentation(.dailyLimitReached)
        XCTAssertEqual(dailyLimit.recoveries.map(\.action), [.openSettings])
        XCTAssertTrue(dailyLimit.message.contains("上限"))
        XCTAssertFalse(ConversationServiceError.dailyLimitReached.allowsOnDeviceFallback)
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
            .modelUnavailable(.deviceNotEligible),
            .modelUnavailable(.appleIntelligenceNotEnabled),
            .modelUnavailable(.modelNotReady),
            .modelUnavailable(.unsupportedLocale),
            .modelUnavailable(.claudeCredentialMissing),
            .modelUnavailable(.claudeAttestationUnsupported),
            .modelUnavailable(.claudeAttestationFailed),
            .modelUnavailable(.claudeUnreachable),
            .modelLocaleUnsupported,
            .modelAssetsUnavailable,
            .guardrailViolation,
            .refusal,
            .contextExceeded,
            .inputTooLong,
            .modelBusy,
            .modelGenerationFailed,
            .cancelled,
            .modelUnreachable,
            .dailyLimitReached,
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
