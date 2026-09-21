import Foundation

/// One runtime is shared by ephemeral address classification and a stateful reply session.
/// Native inference must drain after cancellation before a new operation can use the engine.
actor GemmaConversationService: ReplyGenerating, AddressClassifying, ModelAvailabilityChecking {
    private let runtime: any GemmaRuntime
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
        replySession = nil
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
        do {
            try await runtime.prepare()
            let session: any GemmaSession
            if kind == .reply, let existing = replySession {
                session = existing
            } else {
                session = try await runtime.makeSession(kind)
                if kind == .reply { replySession = session }
            }
            let outputLimit = kind == .reply ? 160 : 16
            // UTF-8 bytes upper-bound byte-fallback tokens. Reserve room for the
            // system prompt, turn delimiters and output rather than overrun 8K.
            guard try session.tokenCount() + prompt.utf8.count + outputLimit + kind.instruction.utf8.count + 128 <= 8192 else {
                throw ConversationServiceError.contextExceeded
            }
            let source = try control.start(session, prompt: prompt, outputLimit: outputLimit)
            var snapshot = ""
            for try await delta in source {
                if !control.isCancelled, !delta.isEmpty {
                    snapshot += delta
                    continuation.yield(snapshot)
                }
            }
            if control.isCancelled { throw CancellationError() }
            guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationServiceError.modelGenerationFailed
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
            // A partial/failed turn must not contaminate the next conversation.
            if kind == .reply { replySession = nil }
        }
        // Finalization arbitrates with cancellation atomically. A cancel after
        // the last chunk still invalidates LiteRT's conversation if it won.
        if control.finish() {
            failure = ConversationServiceError.cancelled
            if kind == .reply { replySession = nil }
        }
        cancellation = nil
        active = nil
        continuation.finish(throwing: failure)
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
