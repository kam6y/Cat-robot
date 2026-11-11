import XCTest
@testable import CatRobot

final class ConversationFailureGuidanceTests: XCTestCase {
    func testEveryServiceErrorHasTheSpecifiedGuidanceOrIsAnException() {
        let cases: [(ConversationServiceError, String?)] = [
            (.modelUnreachable, ConversationFailureGuidance.unreachable),
            (.replyTimedOut, ConversationFailureGuidance.unreachable),
            (.modelUnavailable(.claudeUnreachable), ConversationFailureGuidance.unreachable),
            (.modelGenerationFailed, ConversationFailureGuidance.generationFailed),
            (.modelBusy, ConversationFailureGuidance.generationFailed),
            (.modelUnavailable(.available), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.hermesNotConfigured), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.hermesUnauthorized), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.claudeCredentialMissing), ConversationFailureGuidance.voiceAddressing),
            (.modelUnavailable(.claudeAttestationUnsupported), ConversationFailureGuidance.voiceAddressing),
            (.modelUnavailable(.claudeAttestationFailed), ConversationFailureGuidance.voiceAddressing),
            (.modelLocaleUnsupported, ConversationFailureGuidance.configuration),
            (.refusal, ConversationFailureGuidance.refused),
            (.guardrailViolation, ConversationFailureGuidance.refused),
            (.contextExceeded, ConversationFailureGuidance.contextExceeded),
            (.inputTooLong, ConversationFailureGuidance.inputTooLong),
            (.speechCaptureFailed, ConversationFailureGuidance.listening),
            (.speechEndpointingFailed, ConversationFailureGuidance.listening),
            (.speechCaptureAlreadyRunning, ConversationFailureGuidance.listening),
            (.speechAssetsUnavailable, ConversationFailureGuidance.listening),
            (.speechLocaleUnsupported, ConversationFailureGuidance.listening),
            (.speechVoiceUnavailable, nil), (.speechSynthesisFailed, nil), (.audioSessionFailed, nil),
            (.microphoneDenied, nil), (.cancelled, nil), (.speechUnrecognized, nil),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.spokenGuidance, expected, "\(error)")
        }
    }

    /// 返事は Hermes が作るので、声の案内はモデルの名前を出さない。宛先判定の失敗は文字の会話へ案内する。
    func testGuidanceNamesNoModelAndPointsVoiceAddressingFailuresToTyping() {
        for text in [ConversationFailureGuidance.unreachable, ConversationFailureGuidance.configuration,
                     ConversationFailureGuidance.voiceAddressing] {
            XCTAssertFalse(text.contains("Claude"), text)
        }
        XCTAssertTrue(ConversationFailureGuidance.voiceAddressing.contains("文字"))
    }
}
