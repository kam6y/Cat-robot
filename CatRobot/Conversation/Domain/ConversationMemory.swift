import Foundation

struct ConversationMemoryTurn: Codable, Equatable, Sendable {
    let prompt: String
    let response: String
}

struct ConversationMemorySnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let memoryCompatibilityID: String
    let revision: UInt64
    let savedAt: Date
    let summary: String
    let turns: [ConversationMemoryTurn]

    func validate(expectedCompatibilityID: String) throws {
        guard schemaVersion == 1 else { throw ConversationMemoryError.unsupportedSchema }
        guard memoryCompatibilityID == expectedCompatibilityID else { throw ConversationMemoryError.incompatibleModel }
        guard savedAt.timeIntervalSince1970.isFinite,
              revision > 0 || (summary.isEmpty && turns.isEmpty),
              turns.allSatisfy({ !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConversationMemoryError.invalidData
        }
    }
}

enum ConversationMemoryError: Error, Equatable, Sendable {
    case invalidData, unsupportedSchema, incompatibleModel, tooLarge
    case readFailed, writeFailed, deleteFailed, unavailable, unsupported
}

enum ConversationMemoryState: Equatable, Sendable {
    case unsupported, unprepared, loading, ready, saving, unsaved
    case restoreFailed(ConversationMemoryError)
    case forgetting, forgetFailed(ConversationMemoryError)
}

protocol ConversationMemoryStore: Sendable {
    func load() async throws -> ConversationMemorySnapshot?
    func save(_ snapshot: ConversationMemorySnapshot) async throws
    func clear() async throws
}

protocol ConversationMemoryManaging: Sendable {
    func prepareMemory() async throws
    func memoryState() async -> ConversationMemoryState
    func memoryUpdates() async -> AsyncStream<ConversationMemoryState>
    func retryMemoryOperation() async throws
    func forgetConversation() async throws
}
