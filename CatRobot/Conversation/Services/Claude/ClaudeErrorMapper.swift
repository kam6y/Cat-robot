import ClaudeForFoundationModels
import Foundation
import FoundationModels

/// Claude 経由の失敗を既存の会話エラーへ写す。認証の失敗は「利用不可の理由」、
/// 通信断・タイムアウト・レート制限は `modelUnreachable`（端末内モデルへ切り替える判断材料）。
enum ClaudeErrorMapper {
    static func map(_ error: any Error) -> ConversationServiceError {
        if error is CancellationError { return .cancelled }
        if let service = error as? ConversationServiceError { return service }
        if let claude = error as? ClaudeError {
            switch claude {
            case .missingCredential: return .modelUnavailable(.claudeCredentialMissing)
            case .attestationUnsupported: return .modelUnavailable(.claudeAttestationUnsupported)
            case .attestationFailed: return .modelUnavailable(.claudeAttestationFailed)
            }
        }
        if let framework = error as? LanguageModelError {
            switch framework {
            case .contextSizeExceeded: return .contextExceeded
            case .rateLimited, .timeout: return .modelUnreachable
            case .refusal: return .refusal
            case .guardrailViolation: return .guardrailViolation
            case .unsupportedLanguageOrLocale: return .modelLocaleUnsupported
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                return .modelGenerationFailed
            @unknown default: return .modelGenerationFailed
            }
        }
        if error is URLError { return .modelUnreachable }
        return FoundationModelErrorMapper.map(error)
    }

    static func availability(_ error: any Error) -> ModelAvailability {
        if case .modelUnavailable(let availability) = map(error) { return availability }
        return .claudeUnreachable
    }
}
