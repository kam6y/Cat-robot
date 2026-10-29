import Foundation

@MainActor
final class SentenceReplyPlayback {
    static let preparationStableDelay: Duration = .milliseconds(75)
    private struct Failure: Error { let error: Error; let outcome: ReplyTraceOutcome }
    private let reply: any ReplyGenerating
    private let speaker: any SentenceSpeechSpeaking
    private let prepareFirstSentence: Bool
    init(reply: any ReplyGenerating, speaker: any SentenceSpeechSpeaking, prepareFirstSentence: Bool = true) {
        self.reply = reply; self.speaker = speaker
        self.prepareFirstSentence = prepareFirstSentence
    }
    func run(prompt: String, trace: ReplyTrace?, onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        let channel = SpeechSentenceChannel()
        // These are cumulative snapshots, not sentences: replacing an unread
        // snapshot retains its text in the newer one. Observe upstream failure
        // independently of the bounded sentence queue's playback backpressure.
        let snapshots = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        trace?.mark(.request)
        do {
            let final = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    do {
                        let final = try await self.produce(prompt, snapshots.continuation, trace, onUpdate)
                        snapshots.continuation.finish()
                        return final
                    } catch {
                        // A failed stream has no final tail to flush into speech.
                        snapshots.continuation.finish(throwing: error)
                        throw Failure(error: error, outcome: .generationFailure)
                    }
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
    private func produce(_ prompt: String, _ snapshots: AsyncThrowingStream<String, Error>.Continuation, _ trace: ReplyTrace?,
                         _ onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
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
    private func enqueue(_ snapshots: AsyncThrowingStream<String, Error>, _ channel: SpeechSentenceChannel, _ trace: ReplyTrace?) async throws {
        var buffer = ReplySentenceStreamBuffer()
        var final = ""
        var pending: Task<Void, Never>?
        var candidateKey: String?
        do {
            for try await snapshot in snapshots {
                try Task.checkCancellation()
                final = snapshot
                if reply.supportsStableReplyPrefix {
                    let sentences = try buffer.receive(snapshot)
                    if buffer.preparationCandidate != nil {
                        trace?.mark(.firstCandidate, part: .first, sentenceOrdinal: 0)
                    }
                    let candidate = prepareFirstSentence ? buffer.preparationCandidate : nil
                    let key = candidate?.original.trimmingCharacters(in: .whitespacesAndNewlines)
                    if key != candidateKey {
                        pending?.cancel()
                        await pending?.value
                        pending = nil
                        candidateKey = key
                        if let candidate {
                            pending = Task {
                                do {
                                    try await Task.sleep(for: Self.preparationStableDelay)
                                    try Task.checkCancellation()
                                    await channel.offerPreparation(candidate)
                                } catch {}
                            }
                        }
                    }
                    try await commit(sentences, to: channel, trace: trace)
                }
            }
            pending?.cancel()
            await pending?.value
            try Task.checkCancellation()
            try await commit(buffer.receive(final, final: true), to: channel, trace: trace)
            await channel.finish()
        } catch {
            pending?.cancel()
            await pending?.value
            throw error
        }
    }
    private func commit(_ sentences: [SpeechSentence], to channel: SpeechSentenceChannel, trace: ReplyTrace?) async throws {
        for sentence in sentences {
            trace?.mark(.firstSentence)
            trace?.mark(.speechEnqueued, part: sentence.ordinal == 0 ? .first : .remainder, sentenceOrdinal: sentence.ordinal)
            try await channel.send(sentence)
        }
    }
    private func play(_ channel: SpeechSentenceChannel, _ trace: ReplyTrace?,
                      _ onUpdate: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws {
        let events = try await speaker.speakSentences(from: channel, prefetch: true)
        // The deduplication sets also answer "has anything started / finished yet".
        var startedOrdinals: Set<Int> = []
        var finishedOrdinals: Set<Int> = []
        for try await event in events {
            try Task.checkCancellation()
            let part: ReplySpeechPart = event.ordinal == 0 ? .first : .remainder
            switch event.event {
            case .started:
                guard !finishedOrdinals.contains(event.ordinal),
                      startedOrdinals.insert(event.ordinal).inserted else { continue }
                trace?.mark(.speechStarted, part: part, source: .started, sentenceOrdinal: event.ordinal)
                if startedOrdinals.count == 1 { onUpdate(.speechStarted(.full, .started)) }
                onUpdate(.sentenceStarted(ordinal: event.ordinal))
            case .finished:
                guard finishedOrdinals.insert(event.ordinal).inserted else { continue }
                trace?.mark(.speechFinished, part: part, sentenceOrdinal: event.ordinal)
                onUpdate(.sentenceFinished(ordinal: event.ordinal))
            case .cancelled: throw ConversationServiceError.speechSynthesisFailed
            case .willSpeak: break
            }
        }
        try Task.checkCancellation()
        guard !finishedOrdinals.isEmpty else { throw ConversationServiceError.speechSynthesisFailed }
        onUpdate(.speechFinished(.full))
    }
}
