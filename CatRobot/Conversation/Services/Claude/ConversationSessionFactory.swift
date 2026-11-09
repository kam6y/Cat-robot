import Foundation
import FoundationModels

struct ConversationSessionConfiguration: Equatable, Sendable {
    var model: ConversationModelChoice
    var effort: ConversationEffort
    var instructions: String
}

/// 返答モデルの最小の契約。prewarm と、prompt への累積スナップショットの列。
protocol ReplyModelClient: Sendable {
    func prewarm() async
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error>
}

/// ReplyModelClient の契約（prewarm と累積スナップショット。失敗は ConversationServiceError に写像して投げる）に、
/// 画像添付の有無の検査を加えたもの。
protocol ConversationSessionClient: ReplyModelClient {
    func containsImageAttachments() async -> Bool
}

extension ConversationSessionClient {
    func containsImageAttachments() async -> Bool { false }
}

struct ConversationSummaryRequest: Equatable, Sendable {
    var previousSummary: String
    var evictedTurns: [ConversationMemoryTurn]
    var referenceTurns: [ConversationMemoryTurn] = []
    var characterLimit: Int

    static let instructions = """
    あなたは会話の記憶を整理します。これまでの記憶と追加の会話から、後で必要な情報を短い箇条書きの項目にまとめます。
    これまでの記憶を引き継ぎ、更新後の記憶の全体を返します。残すものが何も無いときだけ空の配列にします。
    新しい項目は追加の会話からだけ作ります。解釈のための参考は、追加の会話への確認や訂正を読み取るためだけに使います。
    AIが「\(ClarificationContext.question)」と聞き返した発言は、利用者がAIに言ったと認めた場合だけ、AIへの質問や利用者の事実として扱います。否定された発言や確認されていない発言は、未解決の質問として残しません。
    この聞き返し対象について、元の発言をAI宛てと認める利用者の返事が、追加の会話にも参考にもなければ、確認されたとは見なしません。元の発言が自分の好みや「覚えて」の依頼でも、その内容を事実や質問の項目にしません。AIの聞き返し自体は利用者の肯定ではありません。
    ほかに残す内容がこれまでの記憶にもなければ、itemsを空配列にします。「未確認」「否定された」という説明だけで項目を作る必要はありません。
    利用者の好み・旅行先・趣味・合言葉・予定と待ち合わせ、明示的な訂正、未解決の質問を優先します。
    最新の利用者の訂正を採用し、古い値を現行の情報として残しません。AIの返答を利用者の事実と混同しません。
    雑談の細部は省略できます。明記されていないことを補いません。記憶だけを出力してください。
    """

    /// 参考の往復が無ければ従来の形式のまま。あれば追加の会話の後に、切り詰めずに別の節として渡す。
    var prompt: String {
        "これまでの記憶:\n" + (previousSummary.isEmpty ? "なし" : previousSummary)
            + "\n追加の会話:\n" + Self.render(evictedTurns)
            + (referenceTurns.isEmpty ? "" : "\n解釈のための参考（要約には含めない）:\n" + Self.render(referenceTurns))
            + "\n更新後の記憶だけを\(characterLimit)文字以内で出力してください。"
    }

    private static func render(_ turns: [ConversationMemoryTurn]) -> String {
        turns.map { "利用者: \($0.prompt)\nAI: \($0.response)" }.joined(separator: "\n")
    }
}

protocol ConversationSessionFactory: Sendable {
    func authenticateIfNeeded() async throws
    func makeReplySession(_ configuration: ConversationSessionConfiguration, tools: [any Tool]) async -> any ConversationSessionClient
    func summarize(_ request: ConversationSummaryRequest) async throws -> ConversationSummaryResult
    func consolidateFacts(_ facts: [LongTermFact]) async throws -> [LongTermFact]
}
