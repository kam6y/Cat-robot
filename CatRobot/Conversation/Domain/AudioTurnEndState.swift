import Foundation

/// Smart Turn 推論 1 回分の入力。`samples` は 16 kHz mono の直近 8 秒（128,000 sample）で、
/// 不足分は先頭をゼロで埋める。`revision` と `requestedAt` が「どの pause に対する要求か」を識別する。
struct AudioTurnEndRequest: Equatable, Sendable {
    let revision: UInt64
    let samples: [Float]
    let requestedAt: TimeInterval
}

/// Audio-only endpoint policy at the VAD's 32 ms frame resolution.
struct AudioTurnEndConfiguration: Equatable, Sendable {
    var completeProbability: Float = 0.5
    var pauseFrames = 7

    func accepts(_ probability: Float) -> Bool {
        guard probability.isFinite, (0...1).contains(probability),
              completeProbability.isFinite, (0...1).contains(completeProbability) else { return false }
        return probability > completeProbability
    }
}

/// Pure audio state machine: 16 kHz, 512-sample frames, VAD hysteresis,
/// one inference per pause, and a 300 ms applicability window. Resumed speech
/// and invalid input retire outstanding inference requests.
struct AudioTurnEndState: Sendable {
    static let frameLength = 512
    static let windowLength = 128_000
    static let speechOnsetProbability: Float = 0.5
    static let speechOffsetProbability: Float = 0.35
    static let minimumSpeechFrames = 16
    static let decisionWindow: TimeInterval = 0.3

    private struct PendingRequest: Equatable {
        let revision: UInt64
        let requestedAt: TimeInterval
    }

    private var window: [Float] = []
    private var isSpeechActive = false
    private var speechFrames = 0
    private var silenceFrames = 0
    private var revision: UInt64 = 0
    private var pending: PendingRequest?
    private var hasRequestedForPause = false
    private var lastTimestamp: TimeInterval?

    private let configuration: AudioTurnEndConfiguration

    init(configuration: AudioTurnEndConfiguration = .init()) { self.configuration = configuration }

    mutating func consume(samples: [Float], speechProbability: Float, at timestamp: TimeInterval) -> AudioTurnEndRequest? {
        guard samples.count == Self.frameLength,
              samples.allSatisfy(\.isFinite),
              speechProbability.isFinite,
              timestamp.isFinite,
              timestamp >= (lastTimestamp ?? timestamp) else {
            reset()
            return nil
        }
        lastTimestamp = timestamp

        window.append(contentsOf: samples)
        if window.count > Self.windowLength {
            window.removeFirst(window.count - Self.windowLength)
        }

        if speechProbability >= Self.speechOnsetProbability {
            isSpeechActive = true
        } else if speechProbability < Self.speechOffsetProbability {
            isSpeechActive = false
        }

        if isSpeechActive {
            speechFrames += 1
            silenceFrames = 0
            hasRequestedForPause = false
            revision &+= 1
            pending = nil
            return nil
        }

        guard speechFrames > 0 else { return nil }
        silenceFrames += 1
        guard silenceFrames >= configuration.pauseFrames,
              speechFrames >= Self.minimumSpeechFrames,
              !hasRequestedForPause else { return nil }

        hasRequestedForPause = true
        pending = PendingRequest(revision: revision, requestedAt: timestamp)
        let padding = [Float](repeating: 0, count: Self.windowLength - window.count)
        return AudioTurnEndRequest(revision: revision, samples: padding + window, requestedAt: timestamp)
    }

    func isPending(_ request: AudioTurnEndRequest, at timestamp: TimeInterval) -> Bool {
        guard let pending, pending.revision == revision,
              request.revision == pending.revision, request.requestedAt == pending.requestedAt,
              timestamp.isFinite, timestamp >= request.requestedAt,
              timestamp <= request.requestedAt + Self.decisionWindow else { return false }
        return true
    }

    mutating func accept(probability: Float, for request: AudioTurnEndRequest, at timestamp: TimeInterval) -> Bool {
        guard configuration.accepts(probability), isPending(request, at: timestamp) else { return false }
        pending = nil
        return true
    }

    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        isSpeechActive = false
        speechFrames = 0
        silenceFrames = 0
        pending = nil
        hasRequestedForPause = false
        lastTimestamp = nil
        revision &+= 1
    }
}
