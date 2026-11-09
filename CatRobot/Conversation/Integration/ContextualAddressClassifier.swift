import Foundation

/// 宛先判定に直近の会話を添える decorator。
struct ContextualAddressClassifier: AddressClassifying {
    private let base: any AddressClassifying
    private let history: any ConversationHistoryReading
    private let characterLimit: Int

    init(base: any AddressClassifying, history: any ConversationHistoryReading,
         characterLimit: Int = ConversationBudget().retainedCharacters) {
        self.base = base
        self.history = history
        self.characterLimit = characterLimit
    }

    /// 新しい方から合計 characterLimit を超えない往復。最新の 1 往復だけで超えれば空。
    /// clarification があり、末尾が (originalUtterance, ClarificationContext.question) に一致すれば末尾を除く。
    static func contextTurns(_ turns: [ConversationMemoryTurn], clarification: ClarificationContext?,
                             characterLimit: Int) -> [ConversationMemoryTurn] {
        guard characterLimit > 0 else { return [] }
        var end = turns.endIndex
        if let clarification, end > 0,
           turns[end - 1].prompt == clarification.originalUtterance,
           turns[end - 1].response == ClarificationContext.question {
            end -= 1
        }

        var start = end, characters = 0
        while start > 0 {
            let turn = turns[start - 1]
            let count = turn.prompt.count + turn.response.count
            guard count <= characterLimit - characters else { break }
            characters += count
            start -= 1
        }
        return Array(turns[start..<end])
    }

    func classify(_ request: AddressClassificationRequest) async throws -> AddressTarget {
        try Task.checkCancellation()
        let turns = await history.recentTurns()
        try Task.checkCancellation()
        let context = Self.contextTurns(turns, clarification: request.clarification, characterLimit: characterLimit)
        try Task.checkCancellation()
        return try await base.classify(.init(utterance: request.utterance,
                                            clarification: request.clarification, recentTurns: context))
    }
}
