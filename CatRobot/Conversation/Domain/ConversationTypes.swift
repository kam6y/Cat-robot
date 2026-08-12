import Foundation

enum ConversationPhase: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case classifying
    case clarifying
    case thinking
    case speaking
    case paused
    case failed(ConversationServiceError)
}

enum AddressTarget: Equatable, Sendable {
    case addressed
    case ambiguous
    case notAddressed
}

struct SpeechRecognitionEvent: Equatable, Sendable {
    var text: String
    var isFinal: Bool

    static func provisional(_ text: String) -> Self {
        .init(text: text, isFinal: false)
    }

    static func finalized(_ text: String) -> Self {
        .init(text: text, isFinal: true)
    }
}

enum SpeechEvent: Equatable, Sendable {
    case started
    case willSpeak(range: Range<Int>)
    case finished
    case cancelled
}

enum ModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
}

enum ConversationServiceError: Error, Equatable, Sendable {
    case microphoneDenied
    case speechAssetsUnavailable
    case speechLocaleUnsupported
    case speechUnrecognized
    case speechCaptureFailed
    case speechCaptureAlreadyRunning
    case speechVoiceUnavailable
    case speechSynthesisFailed
    case audioSessionFailed
    case modelUnavailable(ModelAvailability)
    case modelLocaleUnsupported
    case modelAssetsUnavailable
    case guardrailViolation
    case refusal
    case contextExceeded
    case modelBusy
    case modelGenerationFailed
    case cancelled
}

enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
}
