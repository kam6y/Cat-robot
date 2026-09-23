import Foundation

/// One runtime is shared by ephemeral address classification and a stateful reply session.
/// Native inference must drain after cancellation before a new operation can use the engine.
actor GemmaConversationService: ReplyGenerating, AddressClassifying, ModelAvailabilityChecking, ConversationMemoryManaging {
    private let runtime: any GemmaRuntime
    private var memory = GemmaConversationMemory()
    private var replySession: (any GemmaSession)?
    private var active: Task<Void, Never>?
    private var cancellation: GemmaInferenceCancellation?
    private let memoryStore: any ConversationMemoryStore
    private let compatibilityID: String
    private var persistenceState: ConversationMemoryState = .unprepared
    private var subscribers: [UUID: AsyncStream<ConversationMemoryState>.Continuation] = [:]
    private var prepared = false
    private var revision: UInt64 = 0
    private var operationEpoch: UInt64 = 0
    private var preparation: Task<Void, Error>?
    private var saveRetry: Task<Void, Error>?
    private var forgetting: Task<Void, Error>?

    init(runtime: any GemmaRuntime = LiteRTGemmaRuntime(),
         memoryStore: any ConversationMemoryStore = InMemoryConversationMemoryStore(),
         compatibilityID: String = GemmaMemoryCompatibility.current) {
        self.runtime = runtime
        self.memoryStore = memoryStore
        self.compatibilityID = compatibilityID
    }

    func memoryState() -> ConversationMemoryState { persistenceState }

    func memoryUpdates() -> AsyncStream<ConversationMemoryState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConversationMemoryState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(persistenceState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
    private func publishMemory(_ state: ConversationMemoryState) {
        persistenceState = state
        for subscriber in subscribers.values { subscriber.yield(state) }
    }

    func prepareMemory() async throws {
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        if case .forgetFailed = persistenceState { throw ConversationMemoryError.unavailable }
        if prepared { return }
        if case .restoreFailed(let error) = persistenceState { throw error }
        if let preparation { try await preparation.value; return }
        let epoch = operationEpoch
        publishMemory(.loading)
        let task = Task { try await self.restoreMemory(epoch: epoch) }
        preparation = task
        try await task.value
    }

    private func restoreMemory(epoch: UInt64) async throws {
        defer { if operationEpoch == epoch { preparation = nil } }
        do {
            let snapshot = try await memoryStore.load()
            var restored = GemmaConversationMemory()
            if let snapshot {
                try snapshot.validate(expectedCompatibilityID: compatibilityID)
                try await runtime.prepare()
                guard try await runtime.countTokens(snapshot.summary) <= GemmaContext.summaryOutputLimit else {
                    throw ConversationMemoryError.invalidData
                }
                restored.summary = snapshot.summary
                for turn in snapshot.turns {
                    let prompt = try await runtime.countTokens(turn.prompt)
                    let response = try await runtime.countTokens(turn.response)
                    restored.turns.append(GemmaTurn(prompt: turn.prompt, response: turn.response, rawTokens: prompt + response))
                }
            }
            guard operationEpoch == epoch, forgetting == nil else { throw CancellationError() }
            memory = restored
            revision = snapshot?.revision ?? 0
            prepared = true
            publishMemory(.ready)
        } catch {
            guard operationEpoch == epoch, forgetting == nil else { throw CancellationError() }
            let issue = error as? ConversationMemoryError ?? .readFailed
            publishMemory(.restoreFailed(issue))
            throw issue
        }
    }

    private func snapshot() -> ConversationMemorySnapshot {
        ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: compatibilityID,
            revision: revision, savedAt: Date(), summary: memory.summary,
            turns: memory.turns.map { .init(prompt: $0.prompt, response: $0.response) })
    }

    private func saveMemory(epoch: UInt64) async throws {
        let value = snapshot()
        publishMemory(.saving)
        do {
            try await memoryStore.save(value)
            if operationEpoch == epoch { publishMemory(.ready) }
        } catch {
            if operationEpoch == epoch { publishMemory(.unsaved) }
            throw error
        }
    }

    func retryMemoryOperation() async throws {
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        if let saveRetry { try await saveRetry.value; return }
        guard active == nil, preparation == nil else { throw ConversationServiceError.modelBusy }
        switch persistenceState {
        case .unsaved:
            let epoch = operationEpoch
            let task = Task { try await self.saveMemory(epoch: epoch) }
            saveRetry = task
            defer { saveRetry = nil }
            try await task.value
        case .restoreFailed:
            publishMemory(.unprepared)
            try await prepareMemory()
        case .forgetFailed:
            try await forgetConversation()
        default: break
        }
    }

    func forgetConversation() async throws {
        if let forgetting { try await forgetting.value; return }
        operationEpoch &+= 1
        publishMemory(.forgetting)
        cancellation?.cancel()
        let oldActive = active
        let oldPreparation = preparation
        let oldRetry = saveRetry
        let task = Task {
            await oldActive?.value
            _ = try? await oldPreparation?.value
            _ = try? await oldRetry?.value
            self.preparation = nil
            self.saveRetry = nil
            do {
                try await self.memoryStore.clear()
                self.closeReplySession()
                self.memory = GemmaConversationMemory()
                self.revision = 0
                self.prepared = true
                self.publishMemory(.ready)
            } catch {
                self.publishMemory(.forgetFailed(.deleteFailed))
                throw ConversationMemoryError.deleteFailed
            }
        }
        forgetting = task
        defer { forgetting = nil }
        try await task.value
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
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        let epoch = operationEpoch
        await waitForCancelledInference()
        try await prepareMemory()
        guard operationEpoch == epoch else { throw ConversationServiceError.cancelled }
        return try start(utterance, kind: .reply)
    }

    func classify(_ utterance: String) async throws -> AddressTarget {
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        let epoch = operationEpoch
        await waitForCancelledInference()
        try await prepareMemory()
        guard operationEpoch == epoch else { throw ConversationServiceError.cancelled }
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
        // Failure remains observable and blocks new replies until deletion succeeds.
        try? await forgetConversation()
    }

    private func waitForCancelledInference() async {
        // UI cleanup waits for its stream consumer, which can finish before the
        // native callback drains. A user resuming immediately joins that drain.
        if cancellation?.isCancelled == true || persistenceState == .saving { await active?.value }
    }

    private func start(_ prompt: String, kind: GemmaSessionKind) throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        guard active == nil, forgetting == nil, saveRetry == nil else { throw ConversationServiceError.modelBusy }
        if case .forgetFailed = persistenceState { throw ConversationMemoryError.unavailable }
        let epoch = operationEpoch
        let control = GemmaInferenceCancellation()
        cancellation = control
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { control.cancel() }
        }
        // Do not cancel this worker: it must consume the native terminal callback,
        // retaining the session and engine until the GPU operation has ended.
        active = Task { await self.generate(prompt, kind: kind, control: control, epoch: epoch, into: continuation) }
        return stream
    }

    private func generate(
        _ prompt: String, kind: GemmaSessionKind, control: GemmaInferenceCancellation, epoch: UInt64,
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
        if control.finish() || epoch != operationEpoch { failure = ConversationServiceError.cancelled }
        if kind == .reply {
            if failure == nil {
                memory = candidate
                revision &+= 1
                // Saving is part of the owned turn even if the stream consumer
                // leaves after generation's commit point. Save errors are warnings.
                try? await saveMemory(epoch: epoch)
            }
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
