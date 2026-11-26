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
    var audioTurnEnd: AudioTurnEndSignal? = nil

    static func audioEnded(_ signal: AudioTurnEndSignal) -> Self {
        .init(text: "", isFinal: false, audioTurnEnd: signal)
    }

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

/// 会話モデルの可否。通常の返事は Hermes、宛先判定は Claude（Haiku）が受け持つ。
enum ModelAvailability: Equatable, Sendable {
    case available
    case claudeCredentialMissing
    case claudeAttestationUnsupported
    case claudeAttestationFailed
    case claudeUnreachable
    /// Hermes の接続先か API キーが設定されていない。
    case hermesNotConfigured
    /// Hermes が API キーを受け付けなかった（401）。
    case hermesUnauthorized
}

enum ConversationServiceError: Error, Equatable, Sendable {
    case microphoneDenied
    case speechAssetsUnavailable
    case speechLocaleUnsupported
    case speechUnrecognized
    case speechCaptureFailed
    case speechEndpointingFailed
    case speechCaptureAlreadyRunning
    case speechVoiceUnavailable
    case speechSynthesisFailed
    case audioSessionFailed
    case modelUnavailable(ModelAvailability)
    case modelLocaleUnsupported
    case guardrailViolation
    case refusal
    case contextExceeded
    case inputTooLong
    case modelBusy
    case modelGenerationFailed
    /// 通信断・タイムアウト・レート制限（通信到達不能）。
    case modelUnreachable
    /// 返事が期限までに届かなかった（受付の分からない送信のまま、または受け付けられた run が終わらないまま）。
    /// installed Hermes で終わらない run が同じ会話の後続を止める場合を含む。
    case replyTimedOut
    case cancelled
}

enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case outputVolumeChanged
}
