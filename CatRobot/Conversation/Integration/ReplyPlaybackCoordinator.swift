import Foundation

enum ReplyPlaybackUpdate: Sendable {
    case sentenceQueued(SpeechSentence)
    case caption(String)
    case speechStarted(ReplySpeechPart, ReplySpeechStartSource)
    case speechFinished(ReplySpeechPart)
    case sentenceStarted(ordinal: Int)
    case sentenceFinished(ordinal: Int)
}

/// One owned operation joins generation and sentence playback before returning.
/// Generic cancellation retains memory; a voice interruption records what was delivered.
@MainActor
final class ReplyPlaybackCoordinator {
    private let reply: any ReplyGenerating
    private let speaker: any SentenceSpeechSpeaking
    private let motion: any ReplyTurnObserving
    private let prepareFirstSentence: Bool
    private struct Operation {
        let id: UUID
        let prompt: String
        let task: Task<String, Error>
        var speechStarted = false
        var speechFinished = false
        var interrupted = false
        var delivery = ReplyDeliveryProgress()
    }
    private var active: Operation?
    private var interruption: (id: UUID, task: Task<Void, Never>)?

    init(reply: any ReplyGenerating, speaker: any SentenceSpeechSpeaking,
         motion: any ReplyTurnObserving = NoopRobotMotionController(), prepareFirstSentence: Bool = true) {
        self.reply = reply; self.speaker = speaker; self.motion = motion
        self.prepareFirstSentence = prepareFirstSentence
    }

    func run(prompt: String, trace: ReplyTrace?,
             onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String {
        guard active == nil, interruption == nil else { throw ConversationServiceError.modelBusy }
        guard !Task.isCancelled else {
            trace?.finish(.cancelled)
            throw ConversationServiceError.cancelled
        }
        let id = UUID()
        let motionTurn = MotionTurnID(rawValue: id)
        let task = Task {
            try await ReplyDeliveryContext.$current.withValue(id) {
              try await MotionTurnContext.$current.withValue(motionTurn) {
                guard !Task.isCancelled else {
                    trace?.finish(.cancelled)
                    throw ConversationServiceError.cancelled
                }
                self.motion.beginTurn(motionTurn)
                let update: @MainActor @Sendable (ReplyPlaybackUpdate) -> Void = { [weak self] update in
                    guard let self, self.active?.id == id, self.active?.interrupted == false else { return }
                    switch update {
                    case .sentenceQueued(let sentence): self.active?.delivery.enqueue(sentence)
                    case .sentenceStarted(let ordinal): self.active?.delivery.start(ordinal)
                    case .sentenceFinished(let ordinal): self.active?.delivery.finish(ordinal)
                    case .speechStarted: self.releaseMotionOnce(id)
                    case .speechFinished(.full): self.active?.speechFinished = true
                    default: break
                    }
                    onUpdate(update)
                }
                do {
                    let result = try await ReplyTraceContext.$current.withValue(trace) {
                        try await SentenceReplyPlayback(reply: self.reply, speaker: self.speaker, prepareFirstSentence: self.prepareFirstSentence)
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
        }
        active = Operation(id: id, prompt: prompt, task: task)
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

    /// Freeze delivery before the view model cancels its enclosing turn task.
    /// Returning the owned join task lets capture continue while teardown runs.
    @discardableResult
    func interrupt() -> Task<Void, Never>? {
        if let interruption { return interruption.task }
        // Playback can finish before run() resumes to retire its active operation.
        guard let operation = active, !operation.speechFinished else { return nil }
        let receipt = operation.delivery.interruption(id: operation.id, prompt: operation.prompt)
        active?.interrupted = true
        motion.cancelTurn(MotionTurnID(rawValue: operation.id), reason: .playbackCancelled)
        operation.task.cancel()
        let task = Task { [reply] in
            _ = await operation.task.result
            await reply.interruptReply(receipt)
            if self.interruption?.id == operation.id { self.interruption = nil }
        }
        interruption = (operation.id, task)
        return task
    }

    func interruptAndWait() async { await interrupt()?.value }

    func cancelAndWait() async {
        if let operation = active {
            operation.task.cancel()
            // SentenceReplyPlayback stops the speaker and joins both children.
            _ = await operation.task.result
            if active?.id == operation.id { active = nil }
        }
        await interruption?.task.value
    }

}
