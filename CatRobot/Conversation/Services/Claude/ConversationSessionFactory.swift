import Foundation
import FoundationModels

struct ConversationSessionConfiguration: Equatable, Sendable {
    var model: ConversationModelChoice
    var effort: ConversationEffort
    var instructions: String
}

protocol ConversationSessionClient: Sendable {
    func prewarm() async
    /// 累積スナップショット（既存の ReplyGenerating と同じ契約）。失敗は ConversationServiceError に写像して投げる。
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error>
}

struct ConversationSummaryRequest: Equatable, Sendable {
    var previousSummary: String
    var evictedTurns: [ConversationMemoryTurn]
    var characterLimit: Int

    static let instructions = """
    あなたは会話の記憶を整理します。これまでの記憶と追加の会話から、後で必要な情報を短い箇条書きにまとめます。
    利用者の好み・旅行先・趣味・合言葉・予定と待ち合わせ、明示的な訂正、未解決の質問を優先します。
    最新の利用者の訂正を採用し、古い値を現行の情報として残しません。AIの返答を利用者の事実と混同しません。
    雑談の細部は省略できます。明記されていないことを補いません。記憶だけを出力してください。
    """

    var prompt: String {
        "これまでの記憶:\n" + (previousSummary.isEmpty ? "なし" : previousSummary)
            + "\n追加の会話:\n"
            + evictedTurns.map { "利用者: \($0.prompt)\nAI: \($0.response)" }.joined(separator: "\n")
            + "\n更新後の記憶だけを\(characterLimit)文字以内で出力してください。"
    }
}

protocol ConversationSessionFactory: Sendable {
    func authenticateIfNeeded() async throws
    func makeReplySession(_ configuration: ConversationSessionConfiguration, tools: [any Tool]) async -> any ConversationSessionClient
    func summarize(_ request: ConversationSummaryRequest) async throws -> String
    func consolidateFacts(_ facts: [LongTermFact]) async throws -> [LongTermFact]
}
