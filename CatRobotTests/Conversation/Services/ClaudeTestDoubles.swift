import Foundation
import FoundationModels
@testable import CatRobot

actor StubSessionFactory: ConversationSessionFactory {
    struct SessionRecord: Sendable {
        let configuration: ConversationSessionConfiguration
        let tools: [any Tool]
        var toolNames: [String] { tools.map(\.name) }
    }
    private(set) var sessions: [SessionRecord] = []
    private(set) var summaryRequests: [ConversationSummaryRequest] = []
    private(set) var consolidations = 0
    private let scripts: [ScriptedSessionClient]
    private let summaries: [String]
    private let authenticationError: (any Error)?
    private let summaryError: (any Error)?

    init(scripts: [ScriptedSessionClient] = [ScriptedSessionClient(chunks: ["にゃ", "ん。"])],
         summaries: [String] = ["要約1", "要約2"],
         authenticationError: (any Error)? = nil, summaryError: (any Error)? = nil) {
        self.scripts = scripts
        self.summaries = summaries
        self.authenticationError = authenticationError
        self.summaryError = summaryError
    }

    func authenticateIfNeeded() async throws {
        if let authenticationError { throw authenticationError }
    }

    func makeReplySession(_ configuration: ConversationSessionConfiguration, tools: [any Tool]) async -> any ConversationSessionClient {
        sessions.append(.init(configuration: configuration, tools: tools))
        return scripts[min(sessions.count - 1, scripts.count - 1)]
    }

    func summarize(_ request: ConversationSummaryRequest) async throws -> String {
        summaryRequests.append(request)
        if let summaryError { throw summaryError }
        return summaries[min(summaryRequests.count - 1, summaries.count - 1)]
    }

    func consolidateFacts(_ facts: [LongTermFact]) async throws -> [LongTermFact] {
        consolidations += 1
        return Array(LongTermMemoryPolicy.ordered(facts).suffix(LongTermMemoryPolicy.maximumFacts / 2))
    }
}

/// chunks は差分。累積して snapshots を流す。nil なら yield/finish/fail まで開いたまま。
/// 変更可能な状態はすべて lock で保護する。
final class ScriptedSessionClient: ConversationSessionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [String]?
    private let failure: (any Error)?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var accumulated = ""
    private var storedPrompts: [String] = []
    private var prewarmCount = 0
    private var started = false
    var prompts: [String] { lock.withLock { storedPrompts } }
    var prewarms: Int { lock.withLock { prewarmCount } }

    init(chunks: [String]?, failure: (any Error)? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func prewarm() async { lock.withLock { prewarmCount += 1 } }

    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
                storedPrompts.append(prompt)
                accumulated = ""
                started = true
            }
            if let chunks {
                var text = ""
                for chunk in chunks {
                    text += chunk
                    continuation.yield(text)
                }
                continuation.finish(throwing: failure)
            }
        }
    }

    func yield(_ delta: String) {
        let (continuation, text) = lock.withLock {
            accumulated += delta
            return (self.continuation, accumulated)
        }
        continuation?.yield(text)
    }

    func finish() { lock.withLock { continuation }?.finish() }
    func fail(_ error: any Error) { lock.withLock { continuation }?.finish(throwing: error) }
    func waitUntilStarted() async { while !lock.withLock({ started }) { await Task.yield() } }
}
