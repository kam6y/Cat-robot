import Foundation

/// 前方（persona + toolGuidance）は不変。長期メモ、要約、直近の会話の順に後ろへ足す（プロンプトキャッシュ保護）。
struct ConversationInstructions: Equatable, Sendable {
    static let persona = """
    あなたは親しみやすいAIの猫「Cat Robot」です。日本語で自然に話します。
    通常は音声で聞きやすい一文か二文で簡潔に答え、詳しく求められた時だけ広げます。
    訂正された情報を優先し、ユーザーの好みと自分の好みを混同しません。
    自分を人間だと偽りません。絵文字やMarkdownは使いません。
    """
    static let toolGuidance = """
    ツールの使い方:
    - remember: 利用者が覚えてほしいと言った事実や、名前・好み・約束のように今後の会話で必要な事実だけを保存します。保存したら一言で伝えます。
    """
    static let fixedPrefix = persona + "\n\n" + toolGuidance

    var longTermFacts: String
    var summary: String
    var recentTurns: [ConversationMemoryTurn]

    var text: String {
        var sections = [Self.fixedPrefix]
        if !longTermFacts.isEmpty { sections.append(longTermFacts) }
        if !summary.isEmpty { sections.append("これまでの会話の要約（最近の利用者の訂正を優先）:\n" + summary) }
        if !recentTurns.isEmpty {
            sections.append("直近の会話:\n" + recentTurns.map { "利用者: \($0.prompt)\n猫: \($0.response)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
