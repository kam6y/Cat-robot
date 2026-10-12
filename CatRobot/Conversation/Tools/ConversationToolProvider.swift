import FoundationModels

/// セッションに渡すツールの集合。セッションを作るたびに呼ばれ、memory はそのセッションの世代に固定された書き込み口。
/// 計画 3（move_head）と計画 4（express / look）はここにツールを足す。
protocol ConversationToolProvider: Sendable {
    func tools(memory: any LongTermMemoryWriting) -> [any Tool]
}

struct RememberToolProvider: ConversationToolProvider {
    func tools(memory: any LongTermMemoryWriting) -> [any Tool] { [RememberTool(memory: memory)] }
}
