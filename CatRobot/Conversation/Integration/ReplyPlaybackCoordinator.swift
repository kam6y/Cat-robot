import Foundation

enum ReplyPlaybackMode: String, Codable, Sendable { case completeResponse, firstSentence }
enum ReplyPlaybackUpdate: Sendable {
    case caption(String)
    case speechStarted(ReplySpeechPart, ReplySpeechStartSource)
    case willSpeak(ReplySpeechPart, Range<Int>)
    case speechFinished(ReplySpeechPart)
}

/// One owned operation joins generation and serial playback before returning.
/// Cancellation never resets the reply service or rolls back committed memory.
@MainActor
final class ReplyPlaybackCoordinator {
    private struct Part: Sendable { let kind: ReplySpeechPart; let text: String }
    private struct Failure: Error { let underlying: any Error; let outcome: ReplyTraceOutcome }
    private let reply: any ReplyGenerating
    private let speaker: any SpeechSpeaking
    private let mode: ReplyPlaybackMode
    private var active: (id: UUID, task: Task<String, Error>)?

    init(reply: any ReplyGenerating, speaker: any SpeechSpeaking, mode: ReplyPlaybackMode) {
        self.reply = reply; self.speaker = speaker; self.mode = mode
    }

    func run(prompt: String, trace: ReplyTrace?,
             onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        guard active == nil else { throw ConversationServiceError.modelBusy }
        guard !Task.isCancelled else {
            trace?.finish(.cancelled)
            throw ConversationServiceError.cancelled
        }
        let id = UUID()
        let task = Task {
            try await ReplyTraceContext.$current.withValue(trace) {
                try await self.perform(prompt: prompt, trace: trace, onUpdate: onUpdate)
            }
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func cancelAndWait() async {
        guard let operation = active else { return }
        operation.task.cancel()
        // perform's single cleanup path stops the speaker and joins both children.
        _ = await operation.task.result
        if active?.id == operation.id { active = nil }
    }

    private func perform(prompt: String, trace: ReplyTrace?,
                         onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        let parts = AsyncThrowingStream<Part, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        trace?.mark(.request)
        do {
            let result = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    do {
                        return try await self.produce(prompt: prompt, into: parts.continuation,
                                                      trace: trace, onUpdate: onUpdate)
                    } catch { throw Failure(underlying: error, outcome: .generationFailure) }
                }
                group.addTask {
                    do {
                        try await self.play(parts.stream, trace: trace, onUpdate: onUpdate)
                        return nil
                    } catch { throw Failure(underlying: error, outcome: .speechFailure) }
                }
                do {
                    var final = ""
                    while let value = try await group.next() {
                        if let value { final = value }
                    }
                    try Task.checkCancellation()
                    return final
                } catch {
                    // Keep the first meaningful error. Sibling cancellation must
                    // not replace a synthesis failure with a generation error.
                    group.cancelAll()
                    parts.continuation.finish()
                    await speaker.stop()
                    while await group.nextResult() != nil {}
                    throw error
                }
            }
            trace?.finish(.success)
            return result
        } catch {
            if Task.isCancelled {
                trace?.finish(.cancelled)
                throw ConversationServiceError.cancelled
            }
            if let failure = error as? Failure {
                let cancelled = failure.underlying is CancellationError
                    || failure.underlying as? ConversationServiceError == .cancelled
                trace?.finish(cancelled ? .cancelled : failure.outcome)
                if cancelled { throw ConversationServiceError.cancelled }
                if let serviceError = failure.underlying as? ConversationServiceError { throw serviceError }
                throw failure.outcome == .speechFailure
                    ? ConversationServiceError.speechSynthesisFailed : .modelGenerationFailed
            }
            trace?.finish(.generationFailure)
            throw error
        }
    }

    private func produce(prompt: String, into parts: AsyncThrowingStream<Part, Error>.Continuation,
                         trace: ReplyTrace?,
                         onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        let stream = try await reply.streamReply(to: prompt)
        var buffer = ReplySentenceBuffer()
        var final = ""
        var sentFirst = false
        let early = mode == .firstSentence && reply.supportsStableReplyPrefix
        for try await snapshot in stream {
            try Task.checkCancellation()
            if early, let first = try buffer.receive(snapshot) {
                trace?.mark(.firstSentence)
                parts.yield(Part(kind: .first, text: first))
                sentFirst = true
            }
            final = snapshot
            onUpdate(.caption(snapshot))
            if !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trace?.mark(.firstCaption) }
        }
        try Task.checkCancellation()
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationServiceError.modelGenerationFailed
        }
        trace?.mark(.streamFinished, outcome: .success)
        let remainder = early ? try buffer.remainder(in: final) : final
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.yield(Part(kind: sentFirst ? .remainder : .full, text: remainder))
        }
        parts.finish()
        return final
    }

    private func play(_ parts: AsyncThrowingStream<Part, Error>, trace: ReplyTrace?,
                      onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws {
        for try await part in parts {
            try Task.checkCancellation()
            trace?.mark(.speechEnqueued, part: part.kind)
            let events = try await speaker.speak(part.text)
            var started = false
            var finished = false
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .started, .willSpeak:
                    guard !finished else { continue }
                    if !started {
                        let source: ReplySpeechStartSource = event == .started ? .started : .willSpeakFallback
                        started = true
                        trace?.mark(.speechStarted, part: part.kind, source: source)
                        onUpdate(.speechStarted(part.kind, source))
                    }
                    if case .willSpeak(let range) = event { onUpdate(.willSpeak(part.kind, range)) }
                case .finished:
                    if !finished {
                        finished = true
                        trace?.mark(.speechFinished, part: part.kind)
                        onUpdate(.speechFinished(part.kind))
                    }
                case .cancelled: throw ConversationServiceError.speechSynthesisFailed
                }
            }
            try Task.checkCancellation()
            guard finished else { throw ConversationServiceError.speechSynthesisFailed }
        }
        try Task.checkCancellation()
    }
}
