import Foundation

enum ConversationMemoryError: Error, Equatable, Sendable {
    case unavailable, unsupported
}

enum ConversationMemoryState: Equatable, Sendable {
    case unsupported, unprepared, loading, ready, saving, unsaved
    case restoreFailed(ConversationMemoryError)
    case forgetting, forgetFailed(ConversationMemoryError)
}

protocol ConversationMemoryManaging: Sendable {
    func prepareMemory() async throws
    func memoryState() async -> ConversationMemoryState
    func memoryUpdates() async -> AsyncStream<ConversationMemoryState>
    func retryMemoryOperation() async throws
    func forgetConversation() async throws
}
