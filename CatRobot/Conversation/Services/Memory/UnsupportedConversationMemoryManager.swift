struct UnsupportedConversationMemoryManager: ConversationMemoryManaging {
    func prepareMemory() async throws {}
    func retryMemoryOperation() async throws {}
    func memoryState() async -> ConversationMemoryState { .unsupported }
    func memoryUpdates() async -> AsyncStream<ConversationMemoryState> {
        AsyncStream { $0.yield(.unsupported); $0.finish() }
    }
    func forgetConversation() async throws { throw ConversationMemoryError.unsupported }
}
