import CoreML
import Foundation
import OnnxRuntimeBindings

protocol AudioTurnScoring: Sendable {
    func completionProbability(samples: [Float]) throws -> Float
}
protocol VoiceActivityScoring: Sendable {
    func speechProbability(samples: [Float]) throws -> Float
    /// Scores 1..<512 pending samples without advancing streaming state or context.
    func speechProbabilityOfTail(samples: [Float]) throws -> Float
}
enum AudioTurnModelError: Error { case invalidInput, invalidOutput, unavailable, busy }

/// The compiled model includes the upstream normalization and Whisper mel frontend.
/// Called only from the endpoint worker. One model is shared between captures;
/// a previous uncooperative prediction cannot queue another prediction behind it.
final class CoreMLTurnScorer: AudioTurnScoring, @unchecked Sendable {
    private let model: MLModel
    private let lock = NSLock()

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
#if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
#else
        config.computeUnits = .cpuAndNeuralEngine
#endif
        model = try MLModel(contentsOf: modelURL, configuration: config)
        guard model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape == [1, NSNumber(value: AudioTurnEndState.windowLength)],
              model.modelDescription.outputDescriptionsByName["probability"] != nil else {
            throw AudioTurnModelError.invalidInput
        }
    }

    func completionProbability(samples: [Float]) throws -> Float {
        guard samples.count == AudioTurnEndState.windowLength, samples.allSatisfy(\.isFinite) else {
            throw AudioTurnModelError.invalidInput
        }
        guard lock.try() else { throw AudioTurnModelError.busy }
        defer { lock.unlock() }
        let audio = try MLMultiArray(shape: [1, NSNumber(value: AudioTurnEndState.windowLength)], dataType: .float32)
        samples.withUnsafeBufferPointer { source in
            audio.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: samples.count)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)])
        let result = try model.prediction(from: features)
        guard let output = result.featureValue(for: "probability")?.multiArrayValue, output.count == 1 else {
            throw AudioTurnModelError.invalidOutput
        }
        let probability = output[0].floatValue
        guard probability.isFinite, (0...1).contains(probability) else { throw AudioTurnModelError.invalidOutput }
        return probability
    }
}

/// Silero's official streaming contract: 512 new samples plus 64 context samples,
/// recurrent state [2,1,128], and scalar sample rate 16000. Each capture owns its state.
final class SileroVADScorer: VoiceActivityScoring, @unchecked Sendable {
    private let environment: ORTEnv
    private let session: ORTSession
    private let lock = NSLock()
    private var state = [Float](repeating: 0, count: 256)
    private var context = [Float](repeating: 0, count: 64)

    init(modelURL: URL) throws {
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
    }

    func speechProbability(samples: [Float]) throws -> Float {
        guard samples.count == AudioTurnEndState.frameLength, samples.allSatisfy(\.isFinite) else {
            throw AudioTurnModelError.invalidInput
        }
        return try lock.withLock { try predict(samples: samples, committing: true) }
    }

    func speechProbabilityOfTail(samples: [Float]) throws -> Float {
        guard !samples.isEmpty, samples.count < AudioTurnEndState.frameLength,
              samples.allSatisfy(\.isFinite) else { throw AudioTurnModelError.invalidInput }
        // The pinned upstream wrapper pads final partial frames. This preview
        // does not commit its padding or returned recurrent state to the stream.
        let frame = samples + [Float](repeating: 0, count: AudioTurnEndState.frameLength - samples.count)
        return try lock.withLock { try predict(samples: frame, committing: false) }
    }

    /// Caller holds lock; inputs/state are private copies, so a preview can discard stateN.
    private func predict(samples: [Float], committing: Bool) throws -> Float {
        let input = context + samples
        let rate: [Int64] = [16000]
        let inputValue = try ORTValue(tensorData: NSMutableData(bytes: input, length: input.count * 4),
                                     elementType: .float, shape: [1, 576])
        let stateValue = try ORTValue(tensorData: NSMutableData(bytes: state, length: state.count * 4),
                                     elementType: .float, shape: [2, 1, 128])
        let rateValue = try ORTValue(tensorData: NSMutableData(bytes: rate, length: MemoryLayout<Int64>.size),
                                    elementType: .int64, shape: [])
        let outputs = try session.run(withInputs: ["input": inputValue, "state": stateValue, "sr": rateValue],
                                      outputNames: ["output", "stateN"], runOptions: nil)
        guard let output = outputs["output"], let next = outputs["stateN"] else { throw AudioTurnModelError.invalidOutput }
        let data = try output.tensorData() as Data
        let nextData = try next.tensorData() as Data
        guard data.count == 4, nextData.count == 256 * 4 else { throw AudioTurnModelError.invalidOutput }
        let probability = data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        let nextState = nextData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard probability.isFinite, (0...1).contains(probability), nextState.allSatisfy(\.isFinite) else {
            throw AudioTurnModelError.invalidOutput
        }
        if committing {
            state = nextState
            context = Array(samples.suffix(64))
        }
        return probability
    }

    func reset() {
        lock.withLock {
            state = [Float](repeating: 0, count: 256)
            context = [Float](repeating: 0, count: 64)
        }
    }
}
