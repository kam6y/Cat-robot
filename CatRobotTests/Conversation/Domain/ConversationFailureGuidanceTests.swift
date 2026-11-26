import XCTest
@testable import CatRobot

final class ConversationFailureGuidanceTests: XCTestCase {
    func testEveryServiceErrorHasTheSpecifiedGuidanceOrIsAnException() {
        let cases: [(ConversationServiceError, String?)] = [
            (.modelUnreachable, ConversationFailureGuidance.unreachable),
            (.replyTimedOut, ConversationFailureGuidance.unreachable),
            (.modelGenerationFailed, ConversationFailureGuidance.generationFailed),
            (.modelBusy, ConversationFailureGuidance.generationFailed),
            (.modelUnavailable(.available), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.hermesNotConfigured), ConversationFailureGuidance.configuration),
            (.modelUnavailable(.hermesUnauthorized), ConversationFailureGuidance.configuration),




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

    /// 返事も宛先判定も Hermes が受け持つので、声の案内はモデルやサービスの名前を出さない。
    func testGuidanceNamesNoModelOrService() {
        for text in [ConversationFailureGuidance.unreachable, ConversationFailureGuidance.configuration] {
            XCTAssertFalse(text.contains("Claude"), text)
            XCTAssertFalse(text.contains("Hermes"), text)
        }
    }
}
