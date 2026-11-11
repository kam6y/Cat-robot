enum ConversationFailureGuidance {
    static let unreachable = "ごめんね、いまはうまくつながらないみたい。少し待ってから、また話しかけてね。"
    static let generationFailed = "ごめんね、いまはうまく答えられなかった。もう一回話しかけてね。"
    static let configuration = "ごめんね、返事をする準備ができていないみたい。設定を確認してね。"
    static let refused = "ごめんね、それには答えられないんだ。別の話をしよう。"
    static let contextExceeded = "ごめんね、話が長くなりすぎて、うまく続けられなかった。もう一回話しかけてね。"
    static let inputTooLong = "ちょっと長すぎて、一度に聞ききれなかった。短く分けて話してね。"
    static let listening = "ごめんね、いまは聞き取りがうまくできないみたい。もう一度試してみてね。"
    static let memory = "ごめんね、会話の記憶をうまく読めなかったみたい。"
    /// 声の宛先判定（Claude Haiku）が使えない。返事は Hermes なので文字なら続けられる。
    static let voiceAddressing = "ごめんね、いまは声の呼びかけをうまく確かめられないみたい。文字で話しかけてね。"
}

extension ConversationServiceError {
    /// 声で案内する文。音声出力そのものの失敗・マイク拒否・取消・聞き取り中の speechUnrecognized は声なし（nil）。
    var spokenGuidance: String? {
        switch self {
        case .modelUnreachable, .replyTimedOut, .modelUnavailable(.claudeUnreachable):
            ConversationFailureGuidance.unreachable
        case .modelUnavailable(.claudeCredentialMissing), .modelUnavailable(.claudeAttestationUnsupported),
             .modelUnavailable(.claudeAttestationFailed):
            ConversationFailureGuidance.voiceAddressing
        case .modelGenerationFailed, .modelBusy:
            ConversationFailureGuidance.generationFailed
        case .modelUnavailable, .modelLocaleUnsupported:
            ConversationFailureGuidance.configuration
        case .refusal, .guardrailViolation:
            ConversationFailureGuidance.refused
        case .contextExceeded:
            ConversationFailureGuidance.contextExceeded
        case .inputTooLong:
            ConversationFailureGuidance.inputTooLong
        case .speechCaptureFailed, .speechEndpointingFailed, .speechCaptureAlreadyRunning,
             .speechAssetsUnavailable, .speechLocaleUnsupported:
            ConversationFailureGuidance.listening
        case .speechVoiceUnavailable, .speechSynthesisFailed, .audioSessionFailed,
             .microphoneDenied, .cancelled, .speechUnrecognized:
            nil
        }
    }
}
