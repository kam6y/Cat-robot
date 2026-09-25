import Foundation

typealias SynthesizePCM = @Sendable (String) async throws -> SpeechPCM

@MainActor
final class SupertonicSpeaker: SpeechSpeaking {
    private let player: any PCMPlaying
    private let prepareModel: @Sendable () async throws -> Void
    private let synthesize: SynthesizePCM
    private var preparation: Task<Void, Error>?
    private var active: (id: UUID, task: Task<Void, Never>)?
    var onInput: (@MainActor @Sendable (String) -> Void)?
    var onSynthesis: (@MainActor @Sendable (String, Double?) -> Void)?

    init(player: any PCMPlaying, prepare: @escaping @Sendable () async throws -> Void,
         synthesize: @escaping SynthesizePCM) {
        self.player = player; self.prepareModel = prepare; self.synthesize = synthesize
    }
    convenience init(engine: SupertonicEngine, player: any PCMPlaying, voiceID: String, steps: Int) {
        self.init(player: player, prepare: { try await engine.prepare() }, synthesize: {
            try await engine.synthesize(text: $0, voiceID: voiceID, steps: steps)
        })
    }
    func prepare() async throws {
        if let preparation { try await preparation.value; return }
        let task = Task { try await prepareModel() }
        preparation = task
        defer { preparation = nil }
        try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        try Task.checkCancellation()
    }
    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        guard active == nil, preparation == nil else { throw ConversationServiceError.speechSynthesisFailed }
        let id = UUID()
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in await self?.stop(id: id) }
        }
        let task = Task { [self] in
            defer { if active?.id == id { active = nil } }
            do {
                try Task.checkCancellation()
                onInput?(text)
                onSynthesis?("synthesisStarted", nil)
                let pcm = try await synthesize(text)
                try Task.checkCancellation()
                try pcm.validate()
                onSynthesis?("synthesisFinished", Double(pcm.samples.count) / pcm.sampleRate)
                let events = try await player.play(pcm)
                var finished = false
                for try await event in events {
                    try Task.checkCancellation()
                    if event == .finished { finished = true }
                    pair.continuation.yield(event)
                }
                guard finished else { throw ConversationServiceError.speechSynthesisFailed }
                pair.continuation.finish()
            } catch {
                await player.stop()
                if Task.isCancelled { pair.continuation.yield(.cancelled); pair.continuation.finish() }
                else { pair.continuation.finish(throwing: error) }
            }
        }
        active = (id, task)
        return pair.stream
    }
    func stop() async {
        if let preparation { preparation.cancel(); _ = await preparation.result }
        if let id = active?.id { await stop(id: id) }
    }
    private func stop(id: UUID) async {
        guard let operation = active, operation.id == id else { return }
        operation.task.cancel()
        await player.stop()
        _ = await operation.task.result
        if active?.id == id { active = nil }
    }
}
