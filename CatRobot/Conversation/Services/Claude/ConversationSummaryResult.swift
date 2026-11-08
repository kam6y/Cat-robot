import Foundation
import FoundationModels

/// 要約の結果。「残すものが無い」という正常な結果を、生成の失敗（空の文字列など）と区別する。
enum ConversationSummaryResult: Equatable, Sendable {
    case noContent
    case text(String)

    /// 保存する要約を返す。noContent は前回の要約を消さずにそのまま引き継ぐ（無ければ空の要約）。
    /// 不正な結果と上限を超える要約は、既存どおり modelGenerationFailed。
    func validatedText(previousSummary: String, characterLimit: Int) throws -> String {
        switch self {
        case .noContent:
            guard previousSummary.count <= characterLimit else { throw ConversationServiceError.modelGenerationFailed }
            return previousSummary
        case .text(let text):
            return try Self.validatedSummary(text, characterLimit: characterLimit)
        }
    }

    static func validatedSummary(_ text: String, characterLimit: Int) throws -> String {
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= characterLimit else {
            throw ConversationServiceError.modelGenerationFailed
        }
        return summary
    }
}

@Generable
struct GeneratedConversationSummary: Sendable {
    @Guide(description: "残す事実や会話の要点。残すものが無ければ空配列")
    var items: [String]

    /// 空配列だけを noContent とする。空の項目は不正な出力として拒否し、箇条書きにした全体の文字数を検査する。
    func result(characterLimit: Int) throws -> ConversationSummaryResult {
        guard !items.isEmpty else { return .noContent }
        let lines = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !lines.contains(where: \.isEmpty) else { throw ConversationServiceError.modelGenerationFailed }
        let summary = try ConversationSummaryResult.validatedSummary(
            lines.map { "- " + $0 }.joined(separator: "\n"), characterLimit: characterLimit)
        return .text(summary)
    }
}
