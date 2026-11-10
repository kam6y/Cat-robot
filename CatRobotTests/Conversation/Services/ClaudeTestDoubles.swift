import Foundation
import FoundationModels
@testable import CatRobot

func makeClaudeService(_ factory: StubSessionFactory = StubSessionFactory(),
                       store: any ConversationMemoryStore = InMemoryConversationMemoryStore(),
                       budget: ConversationBudget = .default,
                       longTerm: LongTermMemoryManager? = nil,
                       tools: any ConversationToolProvider = StaticToolProvider([]),
                       configuration: @escaping @Sendable () async -> ConversationModelConfiguration = { .init() }) -> ClaudeConversationService {
    ClaudeConversationService(factory: factory, memoryStore: store,
                              longTermMemory: longTerm ?? LongTermMemoryManager(store: InMemoryLongTermMemoryStore()),
                              tools: tools, configuration: configuration, budget: budget)
}

enum ClarificationSummaryFixture {
    static let budget = ConversationBudget(compactionTriggerCharacters: 60, retainedCharacters: 45)
    static let original = ConversationMemoryTurn(prompt: "私はピーナッツアレルギーです", response: ClarificationContext.question)
    static let nextTurn = ConversationMemoryTurn(prompt: "次の話", response: "新しい返事。")

    static func retained(confirmation: String = "うん、私のこと") -> [ConversationMemoryTurn] {
        [.init(prompt: confirmation, response: "わかったよ。"),
         .init(prompt: String(repeating: "後", count: 30), response: String(repeating: "返", count: 6))]
    }

    static func snapshot(summary: String = "", confirmation: String = "うん、私のこと") -> ConversationMemorySnapshot {
        .init(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current, revision: 1, savedAt: Date(),
              summary: summary, turns: [original] + retained(confirmation: confirmation))
    }
}

/// clear() を gate で止められる長期メモの store。forget の途中（削除中）の状態を再現する。
actor GatedLongTermMemoryStore: LongTermMemoryStore {
    private var facts: [LongTermFact] = []
    private let clearGate: ConversationTestGate?
    private(set) var clearCount = 0
    init(clearGate: ConversationTestGate? = nil) { self.clearGate = clearGate }
    func load() -> [LongTermFact] { facts }
    func save(_ value: [LongTermFact]) { facts = value }
    func clear() async {
        clearCount += 1
        await clearGate?.wait()
        facts = []
    }
}

/// memory に関係なく固定の配列を返すテスト用のプロバイダー。
struct StaticToolProvider: ConversationToolProvider {
    private let items: [any Tool]
    init(_ items: [any Tool]) { self.items = items }
    func tools(memory: any LongTermMemoryWriting) -> [any Tool] { items }
}

actor StubSessionFactory: ConversationSessionFactory {
    struct SessionRecord: Sendable {
        let configuration: ConversationSessionConfiguration
        let tools: [any Tool]
        var toolNames: [String] { tools.map(\.name) }
    }
    private(set) var sessions: [SessionRecord] = []
    private(set) var summaryRequests: [ConversationSummaryRequest] = []
    private(set) var consolidations = 0
    /// セッション生成ごとに順に返す。足りなければ最後を使い回す。ScriptedSessionClient 以外（ゲート付きなど）も渡せる。
    private let scripts: [any ConversationSessionClient]
    private let summaries: [ConversationSummaryResult]
    private let authenticationError: (any Error)?
    private let summaryError: (any Error)?
    private let summaryGate: ConversationTestGate?

    init(scripts: [any ConversationSessionClient] = [ScriptedSessionClient(chunks: ["にゃ", "ん。"])],
         summaries: [ConversationSummaryResult] = [.text("要約1"), .text("要約2")],
         authenticationError: (any Error)? = nil, summaryError: (any Error)? = nil,
         summaryGate: ConversationTestGate? = nil) {
        self.scripts = scripts
        self.summaries = summaries
        self.authenticationError = authenticationError
        self.summaryError = summaryError
        self.summaryGate = summaryGate
    }

    func authenticateIfNeeded() async throws {
        if let authenticationError { throw authenticationError }
    }

    func makeReplySession(_ configuration: ConversationSessionConfiguration, tools: [any Tool]) async -> any ConversationSessionClient {
        sessions.append(.init(configuration: configuration, tools: tools))
        return scripts[min(sessions.count - 1, scripts.count - 1)]
    }

    func summarize(_ request: ConversationSummaryRequest) async throws -> ConversationSummaryResult {
        summaryRequests.append(request)
        await summaryGate?.wait()
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
