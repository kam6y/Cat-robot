import Foundation
@testable import CatRobot

actor StubGemmaRuntime: GemmaRuntime {
    let reply: StubGemmaSession
    let classification: String
    let classifierSession: StubGemmaSession?
    let failure: GemmaRuntimeFailure?
    private(set) var kinds: [GemmaSessionKind] = []

    init(reply: StubGemmaSession = StubGemmaSession(chunks: ["にゃ", "ん。"]),
         classification: String = "addressed", failure: GemmaRuntimeFailure? = nil,
         classifierSession: StubGemmaSession? = nil) {
        self.reply = reply
        self.classification = classification
        self.classifierSession = classifierSession
        self.failure = failure
    }
    func prepare() async throws { if let failure { throw failure } }
    func countTokens(_ text: String) async throws -> Int { text.count }
    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        let kind = configuration.kind
        kinds.append(kind)
        return kind == .reply ? reply : (classifierSession ?? StubGemmaSession(chunks: [classification]))
    }
}

final class StubGemmaSession: GemmaSession, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [String]?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var storedPrompts: [String] = []
    private var started = false
    private var cancelled = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var prompts: [String] { lock.withLock { storedPrompts } }
    private let usedTokens: Int
    init(chunks: [String]?, usedTokens: Int = 100) {
        self.chunks = chunks
        self.usedTokens = usedTokens
    }
    func tokenCount() throws -> Int { usedTokens }
    func inputTokenCount(_ prompt: String) throws -> Int { prompt.count }
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    func close() { lock.withLock { closed = true } }
    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
                storedPrompts.append(prompt)
                started = true
            }
            if let chunks {
                chunks.forEach { continuation.yield($0) }
                continuation.finish()
            } else if prompts.count > 1 {
                continuation.yield("再開できた。")
                continuation.finish()
            }
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func finish() { lock.withLock { continuation }?.finish() }
    func waitUntilStarted() async { while !lock.withLock({ started }) { await Task.yield() } }
    func waitUntilCancelled() async { while !lock.withLock({ cancelled }) { await Task.yield() } }
}

/// Native inference is slow and unavailable in the simulator. This boundary fake
/// models lazy history replay and detects overlapping conversation lifetimes.
actor RecordingGemmaRuntime: GemmaRuntime {
    private(set) var configurations: [GemmaSessionConfiguration] = []
    private(set) var overlappedSessions = false
    private var sessions: [RecordingGemmaSession] = []
    private var summaries: [StubGemmaSession] = []
    private let summaryOutputs: [String]
    private let heldSummary: StubGemmaSession?
    private var failFirstRebuiltReply: Bool
    private let replyResponses: [[String]]
    private var replyCreations = 0
    var summaryPrompts: [String] { summaries.flatMap(\.prompts) }

    init(summaryOutputs: [String] = ["memory-1", "memory-2"], heldSummary: StubGemmaSession? = nil, failFirstRebuiltReply: Bool = false, replyResponses: [[String]] = [["R"]]) {
        self.summaryOutputs = summaryOutputs
        self.heldSummary = heldSummary
        self.failFirstRebuiltReply = failFirstRebuiltReply
        self.replyResponses = replyResponses
    }
    func prepare() async throws {}
    func countTokens(_ text: String) async throws -> Int { text.count }
    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        overlappedSessions = overlappedSessions || sessions.contains { !$0.isClosed } || summaries.contains { !$0.isClosed }
        configurations.append(configuration)
        if configuration.kind == .summary {
            let index = summaries.count
            let session = index == 0 ? (heldSummary ?? StubGemmaSession(chunks: [summaryOutputs[0]]))
                : StubGemmaSession(chunks: [summaryOutputs[min(index, summaryOutputs.count - 1)]])
            summaries.append(session)
            return session
        }
        let fails = failFirstRebuiltReply && !configuration.summary.isEmpty
        if fails { failFirstRebuiltReply = false }
        let responses = replyResponses[min(replyCreations, replyResponses.count - 1)]
        if configuration.kind == .reply { replyCreations += 1 }
        let session = RecordingGemmaSession(configuration: configuration, fails: fails, responses: responses)
        sessions.append(session)
        return session
    }
}

final class RecordingGemmaSession: GemmaSession, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: GemmaSessionConfiguration
    private var used = 0
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    private let fails: Bool
    private let responses: [String]
    private var sends = 0
    init(configuration: GemmaSessionConfiguration, fails: Bool, responses: [String]) {
        self.configuration = configuration
        self.fails = fails
        self.responses = responses
    }
    func tokenCount() throws -> Int { lock.withLock { used } }
    func inputTokenCount(_ prompt: String) throws -> Int {
        lock.withLock {
            let preface = used == 0 ? 100 + configuration.summary.count + configuration.history.reduce(0) { $0 + $1.rawTokens } : 0
            return preface + prompt.count + 10
        }
    }
    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        let pending = try! inputTokenCount(prompt)
        let response = lock.withLock {
            used += pending + 1
            let result = responses[min(sends, responses.count - 1)]
            sends += 1
            return result
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(configuration.kind == .classification ? "addressed" : response)
            continuation.finish(throwing: fails ? ConversationServiceError.modelGenerationFailed : nil)
        }
    }
    func cancel() {}
    func close() { lock.withLock { closed = true } }
}
