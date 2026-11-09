import XCTest
@testable import CatRobot

final class ConversationFailureGuidanceTests: XCTestCase {
    func testEveryServiceErrorHasTheSpecifiedGuidanceOrIsAnException() {
        let cases: [(ConversationServiceError, String?)] = [
            (.modelUnreachable, ConversationFailureGuidance.unreachable),
            (.modelUnavailable(.claudeUnreachable), ConversationFailureGuidance.unreachable),
            (.modelGenerationFailed, ConversationFailureGuidance.generationFailed),
            (.modelBusy, ConversationFailureGuidance.generationFailed),
            (.modelUnavailable(.available), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.claudeCredentialMissing), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.claudeAttestationUnsupported), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.claudeAttestationFailed), ConversationFailureGuidance.configuration),
            (.modelLocaleUnsupported, ConversationFailureGuidance.configuration),
            (.dailyLimitReached, ConversationFailureGuidance.dailyLimit),
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
}
