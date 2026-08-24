import FoundationModels

@Generable
struct RememberMemoryArguments {
    var fact: String
    var supportingQuote: String
}

struct RememberMemoryTool: Tool {
    let name = "rememberMemory"
    let description = "Stage one concise, user-provided fact that will be useful in future conversations. The supporting quote must be copied exactly from the current user message."

    private let context: MemoryToolContext
    private let budget: ReplyToolCallBudget

    init(context: MemoryToolContext, budget: ReplyToolCallBudget) {
        self.context = context
        self.budget = budget
    }

    func call(arguments: RememberMemoryArguments) async throws -> String {
        try await budget.consumeCall()
        return await context.stageRemember(
            fact: arguments.fact,
            supportingQuote: arguments.supportingQuote
        )
    }
}
