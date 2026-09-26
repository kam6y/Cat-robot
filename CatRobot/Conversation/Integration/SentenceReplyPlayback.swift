import Foundation

@MainActor
final class SentenceReplyPlayback {
    private struct Failure: Error { let error: Error; let outcome: ReplyTraceOutcome }
    private let reply: any ReplyGenerating
    private let speaker: any SentenceSpeechSpeaking
    private let prefetch: Bool
    init(reply: any ReplyGenerating, speaker: any SentenceSpeechSpeaking, prefetch: Bool) {
        self.reply = reply; self.speaker = speaker; self.prefetch = prefetch
    }
    func run(prompt: String, trace: ReplyTrace?, onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        let channel = SpeechSentenceChannel()
        // These are cumulative snapshots, not sentences: replacing an unread
        // snapshot retains its text in the newer one. Observe upstream failure
        // independently of the bounded sentence queue's playback backpressure.
        let snapshots = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        trace?.mark(.request)
        do {
            let final = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    do { return try await self.produce(prompt, snapshots.continuation, trace, onUpdate) }
                    catch { throw Failure(error: error, outcome: .generationFailure) }
                }
                group.addTask {
                    do { try await self.enqueue(snapshots.stream, channel, trace); return nil }
                    catch { throw Failure(error: error, outcome: .generationFailure) }
                }
                group.addTask {
                    do { try await self.play(channel, trace, onUpdate); return nil }
                    catch { throw Failure(error: error, outcome: .speechFailure) }
                }
                do {
                    var final = ""
                    while let value = try await group.next() { if let value { final = value } }
                    try Task.checkCancellation()
                    return final
                } catch {
                    group.cancelAll()
                    await channel.finish(throwing: error)
                    await speaker.stop()
                    while await group.nextResult() != nil {}
                    throw error
                }
            }
            trace?.finish(.success)
            return final
        } catch {
            let failure = error as? Failure
            let underlying = failure?.error ?? error
            if Task.isCancelled || underlying is CancellationError || underlying as? ConversationServiceError == .cancelled {
                trace?.finish(.cancelled); throw ConversationServiceError.cancelled
            }
            trace?.finish(failure?.outcome ?? .generationFailure)
            if let serviceError = underlying as? ConversationServiceError { throw serviceError }
            throw failure?.outcome == .speechFailure ? ConversationServiceError.speechSynthesisFailed : .modelGenerationFailed
        }
    }
    private func produce(_ prompt: String, _ snapshots: AsyncStream<String>.Continuation, _ trace: ReplyTrace?,
                         _ onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        defer { snapshots.finish() }
        let stream = try await reply.streamReply(to: prompt)
        var final = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            // Keep the latest cumulative snapshot bounded even if playback stalls.
            guard snapshot.count <= 2000 else { throw ConversationServiceError.inputTooLong }
            final = snapshot
            onUpdate(.caption(snapshot))
            if !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trace?.mark(.firstCaption) }
            snapshots.yield(snapshot)
        }
        try Task.checkCancellation()
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversationServiceError.modelGenerationFailed }
        trace?.mark(.streamFinished, outcome: .success)
        return final
    }
    private func enqueue(_ snapshots: AsyncStream<String>, _ channel: SpeechSentenceChannel, _ trace: ReplyTrace?) async throws {
        var buffer = ReplySentenceStreamBuffer()
        var final = ""
        for await snapshot in snapshots {
            try Task.checkCancellation()
            final = snapshot
            if reply.supportsStableReplyPrefix {
                for sentence in try buffer.receive(snapshot) {
                    trace?.mark(.firstSentence)
                    trace?.mark(.speechEnqueued, part: sentence.ordinal == 0 ? .first : .remainder, sentenceOrdinal: sentence.ordinal)
                    try await channel.send(sentence)
                }
            }
        }
        try Task.checkCancellation()
        for sentence in try buffer.receive(final, final: true) {
            trace?.mark(.speechEnqueued, part: sentence.ordinal == 0 ? .first : .remainder, sentenceOrdinal: sentence.ordinal)
            try await channel.send(sentence)
        }
        await channel.finish()
    }
    private func play(_ channel: SpeechSentenceChannel, _ trace: ReplyTrace?,
                      _ onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws {
        let events = try await speaker.speakSentences(from: channel, prefetch: prefetch)
        var started = false
        var finished = false
        for try await event in events {
            try Task.checkCancellation()
            let part: ReplySpeechPart = event.ordinal == 0 ? .first : .remainder
            switch event.event {
            case .started:
                trace?.mark(.speechStarted, part: part, source: .started, sentenceOrdinal: event.ordinal)
                if !started { started = true; onUpdate(.speechStarted(.full, .started)) }
            case .finished:
                finished = true
                trace?.mark(.speechFinished, part: part, sentenceOrdinal: event.ordinal)
            case .cancelled: throw ConversationServiceError.speechSynthesisFailed
            case .willSpeak: break
            }
        }
        try Task.checkCancellation()
        guard finished else { throw ConversationServiceError.speechSynthesisFailed }
        onUpdate(.speechFinished(.full))
    }
}
