import Foundation

/// Owns one reply: one inference at a time, one next sentence, ordered playback.
@MainActor
final class SupertonicSentenceSpeaker: SentenceSpeechSpeaking {
    private struct Prepared: Sendable { let sentence: SpeechSentence; let pcm: SpeechPCM }
    private enum Completion: Sendable { case played; case next(Prepared?) }
    private let player: any PCMPlaying
    private let prepareModel: @Sendable () async throws -> Void
    private let voice: @MainActor @Sendable () -> SpeechVoicePreset
    private let synthesize: @Sendable (String, SpeechVoicePreset) async throws -> SpeechPCM
    private var preparation: Task<Void, Error>?
    private var active: (id: UUID, channel: SpeechSentenceChannel, task: Task<Void, Never>)?
    var onInput: (@MainActor @Sendable (String, String) -> Void)?
    var onSynthesis: (@MainActor @Sendable (Int, String) -> Void)?

    init(player: any PCMPlaying, prepare: @escaping @Sendable () async throws -> Void,
         voice: @escaping @MainActor @Sendable () -> SpeechVoicePreset,
         synthesize: @escaping @Sendable (String, SpeechVoicePreset) async throws -> SpeechPCM) {
        self.player = player; prepareModel = prepare; self.voice = voice; self.synthesize = synthesize
    }
    convenience init(engine: SupertonicEngine, voice: @escaping @MainActor @Sendable () -> SpeechVoicePreset) {
        self.init(player: PCMPlayer(), prepare: {
            do { try await engine.prepare() }
            catch is CancellationError { throw ConversationServiceError.cancelled }
            catch { throw SupertonicErrorMapper.map(error) }
        }, voice: voice, synthesize: { text, preset in
            do { return try await engine.synthesize(text: text, voiceID: preset.rawValue, steps: 8) }
            catch is CancellationError { throw ConversationServiceError.cancelled }
            catch { throw SupertonicErrorMapper.map(error) }
        })
    }
    func prepare() async throws {
        guard active == nil else { throw ConversationServiceError.speechSynthesisFailed }
        if let preparation { try await preparation.value; return }
        let task = Task { try await prepareModel() }
        preparation = task
        defer { preparation = nil }
        try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try Task.checkCancellation()
    }
    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        let channel = SpeechSentenceChannel()
        try await channel.send(SpeechSentence(ordinal: 0, original: text))
        await channel.finish()
        let source = try await speakSentences(from: channel, prefetch: false)
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let task = Task {
            do {
                for try await event in source { pair.continuation.yield(event.event) }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
    func speakSentences(from channel: SpeechSentenceChannel, prefetch: Bool) async throws -> AsyncThrowingStream<SentenceSpeechEvent, Error> {
        guard active == nil, preparation == nil else { throw ConversationServiceError.speechSynthesisFailed }
        try Task.checkCancellation()
        let selected = voice()
        let id = UUID()
        let pair = AsyncThrowingStream<SentenceSpeechEvent, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in await self?.stop(id: id) } }
        let task = Task {
            defer { if active?.id == id { active = nil } }
            do {
                var current = try await nextPrepared(channel, voice: selected)
                while let ready = current {
                    try Task.checkCancellation()
                    let events = try await player.play(ready.pcm)
                    if prefetch {
                        current = try await playAndPrefetch(events, ready.sentence, channel, selected, pair.continuation)
                    } else {
                        try await forward(events, sentence: ready.sentence, into: pair.continuation)
                        current = try await nextPrepared(channel, voice: selected)
                    }
                }
                try Task.checkCancellation()
                pair.continuation.finish()
            } catch {
                await channel.finish(throwing: error)
                await player.stop()
                pair.continuation.finish(throwing: Task.isCancelled ? ConversationServiceError.cancelled : error)
            }
        }
        active = (id, channel, task)
        return pair.stream
    }
    private func nextPrepared(_ channel: SpeechSentenceChannel, voice: SpeechVoicePreset) async throws -> Prepared? {
        guard let sentence = try await channel.next() else { return nil }
        try Task.checkCancellation()
        let spoken = SpeechPronunciationNormalizer().normalize(sentence.original)
        onInput?(sentence.original, spoken)
        onSynthesis?(sentence.ordinal, "synthesisStarted")
        let pcm = try await synthesize(spoken, voice)
        try Task.checkCancellation()
        try pcm.validate()
        onSynthesis?(sentence.ordinal, "synthesisFinished")
        return Prepared(sentence: sentence, pcm: pcm)
    }
    private func forward(_ events: AsyncThrowingStream<SpeechEvent, Error>, sentence: SpeechSentence,
                         into output: AsyncThrowingStream<SentenceSpeechEvent, Error>.Continuation) async throws {
        var finished = false
        for try await event in events {
            try Task.checkCancellation()
            if event == .cancelled { throw ConversationServiceError.speechSynthesisFailed }
            if case .willSpeak = event { continue } // PCM offsets cannot index the original text.
            if !finished { output.yield(SentenceSpeechEvent(ordinal: sentence.ordinal, event: event)) }
            if event == .finished { finished = true }
        }
        try Task.checkCancellation()
        guard finished else { throw ConversationServiceError.speechSynthesisFailed }
    }
    private func playAndPrefetch(_ events: AsyncThrowingStream<SpeechEvent, Error>, _ sentence: SpeechSentence,
                                 _ channel: SpeechSentenceChannel, _ voice: SpeechVoicePreset,
                                 _ output: AsyncThrowingStream<SentenceSpeechEvent, Error>.Continuation) async throws -> Prepared? {
        try await withThrowingTaskGroup(of: Completion.self) { group in
            group.addTask { try await self.forward(events, sentence: sentence, into: output); return .played }
            group.addTask { .next(try await self.nextPrepared(channel, voice: voice)) }
            do {
                var next: Prepared?
                while let result = try await group.next() { if case .next(let value) = result { next = value } }
                return next
            } catch {
                group.cancelAll()
                await channel.finish(throwing: error)
                await player.stop()
                while await group.nextResult() != nil {}
                throw error
            }
        }
    }
    func stop() async {
        if let preparation { preparation.cancel(); _ = await preparation.result }
        if let id = active?.id { await stop(id: id) }
    }
    private func stop(id: UUID) async {
        guard let operation = active, operation.id == id else { return }
        operation.task.cancel()
        await operation.channel.finish(throwing: ConversationServiceError.cancelled)
        await player.stop()
        _ = await operation.task.result
        if active?.id == id { active = nil }
    }
}
