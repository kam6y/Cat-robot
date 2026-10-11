import ClaudeForFoundationModels
import Foundation
import FoundationModels

struct ClaudeSessionFactory: ConversationSessionFactory {
    static let replyTimeout: TimeInterval = 30
    static let maximumResponseTokens = 600
    private let auth: ClaudeAuthConfiguration

    init(auth: ClaudeAuthConfiguration) { self.auth = auth }

    static func claudeModel(for choice: ConversationModelChoice) -> ClaudeModel {
        switch choice {
        case .opus5_5: .opus5_5
        case .sonnet5_5: .sonnet5_5
        case .haiku5_5: .haiku5_5
        }
    }

    static func claudeEffort(for effort: ConversationEffort) -> ClaudeModel.Effort {
        switch effort {
        case .low: .low
        case .medium: .medium
        }
    }

    private func languageModel(_ choice: ConversationModelChoice, effort: ConversationEffort) throws -> ClaudeLanguageModel {
        guard let mode = auth.authMode else { throw ClaudeError.missingCredential }
        // fallbacks は使わない（Global Constraints）。既定値に頼らず空を明示する。
        return ClaudeLanguageModel(name: Self.claudeModel(for: choice), auth: mode,
                                   fixedEffort: Self.claudeEffort(for: effort), fallbacks: [],
                                   timeout: Self.replyTimeout)
    }

    func authenticateIfNeeded() async throws {
        try await languageModel(.haiku5_5, effort: .low).authenticateIfNeeded()
    }

    func makeReplySession(_ configuration: ConversationSessionConfiguration, tools: [any Tool]) async -> any ConversationSessionClient {
        do {
            let model = try languageModel(configuration.model, effort: configuration.effort)
            let session = LanguageModelSession(model: model, tools: tools,
                                               instructions: Instructions(configuration.instructions))
            return LiveClaudeSessionClient(session: session)
        } catch {
            return FailingSessionClient(error: error)
        }
    }

    func summarize(_ request: ConversationSummaryRequest) async throws -> String {
        let session = LanguageModelSession(model: try languageModel(.haiku5_5, effort: .low),
                                           instructions: Instructions(ConversationSummaryRequest.instructions))
        let response = try await session.respond(to: request.prompt,
                                                 options: GenerationOptions(maximumResponseTokens: request.characterLimit * 2))
        let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= request.characterLimit else { throw ConversationServiceError.modelGenerationFailed }
        return summary
    }

    func consolidateFacts(_ facts: [LongTermFact]) async throws -> [LongTermFact] {
        let session = LanguageModelSession(model: try languageModel(.haiku5_5, effort: .low),
                                           instructions: Instructions(ConsolidatedFacts.instructions))
        let response = try await session.respond(to: LongTermMemoryPolicy.render(facts), generating: ConsolidatedFacts.self)
        let now = Date()
        return response.content.facts.prefix(LongTermMemoryPolicy.maximumFacts).map {
            LongTermFact(id: UUID(), category: LongTermFactCategory(rawValue: $0.category) ?? .other,
                         text: String($0.text.prefix(LongTermMemoryPolicy.maximumFactLength)), createdAt: now)
        }
    }
}

@Generable
struct ConsolidatedFacts: Sendable {
    static let instructions = """
    覚えている事実の一覧を、重複をまとめ、古い値より新しい訂正を優先して統合します。各事実は60文字以内。
    category は person, preference, event, promise, other のいずれか。事実以外は出力しません。
    """
    @Guide(description: "統合後の事実") var facts: [ConsolidatedFact]
}

@Generable
struct ConsolidatedFact: Sendable {
    @Guide(description: "person, preference, event, promise, other のいずれか") var category: String
    @Guide(description: "60文字以内の事実") var text: String
}

/// LanguageModelSession は Sendable。変更可能な共有状態を増やさず、不変の参照だけを保持する。
private final class LiveClaudeSessionClient: ConversationSessionClient {
    private let session: LanguageModelSession
    init(session: LanguageModelSession) { self.session = session }

    func prewarm() async { session.prewarm() }

    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [session] in
                do {
                    let stream = session.streamResponse(
                        to: prompt, options: GenerationOptions(maximumResponseTokens: ClaudeSessionFactory.maximumResponseTokens))
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ClaudeErrorMapper.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct FailingSessionClient: ConversationSessionClient {
    let error: any Error
    func prewarm() async {}
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: ClaudeErrorMapper.map(error)) }
    }
}
