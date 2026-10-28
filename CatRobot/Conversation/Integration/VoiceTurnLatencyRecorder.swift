import Foundation

/// The lifecycle, turn, or capture an asynchronous result belongs to.
enum ConversationTurnOwner {
    case lifecycle(generation: UInt64)
    case turn(generation: UInt64, turnID: UInt64)
    case capture(generation: UInt64, captureID: UInt64)
}

/// Owns the latency token and reply trace of the one voice turn being measured.
/// Milestones are recorded only for the matching generation and turn, and a
/// cancellation from an older owner never ends a newer turn's measurement.
@MainActor
final class VoiceTurnLatencyRecorder {
    private struct Active {
        let generation: UInt64
        let captureID: UInt64
        let turnID: UInt64
        let token: ConversationLatencyToken
        let trace: ReplyTrace
    }

    private let latency: any ConversationLatencyTracking
    private let traceSink: any ReplyTraceSink
    private let now: @Sendable () -> TimeInterval
    private var active: Active?

    init(
        latency: any ConversationLatencyTracking,
        traceSink: any ReplyTraceSink,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.latency = latency
        self.traceSink = traceSink
        self.now = now
    }

    var trace: ReplyTrace? { active?.trace }

    func begin(
        generation: UInt64,
        captureID: UInt64,
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    ) {
        let token = latency.beginVoiceTurn(
            turnID: turnID,
            boundaryAt: boundaryAt,
            lastASRActivityAt: lastASRActivityAt,
            segmentationInterval: segmentationInterval
        )
        let trace = ReplyTrace(id: token.rawValue, sink: traceSink, now: now)
        trace.mark(.captureBoundary)
        active = Active(
            generation: generation,
            captureID: captureID,
            turnID: turnID,
            token: token,
            trace: trace
        )
    }

    func noteASRActivity(generation: UInt64, captureID: UInt64) {
        guard let active,
              active.generation == generation,
              active.captureID == captureID else { return }
        latency.noteASRActivity(at: now(), for: active.token)
    }

    func selectPath(_ path: ConversationLatencyPath, generation: UInt64, turnID: UInt64) {
        guard let active = matching(generation: generation, turnID: turnID) else { return }
        latency.selectPath(path, for: active.token, at: now())
    }

    func recordFirstCaption(generation: UInt64, turnID: UInt64) {
        guard let active = matching(generation: generation, turnID: turnID) else { return }
        active.trace.mark(.firstCaption)
        latency.firstCaptionVisible(for: active.token, at: now())
    }

    func recordSpeechStarted(generation: UInt64, turnID: UInt64) {
        guard let active = matching(generation: generation, turnID: turnID) else { return }
        latency.speechStarted(for: active.token, at: now())
    }

    func cancel(reason: ConversationLatencyCancellation) {
        guard let active else { return }
        self.active = nil
        let outcome: ReplyTraceOutcome
        switch reason {
        case .noResponse, .unselectedPath: outcome = .noResponse
        case .ambiguous: outcome = .ambiguous
        case .failure: outcome = .generationFailure
        default: outcome = .cancelled
        }
        active.trace.finish(outcome)
        latency.cancel(active.token, reason: reason, at: now())
    }

    func cancel(reason: ConversationLatencyCancellation, ifOwnedBy owner: ConversationTurnOwner) {
        guard let active else { return }
        let isOwner: Bool
        switch owner {
        case .lifecycle(let generation):
            isOwner = active.generation == generation
        case .turn(let generation, let turnID):
            isOwner = active.generation == generation
                && active.turnID == turnID
        case .capture(let generation, let captureID):
            isOwner = active.generation == generation
                && active.captureID == captureID
        }
        guard isOwner else { return }
        cancel(reason: reason)
    }

    private func matching(generation: UInt64, turnID: UInt64) -> Active? {
        guard let active,
              active.generation == generation,
              active.turnID == turnID else { return nil }
        return active
    }
}
