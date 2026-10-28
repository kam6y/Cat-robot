import Foundation

enum FaceExpression: String, CaseIterable, Sendable {
    case neutral, happy, curious, thinking, listening, speaking, sleepy, surprised, sorry, sleeping

    /// express ツール（LLM）が予約できる表情。sleeping は無活動の待機状態が表示するもので、ここには含めない。
    static let expressible: [Self] = allCases.filter { $0 != .sleeping }

    static func normalized(_ raw: String) -> Self {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return expressible.first { $0.rawValue == name } ?? .neutral
    }

    static func automatic(for phase: ConversationPhase) -> Self {
        switch phase {
        case .idle, .paused: .neutral
        case .preparing, .classifying, .thinking: .thinking
        case .listening: .listening
        case .clarifying: .curious
        case .speaking: .speaking
        case .failed: .sorry
        }
    }
}
