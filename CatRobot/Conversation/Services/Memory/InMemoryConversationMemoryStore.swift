actor InMemoryConversationMemoryStore: ConversationMemoryStore {
    private var snapshot: ConversationMemorySnapshot?
    init(snapshot: ConversationMemorySnapshot? = nil) { self.snapshot = snapshot }
    func load() -> ConversationMemorySnapshot? { snapshot }
    func save(_ snapshot: ConversationMemorySnapshot) { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}
