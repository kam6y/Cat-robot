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

extension Character {
    /// 認識結果のうち、句読点や雑音ではなく言葉として数える文字（文字と数字）。
    var isLexical: Bool { isLetter || isNumber }
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
    // Claude 側の理由（Task 2）
    case claudeCredentialMissing
    case claudeAttestationUnsupported
    case claudeAttestationFailed
    case claudeUnreachable
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
    case inputTooLong
    case modelBusy
    case modelGenerationFailed
    /// 通信断・タイムアウト・レート制限（通信到達不能）。
    case modelUnreachable
    case dailyLimitReached
    case cancelled
}

extension ConversationServiceError {
    /// 端末内モデルへ切り替えてよい失敗（FR-LLM-4）。通信到達不能（.modelUnreachable）と汎用の生成失敗（.modelGenerationFailed）だけ。
    /// パッケージが型を公開しない API エラー（HTTP 5xx の api_error。0.2.3 では 400/403/404 も）は .modelGenerationFailed に写るので、ここで拾う。
    /// 公開 API で識別できる認証・権限（.modelUnavailable）、拒否、guardrail、文脈超過、入力過長、取り消しは切り替えない。
    var allowsOnDeviceFallback: Bool {
        switch self {
        case .modelUnreachable, .modelGenerationFailed:
            return true
        case .microphoneDenied, .speechAssetsUnavailable, .speechLocaleUnsupported, .speechUnrecognized, .speechCaptureFailed,
             .speechCaptureAlreadyRunning, .speechVoiceUnavailable, .speechSynthesisFailed, .audioSessionFailed,
             .modelUnavailable, .modelLocaleUnsupported, .modelAssetsUnavailable, .guardrailViolation, .refusal,
             .contextExceeded, .inputTooLong, .modelBusy, .dailyLimitReached, .cancelled:
            return false
        }
    }
}

enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
}
