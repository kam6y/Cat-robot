import Foundation

/// One runtime is shared by ephemeral address classification and a stateful reply session.
/// Native inference must drain after cancellation before a new operation can use the engine.
actor GemmaConversationService: ReplyGenerating, AddressClassifying, ModelAvailabilityChecking {
    private let runtime: any GemmaRuntime
    private var memory = GemmaConversationMemory()
    private var replySession: (any GemmaSession)?
    private var active: Task<Void, Never>?
    private var cancellation: GemmaInferenceCancellation?
    private var resetCount = 0

    init(runtime: any GemmaRuntime = LiteRTGemmaRuntime()) {
        self.runtime = runtime
    }

    func availability() async -> ModelAvailability {
        do {
            try await runtime.prepare()
            return .available
        } catch GemmaRuntimeFailure.missingModel {
            return .gemmaModelMissing
        } catch GemmaRuntimeFailure.invalidModel {
            return .gemmaModelInvalid
        } catch {
            return .gemmaUnavailable
        }
    }

    func prewarm() async {
        // The existing nonthrowing contract is retained. Availability and generation
        // report preparation failures through their existing error paths.
        try? await runtime.prepare()
    }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        await waitForCancelledInference()
        return try start(utterance, kind: .reply)
    }

    func classify(_ utterance: String) async throws -> AddressTarget {
        await waitForCancelledInference()
        let stream = try start(utterance, kind: .classification)
        var result = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            result = snapshot
        }
        try Task.checkCancellation()
        switch result.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "addressed": return .addressed
        case "notAddressed": return .notAddressed
        default: return .ambiguous
        }
    }

    func reset() async {
        resetCount += 1
        cancellation?.cancel()
        await active?.value
        closeReplySession()
        memory = GemmaConversationMemory()
        resetCount -= 1
    }

    private func waitForCancelledInference() async {
        // UI cleanup waits for its stream consumer, which can finish before the
        // native callback drains. A user resuming immediately joins that drain.
        if cancellation?.isCancelled == true { await active?.value }
    }

    private func start(_ prompt: String, kind: GemmaSessionKind) throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        guard active == nil, resetCount == 0 else { throw ConversationServiceError.modelBusy }
        let control = GemmaInferenceCancellation()
        cancellation = control
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { control.cancel() }
        }
        // Do not cancel this worker: it must consume the native terminal callback,
        // retaining the session and engine until the GPU operation has ended.
        active = Task { await self.generate(prompt, kind: kind, control: control, into: continuation) }
        return stream
    }

    private func generate(
        _ prompt: String, kind: GemmaSessionKind, control: GemmaInferenceCancellation,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var failure: Error?
        var candidate = memory
        do {
            try await runtime.prepare()
            try checkCancellation(control)
            if kind == .reply {
                let promptTokens = try await runtime.countTokens(prompt)
                // Reject impossible inputs before spending time on a summary.
                guard promptTokens + GemmaContext.replyOutputLimit + GemmaContext.safetyMargin < GemmaContext.capacity else {
                    throw ConversationServiceError.inputTooLong
                }
                if candidate.rawTokens >= GemmaContext.compactionTrigger, candidate.retentionStart > 0 {
                    candidate = try await compact(candidate, control: control)
                }
                var session = try await replySession(for: candidate)
                // Many short turns can fill the native template budget before raw
                // text reaches 8K. Compact early in that case rather than overflow.
                if try !fits(session, prompt: prompt, limit: GemmaContext.replyOutputLimit), candidate.retentionStart > 0 {
                    candidate = try await compact(candidate, control: control)
                    session = try await replySession(for: candidate)
                }
                let response: String
                do {
                    response = try await consume(session, prompt: prompt, limit: GemmaContext.replyOutputLimit,
                                                 control: control, into: continuation)
                } catch GemmaGenerationFailure.emptyResponse {
                    // A long-lived native session can return no text. A single
                    // replay from committed memory recovered this on device.
                    // Never retry errors, partial visible answers, or cancellation.
                    closeReplySession()
                    try checkCancellation(control)
                    let rebuilt = try await replySession(for: candidate)
                    response = try await consume(rebuilt, prompt: prompt, limit: GemmaContext.replyOutputLimit,
                                                 control: control, into: continuation)
                }
                let responseTokens = try await runtime.countTokens(response)
                candidate.turns.append(GemmaTurn(prompt: prompt, response: response, rawTokens: promptTokens + responseTokens))
            } else {
                // LiteRT's GPU session switching can restore stale KV state when
                // several conversations remain alive. Rebuild replies from memory.
                closeReplySession()
                let classifier = try await runtime.makeSession(GemmaSessionConfiguration(kind: .classification))
                defer { classifier.close() }
                _ = try await consume(classifier, prompt: prompt, limit: GemmaContext.classificationOutputLimit,
                                      control: control, into: continuation)
            }
        } catch {
            if control.isCancelled || error is CancellationError {
                failure = ConversationServiceError.cancelled
            } else if let error = error as? ConversationServiceError {
                failure = error
            } else if error is GemmaRuntimeFailure {
                failure = ConversationServiceError.modelAssetsUnavailable
            } else {
                failure = ConversationServiceError.modelGenerationFailed
            }
        }
        // Publish both compaction and the new turn only if success wins the
        // cancellation race. A retry can reconstruct the original committed memory.
        if control.finish() { failure = ConversationServiceError.cancelled }
        if kind == .reply {
            if failure == nil { memory = candidate }
            else { closeReplySession() }
        }
        cancellation = nil
        active = nil
        continuation.finish(throwing: failure)
    }

    private func replySession(for memory: GemmaConversationMemory) async throws -> any GemmaSession {
        if let replySession { return replySession }
        let session = try await runtime.makeSession(GemmaSessionConfiguration(kind: .reply, summary: memory.summary, history: memory.turns))
        replySession = session
        return session
    }

    private func closeReplySession() {
        replySession?.close()
        replySession = nil
    }

    private func compact(_ original: GemmaConversationMemory, control: GemmaInferenceCancellation) async throws -> GemmaConversationMemory {
        try checkCancellation(control)
        let keepFrom = original.retentionStart
        guard keepFrom > 0 else { return original }
        let evicted = original.turns[..<keepFrom]
        let prompt = "これまでの記憶:\n" + (original.summary.isEmpty ? "なし" : original.summary)
            + "\n追加の会話:\n"
            + evicted.map { "利用者: \($0.prompt)\nAI: \($0.response)" }.joined(separator: "\n")
            + "\n更新後の記憶だけを短く出力してください。"
        closeReplySession()
        let summarizer = try await runtime.makeSession(GemmaSessionConfiguration(kind: .summary))
        defer { summarizer.close() }
        // Summary failure is recoverable. Do not route it through the UI's
        // contextExceeded reset, which would discard the original conversation.
        guard try fits(summarizer, prompt: prompt, limit: GemmaContext.summaryOutputLimit) else {
            throw ConversationServiceError.modelGenerationFailed
        }
        let summary = try await consume(summarizer, prompt: prompt, limit: GemmaContext.summaryOutputLimit, control: control)
        guard try await runtime.countTokens(summary) <= GemmaContext.summaryOutputLimit else {
            throw ConversationServiceError.modelGenerationFailed
        }
        return GemmaConversationMemory(summary: summary, turns: Array(original.turns[keepFrom...]))
    }

    private func fits(_ session: any GemmaSession, prompt: String, limit: Int) throws -> Bool {
        try session.tokenCount() + session.inputTokenCount(prompt) + limit + GemmaContext.safetyMargin < GemmaContext.capacity
    }

    private func consume(
        _ session: any GemmaSession, prompt: String, limit: Int, control: GemmaInferenceCancellation,
        into continuation: AsyncThrowingStream<String, Error>.Continuation? = nil
    ) async throws -> String {
        try checkCancellation(control)
        guard try fits(session, prompt: prompt, limit: limit) else { throw ConversationServiceError.inputTooLong }
        let source = try control.start(session, prompt: prompt, outputLimit: limit)
        defer { control.detach() }
        var snapshot = ""
        for try await delta in source {
            if !control.isCancelled, !delta.isEmpty {
                snapshot += delta
                continuation?.yield(snapshot)
            }
        }
        try checkCancellation(control)
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GemmaGenerationFailure.emptyResponse
        }
        return snapshot
    }

    private func checkCancellation(_ control: GemmaInferenceCancellation) throws {
        if control.isCancelled { throw CancellationError() }
    }

}

/// Cancellation can arrive from the stream consumer on any executor. Starting
/// native generation and binding its cancellation target happen under one lock.
final class GemmaInferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any GemmaSession)?
    private var cancelled = false
    private var finished = false
    var isCancelled: Bool { lock.withLock { cancelled } }

    func start(_ session: any GemmaSession, prompt: String, outputLimit: Int) throws -> AsyncThrowingStream<String, Error> {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            self.session = session
            return session.stream(prompt, outputLimit: outputLimit)
        }
    }

    // Called only after a sub-operation has drained, before closing its session.
    func detach() { lock.withLock { session = nil } }

    func cancel() {
        lock.withLock {
            guard !finished, !cancelled else { return }
            cancelled = true
            session?.cancel()
        }
    }

    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            finished = true
            session = nil
            return cancelled
        }
    }
}

private enum GemmaGenerationFailure: Error { case emptyResponse }

private struct GemmaConversationMemory {
    var summary = ""
    var turns: [GemmaTurn] = []
    var rawTokens: Int { turns.reduce(0) { $0 + $1.rawTokens } }

    /// Retain at least 2K of raw text, rounding up to complete user/AI turns.
    var retentionStart: Int {
        var index = turns.count
        var retained = 0
        while index > 0, retained < GemmaContext.recentMinimum {
            index -= 1
            retained += turns[index].rawTokens
        }
        return index
    }
}
