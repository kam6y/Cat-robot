import AVFAudio
import Foundation

/// Smart Turn is required for this capture. Initialization errors propagate;
/// cancellation does not join a synchronous model loader or prediction.
actor SmartTurnService {
    private let makeScorer: @Sendable () throws -> any AudioTurnScoring
    private let makeVAD: @Sendable () throws -> any VoiceActivityScoring
    private let configuration: AudioTurnEndConfiguration
    private var scorer: (any AudioTurnScoring)?
    private var preparing = false

    init(root: URL, configuration: AudioTurnEndConfiguration = .init()) {
        makeScorer = { try CoreMLTurnScorer(modelURL: root.appendingPathComponent("smart_turn.mlmodelc")) }
        makeVAD = { try SileroVADScorer(modelURL: root.appendingPathComponent("silero_vad.onnx")) }
        self.configuration = configuration
    }

    init(configuration: AudioTurnEndConfiguration = .init(),
         makeScorer: @escaping @Sendable () throws -> any AudioTurnScoring,
         makeVAD: @escaping @Sendable () throws -> any VoiceActivityScoring) {
        self.configuration = configuration
        self.makeScorer = makeScorer
        self.makeVAD = makeVAD
    }

    func makeCapture(
        sourceFormat: AVAudioFormat,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onEndpoint: @escaping @Sendable (AudioTurnEndSignal) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void,
        onObservation: @escaping @Sendable (AudioTurnEndObservation) -> Void = { _ in }
    ) async throws -> AudioTurnEndCapture {
        try Task.checkCancellation()
        guard !preparing else { throw AudioTurnModelError.busy }
        preparing = true
        let cachedScorer = scorer
        let makeScorer = makeScorer
        let makeVAD = makeVAD
        let configuration = configuration
        let (stream, continuation) = AsyncThrowingStream<AudioTurnEndCapture, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let preparation = Task.detached { [self] in
            do {
                try Task.checkCancellation()
                let model: any AudioTurnScoring
                if let cachedScorer { model = cachedScorer }
                else {
                    model = try makeScorer()
                    try Task.checkCancellation()
                    _ = try model.completionProbability(samples: [Float](repeating: 0, count: AudioTurnEndState.windowLength))
                }
                try Task.checkCancellation()
                let vad = try makeVAD()
                try Task.checkCancellation()
                let capture = try AudioTurnEndCapture(sourceFormat: sourceFormat, vad: vad, scorer: model,
                    configuration: configuration, now: now, onEndpoint: onEndpoint,
                    onFailure: onFailure, onObservation: onObservation)
                await prepared(model)
                if Task.isCancelled { capture.cancel() }
                else if case .terminated = continuation.yield(capture) { capture.cancel() }
                continuation.finish()
            } catch {
                await preparationFailed()
                continuation.finish(throwing: error)
            }
        }
        return try await withTaskCancellationHandler {
            defer { preparation.cancel(); continuation.finish() }
            var iterator = stream.makeAsyncIterator()
            guard let capture = try await iterator.next() else { throw CancellationError() }
            guard !Task.isCancelled else { capture.cancel(); throw CancellationError() }
            return capture
        } onCancel: {
            preparation.cancel()
            continuation.finish(throwing: CancellationError())
        }
    }

    private func prepared(_ model: any AudioTurnScoring) {
        scorer = model
        preparing = false
    }

    private func preparationFailed() { preparing = false }
}
