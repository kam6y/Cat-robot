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

    func testToolRuntimeFailureOffersRetryAndTypedInputWithoutPrivateDetail() {
        let presentation = ConversationErrorPresentation(.toolRuntimeFailed)

        XCTAssertEqual(
            presentation.message,
            "記憶機能を使った返事を完了できませんでした。もう一度話しかけてください。"
        )
        XCTAssertEqual(presentation.recoveries.map(\.action), [.retry, .showTypedInput])
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
            .modelUnavailable(.deviceNotEligible),
            .modelUnavailable(.appleIntelligenceNotEnabled),
            .modelUnavailable(.modelNotReady),
            .modelUnavailable(.unsupportedLocale),
            .modelLocaleUnsupported,
            .modelAssetsUnavailable,
            .guardrailViolation,
            .refusal,
            .contextExceeded,
            .modelBusy,
            .modelGenerationFailed,
            .toolRuntimeFailed,
            .cancelled,
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
}
