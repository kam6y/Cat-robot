import Foundation

enum SupertonicErrorMapper {
    static func map(_ error: Error) -> ConversationServiceError {
        switch error as? SupertonicError {
        case .missingAssets, .invalidAssets, .unsupportedVoice: .speechVoiceUnavailable
        default: .speechSynthesisFailed
        }
    }
}
