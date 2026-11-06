import Foundation

/// Synchronous fence shared by tap admission, the VAD worker, and the MainActor consumer.
/// Pending audio must be scored before silence can authorize a close.
final class AudioTurnEndGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var speechRevision: UInt64 = 0
    private var pendingAudio = 0

    var revision: UInt64 { lock.withLock { speechRevision } }

    func beginAudio() -> Bool {
        lock.withLock {
            guard active else { return false }
            pendingAudio += 1
            speechRevision &+= 1 // A raw chunk retires previously issued signals even before VAD.
            return true
        }
    }

    func endAudio() { lock.withLock { pendingAudio = max(0, pendingAudio - 1) } }
    func noteSpeech() { lock.withLock { speechRevision &+= 1 } }
    func invalidate() { lock.withLock { active = false; speechRevision &+= 1 } }

    func isCurrent(_ revision: UInt64) -> Bool {
        lock.withLock { active && pendingAudio == 0 && speechRevision == revision }
    }
}

struct AudioTurnEndSignal: Equatable, Sendable {
    private let configuration: AudioTurnEndConfiguration
    let id = UUID()
    let probability: Float
    let requestedAt: TimeInterval
    private let gate: AudioTurnEndGate
    private let revision: UInt64

    init(probability: Float, requestedAt: TimeInterval, gate: AudioTurnEndGate = .init(),
         configuration: AudioTurnEndConfiguration = .init()) {
        self.configuration = configuration
        self.probability = probability
        self.requestedAt = requestedAt
        self.gate = gate
        revision = gate.revision
    }

    func isValid(at timestamp: TimeInterval) -> Bool {
        return configuration.accepts(probability) && requestedAt.isFinite && timestamp.isFinite
            && timestamp >= requestedAt && timestamp <= requestedAt + AudioTurnEndState.decisionWindow
            && gate.isCurrent(revision)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
