import Foundation

struct ConversationErrorPresentation: Equatable, Sendable {
    let message: String
    let recoveries: [ConversationRecovery]

    var offersTypedInput: Bool {
        recoveries.contains { $0.action == .showTypedInput }
    }

    init(_ error: ConversationServiceError) {
        switch error {
        case .microphoneDenied:
            message = "マイクを使えません。設定で許可するか、文字で話しかけてください。"
            recoveries = [.settings, .typedInput]
        case .speechAssetsUnavailable:
            message = "日本語の聞き取りを準備できませんでした。もう一度試すか、文字で話しかけてください。"
            recoveries = [.retry, .typedInput]
        case .speechLocaleUnsupported:
            message = "この端末では日本語を聞き取れません。文字で話しかけてください。"
            recoveries = [.typedInput]
        case .speechUnrecognized:
            message = "うまく聞き取れませんでした"
            recoveries = [.retry, .typedInput]
        case .speechCaptureFailed:
            message = "マイクの聞き取りを続けられませんでした。"
            recoveries = [.retry, .typedInput]
        case .speechCaptureAlreadyRunning:
            message = "マイクの状態を整えられませんでした。"
            recoveries = [.retry, .typedInput]
        case .speechVoiceUnavailable:
            message = "日本語の声を準備できませんでした。"
            recoveries = [.retry]
        case .speechSynthesisFailed:
            message = "返事を音声で再生できませんでした。"
            recoveries = [.retry]
        case .audioSessionFailed:
            message = "マイクとスピーカーを使う準備ができませんでした。"
            recoveries = [.retry, .settings]
        case .modelUnavailable(let availability):
            switch availability {
            case .available:
                message = "会話モデルの状態を確認できませんでした。"
                recoveries = [.checkAgain]
            case .deviceNotEligible:
                message = "このiPhoneではApple Intelligenceの会話モデルを利用できません。"
                recoveries = [.checkAgain]
            case .appleIntelligenceNotEnabled:
                message = "Apple Intelligenceがオフです。設定で有効にしてください。"
                recoveries = [.settings]
            case .modelNotReady:
                message = "会話モデルを準備しています。少し待ってから、もう一度確認してください。"
                recoveries = [.checkAgain]
            case .unsupportedLocale:
                message = "Apple Intelligenceの言語設定が日本語に対応していません。"
                recoveries = [.settings]
            }
        case .modelLocaleUnsupported:
            message = "この言語では会話モデルを利用できません。設定を確認してください。"
            recoveries = [.settings]
        case .modelAssetsUnavailable:
            message = "会話モデルの準備が完了していません。少し待ってから、もう一度お試しください。"
            recoveries = [.checkAgain]
        case .guardrailViolation:
            message = "その内容には答えられません。言い方を変えて話しかけてください。"
            recoveries = [.retry]
        case .refusal:
            message = "そのお願いには答えられません。別の話題を話しかけてください。"
            recoveries = [.retry]
        case .contextExceeded:
            message = "会話が長くなったため、短期の会話内容をリセットしました。もう一度話しかけてください。"
            recoveries = [.retry]
        case .modelBusy:
            message = "いまは返事を作っているところです。少し待ってから、もう一度お試しください。"
            recoveries = [.retry]
        case .modelGenerationFailed:
            message = "返事を作れませんでした。もう一度話しかけてください。"
            recoveries = [.retry]
        case .cancelled:
            message = "会話を一時停止しました。"
            recoveries = [.retry]
        }
    }
}

private extension ConversationRecovery {
    static let retry = Self(title: "もう一度", action: .retry)
    static let checkAgain = Self(title: "もう一度確認", action: .retry)
    static let settings = Self(title: "設定を開く", action: .openSettings)
    static let typedInput = Self(title: "文字で話す", action: .showTypedInput)
}
