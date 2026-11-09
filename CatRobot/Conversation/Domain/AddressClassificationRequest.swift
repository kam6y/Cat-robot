struct ClarificationContext: Equatable, Sendable {
    static let question = "今の、ぼくに言った？"
    let originalUtterance: String
}

struct AddressClassificationRequest: Equatable, Sendable {
    let utterance: String
    let clarification: ClarificationContext?
    /// 分類器にだけ渡す直近の会話（古い順）。返答の prompt や保存には使わない。
    let recentTurns: [ConversationMemoryTurn]

    init(utterance: String, clarification: ClarificationContext? = nil, recentTurns: [ConversationMemoryTurn] = []) {
        self.utterance = utterance
        self.clarification = clarification
        self.recentTurns = recentTurns
    }
}
