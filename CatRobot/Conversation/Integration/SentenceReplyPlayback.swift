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
        trace?.mark(.request)
        do {
            let final = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    do { return try await self.produce(prompt, channel, trace, onUpdate) }
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
    private func produce(_ prompt: String, _ channel: SpeechSentenceChannel, _ trace: ReplyTrace?,
                         _ onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        let stream = try await reply.streamReply(to: prompt)
        var buffer = ReplySentenceStreamBuffer()
        var final = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            final = snapshot
            onUpdate(.caption(snapshot))
            if !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trace?.mark(.firstCaption) }
            if reply.supportsStableReplyPrefix {
                for sentence in try buffer.receive(snapshot) {
                    trace?.mark(.firstSentence)
                    trace?.mark(.speechEnqueued, part: sentence.ordinal == 0 ? .first : .remainder, sentenceOrdinal: sentence.ordinal)
                    try await channel.send(sentence)
                }
            }
        }
        try Task.checkCancellation()
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversationServiceError.modelGenerationFailed }
        trace?.mark(.streamFinished, outcome: .success)
        for sentence in try buffer.receive(final, final: true) {
            trace?.mark(.speechEnqueued, part: sentence.ordinal == 0 ? .first : .remainder, sentenceOrdinal: sentence.ordinal)
            try await channel.send(sentence)
        }
        await channel.finish()
        return final
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
