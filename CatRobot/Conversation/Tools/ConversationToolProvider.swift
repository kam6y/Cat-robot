import FoundationModels

/// セッションに渡すツールの集合。セッションを作るたびに呼ばれ、memory はそのセッションの世代に固定された書き込み口。
/// 計画 3（move_head）と計画 4（express / look）はここにツールを足す。
protocol ConversationToolProvider: Sendable {
    func tools(memory: any LongTermMemoryWriting) -> [any Tool]
}

struct RememberToolProvider: ConversationToolProvider {
    func tools(memory: any LongTermMemoryWriting) -> [any Tool] { [RememberTool(memory: memory)] }
}

/// テスト用。memory に関係なく固定の配列を返す。
struct StaticToolProvider: ConversationToolProvider {
    private let items: [any Tool]
    init(_ items: [any Tool]) { self.items = items }
    func tools(memory: any LongTermMemoryWriting) -> [any Tool] { items }
}
