import Foundation

enum ReplyPlaybackUpdate: Sendable {
    case caption(String)
    case speechStarted(ReplySpeechPart, ReplySpeechStartSource)
    case speechFinished(ReplySpeechPart)
    case sentenceStarted(ordinal: Int)
    case sentenceFinished(ordinal: Int)
}

/// One owned operation joins generation and sentence playback before returning.
/// Cancellation never resets the reply service or rolls back committed memory.
@MainActor
final class ReplyPlaybackCoordinator {
    private let reply: any ReplyGenerating
    private let speaker: any SentenceSpeechSpeaking
    private let motion: any ReplyTurnObserving
    private var active: (id: UUID, task: Task<String, Error>, speechStarted: Bool)?

    init(reply: any ReplyGenerating, speaker: any SentenceSpeechSpeaking,
         motion: any ReplyTurnObserving = NoopRobotMotionController()) {
        self.reply = reply; self.speaker = speaker; self.motion = motion
    }

    func run(prompt: String, trace: ReplyTrace?,
             onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        guard active == nil else { throw ConversationServiceError.modelBusy }
        guard !Task.isCancelled else {
            trace?.finish(.cancelled)
            throw ConversationServiceError.cancelled
        }
        let id = UUID()
        let motionTurn = MotionTurnID(rawValue: id)
        let task = Task {
            try await MotionTurnContext.$current.withValue(motionTurn) {
                guard !Task.isCancelled else {
                    trace?.finish(.cancelled)
                    throw ConversationServiceError.cancelled
                }
                self.motion.beginTurn(motionTurn)
                let update: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void = { [weak self] update in
                    if case .speechStarted = update { self?.releaseMotionOnce(id) }
                    onUpdate(update)
                }
                do {
                    let result = try await ReplyTraceContext.$current.withValue(trace) {
                        try await SentenceReplyPlayback(reply: self.reply, speaker: self.speaker)
                            .run(prompt: prompt, trace: trace, onUpdate: update)
                    }
                    self.motion.speechFinished(motionTurn)
                    return result
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                        || error as? ConversationServiceError == .cancelled
                    self.motion.cancelTurn(motionTurn, reason: cancelled ? .playbackCancelled : .playbackFailed)
                    throw error
                }
            }
        }
        active = (id, task, false)
        defer { if active?.id == id { active = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func releaseMotionOnce(_ id: UUID) {
        guard active?.id == id, active?.speechStarted == false else { return }
        active?.speechStarted = true
        motion.speechStarted(MotionTurnID(rawValue: id))
    }

    func cancelAndWait() async {
        guard let operation = active else { return }
        operation.task.cancel()
        // SentenceReplyPlayback stops the speaker and joins generation and playback.
        _ = await operation.task.result
        if active?.id == operation.id { active = nil }
    }

}
