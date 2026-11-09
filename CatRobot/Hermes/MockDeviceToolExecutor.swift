#if DEBUG
import Foundation

struct MockDeviceToolExecutor: Sendable {
    enum Rejection: String, Sendable { case unknownTool, missingText, textTooLong }
    enum Result: Equatable, Sendable {
        case success(String)
        case rejected(Rejection)
    }

    func execute(tool: String, arguments: [String: String]) -> Result {
        guard tool == "echo" else { return .rejected(.unknownTool) }
        guard let text = arguments["text"] else { return .rejected(.missingText) }
        guard text.count <= 1_024 else { return .rejected(.textTooLong) }
        return .success(text)
    }
}
#endif
