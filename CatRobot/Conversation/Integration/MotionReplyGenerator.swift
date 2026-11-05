import Foundation

/// Observes the final routed stream; memory and cached model sessions remain owned by the base service.
struct MotionReplyGenerator: ReplyGenerating {
    let base: any ReplyGenerating
    let motion: any ReplyTurnObserving
    var supportsStableReplyPrefix: Bool { base.supportsStableReplyPrefix }

    init(base: any ReplyGenerating, motion: any ReplyTurnObserving) {
        self.base = base
        self.motion = motion
    }
    func prewarm() async { await base.prewarm() }
    func reset() async { await base.reset() }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        // Capture before the actor hop or relay task, and never substitute the coordinator's current turn.
        guard let turn = MotionTurnContext.current else { return try await base.streamReply(to: utterance) }
        do {
            let source = try await base.streamReply(to: utterance)
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let worker = Task {
                do {
                    for try await snapshot in source {
                        try Task.checkCancellation()
                        continuation.yield(snapshot)
                    }
                    try Task.checkCancellation()
                    await motion.generationFinished(turn, outcome: .success)
                    continuation.finish()
                } catch {
                    await motion.generationFinished(turn, outcome: .failed)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { worker.cancel() }
            }
            return stream
        } catch {
            await motion.generationFinished(turn, outcome: .failed)
            throw error
        }
    }
}
