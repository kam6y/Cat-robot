/// 設定の「会話の履歴」が読む会話。正本は Hermes にあり、端末は表示のたびに読み、保存しない。
protocol ConversationTranscriptReading: Sendable {
    func transcript() async throws -> [HermesTranscriptEntry]
}

extension HermesConversationService: ConversationTranscriptReading {}
