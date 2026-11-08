import Foundation

enum SupertonicErrorMapper {
    static func map(_ error: Error) -> ConversationServiceError {
        switch error as? SupertonicError {
        case .missingAssets, .invalidAssets, .unsupportedVoice: .speechVoiceUnavailable
        default: .speechSynthesisFailed
        }
    }

    /// Awaits one native step once; cancellation stays `.cancelled`, every other failure goes through `map`.
    static func mapping<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is CancellationError { throw ConversationServiceError.cancelled }
        catch { throw map(error) }
    }
}
