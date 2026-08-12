import FoundationModels

enum FoundationModelFailureKind: Equatable, Sendable {
    case exceededContextWindowSize
    case assetsUnavailable
    case guardrailViolation
    case unsupportedGuide
    case unsupportedLanguageOrLocale
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case refusal
    case other
}

enum FoundationModelErrorMapper {
    static func map(_ failure: FoundationModelFailureKind) -> ConversationServiceError {
        switch failure {
        case .exceededContextWindowSize:
            return .contextExceeded
        case .assetsUnavailable:
            return .modelAssetsUnavailable
        case .guardrailViolation:
            return .guardrailViolation
        case .unsupportedLanguageOrLocale:
            return .modelLocaleUnsupported
        case .concurrentRequests:
            return .modelBusy
        case .refusal:
            return .refusal
        case .unsupportedGuide, .decodingFailure, .rateLimited, .other:
            return .modelGenerationFailed
        }
    }

    static func map(_ error: any Error) -> ConversationServiceError {
        if error is CancellationError {
            return .cancelled
        }

        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .modelGenerationFailed
        }

        switch generationError {
        case .exceededContextWindowSize:
            return map(.exceededContextWindowSize)
        case .assetsUnavailable:
            return map(.assetsUnavailable)
        case .guardrailViolation:
            return map(.guardrailViolation)
        case .unsupportedGuide:
            return map(.unsupportedGuide)
        case .unsupportedLanguageOrLocale:
            return map(.unsupportedLanguageOrLocale)
        case .decodingFailure:
            return map(.decodingFailure)
        case .rateLimited:
            return map(.rateLimited)
        case .concurrentRequests:
            return map(.concurrentRequests)
        case .refusal:
            return map(.refusal)
        @unknown default:
            return .modelGenerationFailed
        }
    }
}
