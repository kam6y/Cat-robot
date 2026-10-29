import FoundationModels

struct RememberTool: Tool {
    let name = "remember"
    let description = "利用者について今後も覚えておくべき事実を保存する。名前、好み、出来事、約束。利用者が『覚えて』と言ったとき、または今後の会話に必要な事実を聞いたときだけ使う。"

    @Generable
    struct Arguments {
        @Guide(description: "60文字以内の事実。誰のことかが分かる形で書く") var fact: String
        @Guide(description: "person, preference, event, promise, other のいずれか") var category: String
    }

    private let memory: any LongTermMemoryWriting
    init(memory: any LongTermMemoryWriting) { self.memory = memory }

    func call(arguments: Arguments) async throws -> String {
        return try await ReplyTraceContext.withTool(.remember) {
            let category = LongTermFactCategory(rawValue: arguments.category.lowercased()) ?? .other
            switch try await memory.remember(arguments.fact, category: category) {
            case .saved: return "覚えました: \(arguments.fact)"
            case .duplicate: return "すでに覚えています: \(arguments.fact)"
            case .rejected: return "この記憶は保存できませんでした（会話がリセットされました）: \(arguments.fact)"
            }
        }
    }
}
