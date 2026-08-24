import Foundation
import FoundationModels

@Generable
struct ForgetMemoryArguments {
    var memoryIDs: [String]
    var supportingQuote: String
}

struct ForgetMemoryTool: Tool {
    let name = "forgetMemory"
    let description = "Stage deletion of specific memory IDs returned by searchMemory in this user turn. The supporting quote must be copied exactly from the current user message."

    private let context: MemoryToolContext
    private let budget: ReplyToolCallBudget

    init(context: MemoryToolContext, budget: ReplyToolCallBudget) {
        self.context = context
        self.budget = budget
    }

    func call(arguments: ForgetMemoryArguments) async throws -> String {
        try await budget.consumeCall()

        var memoryIDs: [UUID] = []
        for memoryID in arguments.memoryIDs {
            guard let uuid = UUID(uuidString: memoryID),
                  uuid.uuidString.lowercased() == memoryID.lowercased() else {
                return "Forget rejected: every memory ID must be a UUID."
            }
            memoryIDs.append(uuid)
        }

        return await context.stageForget(
            memoryIDs: memoryIDs,
            supportingQuote: arguments.supportingQuote
        )
    }
}
