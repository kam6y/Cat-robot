import Foundation
import Observation

struct ConversationOperationOwnership {
    private(set) var activeID: UInt64?
    private var counter: UInt64 = 0

    mutating func begin() -> UInt64 {
        counter &+= 1
        activeID = counter
        return counter
    }

    @discardableResult
    mutating func finish(_ id: UInt64) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    mutating func invalidate() {
        activeID = nil
    }
}

@MainActor
@Observable
final class ConversationViewModel {
    private enum EngagementUpdate {
        case arm
        case refresh
        case none
    }

    /// How a failed reply turn ends; typed and voice turns share the decision.
    private struct ReplyFailurePolicy {
        let error: ConversationServiceError
        /// A synthesis failure would fail a typed reply as well.
        var includesTypedFallback: Bool { error != .speechSynthesisFailed && error != .speechVoiceUnavailable }
        /// An exceeded context cannot recover within the same reply session.
        var resetsReplySession: Bool { error == .contextExceeded }
    }

    private struct DetachedLifecycleTasks: Sendable {
        let preflight: Task<Void, Never>?
        let turn: Task<Void, Never>?
        let capture: Task<Void, Never>?
        let closing: Task<Void, Never>?
    }

    private let dependencies: ConversationDependencies
    private let replyPlayback: ReplyPlaybackCoordinator
    private let voiceLatency: VoiceTurnLatencyRecorder
    @ObservationIgnored private var playbackMouthSequence = SpeechMouthPoseSequence()
    private(set) var viewState: ConversationViewState = .idle

    @ObservationIgnored private var engagement = EngagementWindow()
    @ObservationIgnored private var pendingClarification: PendingClarification?
    @ObservationIgnored private var pendingClarificationExpirationCounter: UInt64 = 0
    @ObservationIgnored private var activePendingClarificationExpirationID: UInt64?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var captureCounter: UInt64 = 0
    @ObservationIgnored private var turnCounter: UInt64 = 0
    @ObservationIgnored private var actionIntentCounter: UInt64 = 0
    @ObservationIgnored private var failureCounter: UInt64 = 0
    @ObservationIgnored private var microphonePermissionAwaitCounter: UInt64 = 0
    @ObservationIgnored private var activeMicrophonePermissionAwaitID: UInt64?
    @ObservationIgnored private var deferredMicrophonePermissionAwaitID: UInt64?
    @ObservationIgnored private var microphonePermissionCompletionWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var preflightOwnership = ConversationOperationOwnership()
    @ObservationIgnored private var transitionOwnership = ConversationOperationOwnership()
    @ObservationIgnored private var activeFailureID: UInt64?
    @ObservationIgnored private var activeCaptureID: UInt64?
    @ObservationIgnored private var activeTurnID: UInt64?
    @ObservationIgnored private var captureIsClosing = false
    @ObservationIgnored private var closingTailSegments: [String] = []
    @ObservationIgnored private var segmenter = UtteranceSegmenter()
    @ObservationIgnored private var latestCaptureActivityAt: TimeInterval?
    @ObservationIgnored private var wantsListening = false
    @ObservationIgnored private var microphoneWasAllowed = false
    @ObservationIgnored private var isShutdown = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var preflightTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var segmentationTask: Task<Void, Never>?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var failureCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var pendingClarificationExpirationTask: Task<Void, Never>?
    @ObservationIgnored private var audioEventTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    @ObservationIgnored private var memoryEventTask: Task<Void, Never>?
    @ObservationIgnored private var memoryActionInProgress = false
    @ObservationIgnored private var forgettingMemory = false
    @ObservationIgnored private var noticeExpiryTask: Task<Void, Never>?
    @ObservationIgnored var onAddressedActivity: @MainActor () -> Void = {}
    @ObservationIgnored var onPhaseChange: @MainActor (ConversationPhase) -> Void = { _ in }
    @ObservationIgnored var onPendingSpeechChange: @MainActor () -> Void = {}
    private static let noticeLifetime: Duration = .seconds(5)

    init(dependencies: ConversationDependencies) {
        self.dependencies = dependencies
        self.replyPlayback = ReplyPlaybackCoordinator(reply: dependencies.reply, speaker: dependencies.speaker, motion: dependencies.replyTurnObserver)
        self.voiceLatency = VoiceTurnLatencyRecorder(latency: dependencies.latency, traceSink: dependencies.replyTraceSink, now: dependencies.now)
        announcePhase(.idle)
    }

    /// The head and the expression follow the phase; look only observes turns.
    private func announcePhase(_ phase: ConversationPhase) {
        dependencies.motion.setConversationPhase(phase)
        dependencies.faceExpressions.setConversationPhase(phase)
    }

    /// Clears what the current turn put on screen and, when a reason is given, stops the head.
    /// Order is fixed: head, then expression, then look. Runs synchronously before any suspension.
    private func resetTurnPresentation(stopping reason: MotionCancellationReason?) {
        if let reason { dependencies.motion.stopAll(reason: reason) }
        dependencies.faceExpressions.reset()
        dependencies.look.reset()
    }

    var hasPendingSpeech: Bool { segmenter.hasActivity || captureIsClosing }

    var isAwaitingMicrophonePermission: Bool {
        activeMicrophonePermissionAwaitID != nil
    }

    func startConversation() async {
        guard !isShutdown, !isShuttingDown, !memoryActionInProgress,
              !ConversationMemoryPresentation(state: viewState.memoryState).blocksConversation else { return }
        ensureMemoryEventConsumer()
        ensureAudioEventConsumer()

        if let failureCleanupTask {
            guard await awaitTaskKeepingIntent(failureCleanupTask, checkpoint: .waitingForFailureCleanup) else { return }
        }

        if let lifecycleTransitionTask {
            guard await awaitTaskKeepingIntent(lifecycleTransitionTask) else { return }
        }
        guard !isShutdown, !isShuttingDown else { return }

        if let preflightTask {
            await dependencies.lifecycleCheckpoint(.joiningExistingPreflight)
            await preflightTask.value
            return
        }
        switch viewState.phase {
        case .listening, .classifying, .clarifying, .thinking, .speaking:
            return
        case .idle, .preparing, .paused, .failed:
            break
        }

        viewState.isAwaitingTapToResume = false
        wantsListening = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        transition(to: .preparing)
        let preflightID = preflightOwnership.begin()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dependencies.lifecycleCheckpoint(.preflightWillStart)
            await self.performVoicePreflight(generation: generation)
            await self.dependencies.lifecycleCheckpoint(.preflightWillFinish)
            if self.preflightOwnership.finish(preflightID) {
                self.preflightTask = nil
            }
        }
        preflightTask = task
        await task.value
    }

    func toggleListening() async {
        switch viewState.phase {
        case .idle, .paused, .failed:
            await startConversation()
        case .preparing, .listening, .classifying, .clarifying, .thinking, .speaking:
            resetTurnPresentation(stopping: .userStop)
            await pauseConversation(awaitsTapResume: true)
        }
    }

    func retryRecovery() async {
        viewState.errorMessage = nil
        viewState.recoveries = []
        switch viewState.phase {
        case .failed, .paused, .idle:
            await startConversation()
        default:
            break
        }
    }

    func clearCaptionForStandby() {
        viewState.caption = ""
    }

    func showTypedInput() {
        viewState.showsTypedInput = true
    }

    func hideTypedInput() {
        viewState.showsTypedInput = false
    }

    func updateTypedText(_ text: String) {
        viewState.typedText = text
    }

    func submitTypedText(_ text: String) async {
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty,
              !isShutdown,
              !isShuttingDown,
              !memoryActionInProgress,
              viewState.allowsTypedSubmission else { return }

        if let failureCleanupTask {
            guard await awaitTaskKeepingIntent(failureCleanupTask),
                  !isShutdown,
                  !isShuttingDown else { return }
        }

        if let lifecycleTransitionTask {
            guard await awaitTaskKeepingIntent(lifecycleTransitionTask),
                  !isShutdown,
                  !isShuttingDown else { return }
        }

        guard viewState.allowsTypedSubmission, !memoryActionInProgress else { return }
        onAddressedActivity()
        ensureMemoryEventConsumer()

        voiceLatency.cancel(reason: .typedReplacement)
        ensureAudioEventConsumer()
        let shouldResumeVoice = wantsListening
            && microphoneWasAllowed
            && activeCaptureID != nil
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        wantsListening = false
        clearPendingClarification()
        engagement.clear()
        turnCounter &+= 1
        let turnID = turnCounter
        activeTurnID = turnID
        transition(to: .preparing)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTypedTurn(
                submitted,
                shouldResumeVoice: shouldResumeVoice,
                generation: generation,
                turnID: turnID
            )
        }
        turnTask = task
        await task.value
        if activeTurnID == turnID {
            activeTurnID = nil
            turnTask = nil
        }
    }

    func sceneBecameInactive() async {
        await pauseConversation()
    }

    func deferMicrophonePermissionCompletion() {
        guard let activeMicrophonePermissionAwaitID else { return }
        deferredMicrophonePermissionAwaitID = activeMicrophonePermissionAwaitID
    }

    func releaseMicrophonePermissionCompletion() {
        deferredMicrophonePermissionAwaitID = nil
        let waiter = microphonePermissionCompletionWaiter
        microphonePermissionCompletionWaiter = nil
        waiter?.resume()
    }

    func invalidateForSceneInactivity() {
        viewState.isAwaitingTapToResume = false
        resetTurnPresentation(stopping: nil)
        actionIntentCounter &+= 1
        lifecycleGeneration &+= 1
        wantsListening = false
        clearPendingClarification()
        voiceLatency.cancel(reason: .lifecycle)
        activeMicrophonePermissionAwaitID = nil
        releaseMicrophonePermissionCompletion()
    }

    func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
        switch event {
        case .interruptionBegan, .routeChanged:
            resetTurnPresentation(stopping: .playbackFailed)
            await pauseConversation(awaitsTapResume: true)
        case .interruptionEnded:
            break
        }
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !isShutdown else { return }
        isShuttingDown = true
        viewState.isAwaitingTapToResume = false
        resetTurnPresentation(stopping: nil)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        dependencies.motion.setControlMode(.background)
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        voiceLatency.cancel(reason: .shutdown)
        await pauseConversation(force: true)

        let eventTask = audioEventTask
        audioEventTask = nil
        eventTask?.cancel()
        await eventTask?.value
        let memoryEvents = memoryEventTask
        memoryEventTask = nil
        memoryEvents?.cancel()
        await memoryEvents?.value
        await dependencies.serviceTeardown()
        isShutdown = true
        isShuttingDown = false
    }

    func flushSegmentation(at timestamp: TimeInterval) async {
        if let closingTask {
            await closingTask.value
            return
        }
        guard let captureID = activeCaptureID,
              !captureIsClosing else {
            return
        }
        guard let utterance = segmenter.utteranceIfReady(at: timestamp) else {
            synchronizeCaptureTimingWithSegmenter()
            return
        }
        beginClosingCapture(
            utterance: utterance,
            generation: lifecycleGeneration,
            captureID: captureID,
            boundaryAt: timestamp
        )
        await closingTask?.value
    }

    private func ensureMemoryEventConsumer() {
        guard memoryEventTask == nil, !isShutdown else { return }
        let manager = dependencies.memory
        memoryEventTask = Task { @MainActor [weak self] in
            for await state in await manager.memoryUpdates() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if !self.forgettingMemory { self.viewState.memoryState = state }
            }
        }
    }

    /// 設定の「すべて削除」。確認ダイアログは設定画面側で済ませてから呼ぶ。覚えていることと会話の要約の両方を消す。
    func forgetConversation() async {
        guard !memoryActionInProgress,
              ConversationMemoryPresentation(state: viewState.memoryState).supportsForget else { return }
        await performForgetConversation()
    }

    private func performForgetConversation() async {
        guard !memoryActionInProgress, !isShutdown, !isShuttingDown else { return }
        memoryActionInProgress = true
        forgettingMemory = true
        resetTurnPresentation(stopping: .newConversation)
        viewState.memoryState = .forgetting
        clearNotice()
        defer { memoryActionInProgress = false; forgettingMemory = false }
        await pauseConversation(force: true)
        do {
            try await dependencies.memory.forgetConversation()
            viewState.caption = ""
            viewState.provisionalTranscript = ""
            viewState.typedText = ""
            viewState.showsTypedInput = false
            showNotice("会話の記憶を削除しました")
        } catch {
            // The service retains a blocking failure state. Never announce deletion.
        }
        viewState.memoryState = await dependencies.memory.memoryState()
        transition(to: .paused)
    }

    /// 短期の会話内容だけを捨てる。長期メモは残る。モデル設定の変更はこのあとの会話から効く。
    func startNewConversation() async {
        guard !memoryActionInProgress, !isShutdown, !isShuttingDown else { return }
        memoryActionInProgress = true
        defer { memoryActionInProgress = false }
        resetTurnPresentation(stopping: .newConversation)
        clearNotice()
        await pauseConversation(force: true)
        await dependencies.reply.reset()
        viewState.caption = ""
        viewState.provisionalTranscript = ""
        showNotice("新しい会話を始めました")
        viewState.memoryState = await dependencies.memory.memoryState()
        transition(to: .paused)
    }

    /// 通知は数秒で消す。次に話しかけた時点（transition で classifying / thinking に入る）でも消す。
    private func showNotice(_ text: String) {
        noticeExpiryTask?.cancel()
        viewState.memoryNotice = text
        let delay = dependencies.noticeDelay
        noticeExpiryTask = Task { @MainActor [weak self] in
            await delay(Self.noticeLifetime)
            guard !Task.isCancelled, let self, self.viewState.memoryNotice == text else { return }
            self.viewState.memoryNotice = nil
            self.noticeExpiryTask = nil
        }
    }

    private func clearNotice() {
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        viewState.memoryNotice = nil
    }

    func retryMemoryOperation() async {
        guard !memoryActionInProgress, !isShutdown, !isShuttingDown else { return }
        if case .forgetFailed = viewState.memoryState {
            await performForgetConversation()
            return
        }
        memoryActionInProgress = true
        defer { memoryActionInProgress = false }
        do { try await dependencies.memory.retryMemoryOperation() } catch {}
        viewState.memoryState = await dependencies.memory.memoryState()
        // Retrying persistence never restarts capture or synthesis.
    }

    private func ensureAudioEventConsumer() {
        guard audioEventTask == nil, !isShutdown else { return }
        let events = dependencies.audioSession.events
        audioEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handleAudioSessionEvent(event)
            }
        }
    }

    private func performVoicePreflight(generation: UInt64) async {
        var audioActivationAttempted = false
        var recognizerPreparationAttempted = false
        do {
            microphonePermissionAwaitCounter &+= 1
            let permissionAwaitID = microphonePermissionAwaitCounter
            activeMicrophonePermissionAwaitID = permissionAwaitID
            let allowed = await dependencies.microphonePermission.requestAccess()
            await waitForMicrophonePermissionCompletionIfDeferred(permissionAwaitID)
            if activeMicrophonePermissionAwaitID == permissionAwaitID {
                activeMicrophonePermissionAwaitID = nil
            }
            guard isCurrent(generation) else { return }
            guard allowed else {
                microphoneWasAllowed = false
                wantsListening = false
                publish(.microphoneDenied)
                return
            }
            microphoneWasAllowed = true

            let availability = await dependencies.modelAvailability.availability()
            guard isCurrent(generation) else { return }
            guard availability == .available else {
                wantsListening = false
                publish(.modelUnavailable(availability))
                return
            }

            try await dependencies.memory.prepareMemory()
            guard isCurrent(generation) else { return }
            viewState.memoryState = await dependencies.memory.memoryState()
            guard isCurrent(generation) else { return }
            try await dependencies.speaker.prepare()
            guard isCurrent(generation) else { return }
            audioActivationAttempted = true
            try await dependencies.audioSession.activate()
            guard isCurrent(generation) else { return }
            recognizerPreparationAttempted = true
            try await dependencies.recognizer.prepare()
            guard isCurrent(generation) else { return }
            await dependencies.reply.prewarm()
            guard isCurrent(generation) else { return }
            try await startCapture(generation: generation, recognizerIsPrepared: true)
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return }
            if error is ConversationMemoryError {
                let state = await dependencies.memory.memoryState()
                guard isCurrent(generation) else { return }
                wantsListening = false
                viewState.memoryState = state
                transition(to: .paused)
                return
            }
            let serviceError = Self.serviceError(from: error)
            if audioActivationAttempted {
                await finishVoiceFailure(
                    with: serviceError,
                    stopRecognizer: recognizerPreparationAttempted,
                    owner: .lifecycle(generation: generation)
                )
            } else {
                wantsListening = false
                publish(serviceError)
            }
        }
    }

    private func performTypedTurn(
        _ submitted: String,
        shouldResumeVoice: Bool,
        generation: UInt64,
        turnID: UInt64
    ) async {
        let oldCapture = captureTask
        let oldClosing = closingTask
        let hadCapture = activeCaptureID != nil
            || oldCapture != nil
            || oldClosing != nil
        if hadCapture {
            segmentationTask?.cancel()
            segmentationTask = nil
            activeCaptureID = nil
            captureTask = nil
            closingTask = nil
            captureIsClosing = false
            closingTailSegments.removeAll(keepingCapacity: true)
            segmenter = UtteranceSegmenter()
            latestCaptureActivityAt = nil
            if let oldClosing {
                await oldClosing.value
            } else {
                await dependencies.recognizer.stop()
                await oldCapture?.value
            }
        }
        guard isTypedTurnCurrent(generation, turnID: turnID),
              !Task.isCancelled else { return }
        viewState.provisionalTranscript = ""
        if viewState.typedText == submitted {
            viewState.typedText = ""
        }

        do {
            let availability = await dependencies.modelAvailability.availability()
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            guard availability == .available else {
                await finishTypedTurn(
                    with: .modelUnavailable(availability),
                    includesTypedFallback: true,
                    generation: generation,
                    turnID: turnID
                )
                return
            }

            try await dependencies.memory.prepareMemory()
            guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            viewState.memoryState = await dependencies.memory.memoryState()
            guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await dependencies.reply.prewarm()
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            try await dependencies.speaker.prepare()
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            try await dependencies.audioSession.activate()
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            await generateTypedReply(
                to: submitted,
                shouldResumeVoice: shouldResumeVoice,
                generation: generation,
                turnID: turnID
            )
        } catch {
            if error is ConversationMemoryError {
                let state = await dependencies.memory.memoryState()
                guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                viewState.memoryState = state
                transition(to: .paused)
                return
            }
            let serviceError = Self.serviceError(from: error)
            await finishTypedTurn(
                with: serviceError,
                includesTypedFallback: true,
                generation: generation,
                turnID: turnID
            )
        }
    }

    private func generateTypedReply(
        to submitted: String,
        shouldResumeVoice: Bool,
        generation: UInt64,
        turnID: UInt64
    ) async {
        let trace = ReplyTrace(sink: dependencies.replyTraceSink, now: dependencies.now)
        transition(to: .thinking)
        playbackMouthSequence = SpeechMouthPoseSequence()
        do {
            _ = try await replyPlayback.run(prompt: submitted, trace: trace) { [weak self] update in
                guard let self, self.isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                self.applyPlaybackUpdate(update)
            }
            guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            if shouldResumeVoice {
                engagement.arm(at: dependencies.now())
                wantsListening = true
                do {
                    try await startCapture(generation: generation, recognizerIsPrepared: false)
                } catch {
                    guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                    wantsListening = false
                    await dependencies.recognizer.stop()
                    await finishTypedTurn(with: Self.serviceError(from: error), generation: generation, turnID: turnID)
                }
            } else {
                await dependencies.audioSession.deactivate()
                guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                transition(to: .paused)
            }
        } catch {
            guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            let policy = ReplyFailurePolicy(error: Self.serviceError(from: error))
            await finishTypedTurn(
                with: policy.error,
                includesTypedFallback: policy.includesTypedFallback,
                resetsReplySession: policy.resetsReplySession,
                speakerAlreadyStopped: true,
                generation: generation,
                turnID: turnID
            )
        }
    }

    private func applyPlaybackUpdate(_ update: ReplyPlaybackUpdate) {
        switch update {
        case .caption(let text): viewState.caption = text
        case .speechStarted:
            transition(to: .speaking)
            viewState.mouthPose = .small
        case .sentenceStarted:
            viewState.mouthPose = playbackMouthSequence.nextWordPose()
        case .sentenceFinished:
            viewState.mouthPose = .closed
        case .speechFinished:
            transition(to: .thinking)
            viewState.mouthPose = .closed
        }
    }

    private func finishTypedTurn(
        with error: ConversationServiceError,
        includesTypedFallback: Bool = false,
        resetsReplySession: Bool = false,
        speakerAlreadyStopped: Bool = false,
        generation: UInt64,
        turnID: UInt64
    ) async {
        await stopTurnAudio(
            speakerAlreadyStopped: speakerAlreadyStopped,
            stopRecognizer: false,
            resetsReplySession: resetsReplySession
        )
        guard isTypedTurnCurrent(generation, turnID: turnID),
              !Task.isCancelled else { return }
        publish(error, includesTypedFallback: includesTypedFallback)
    }

    /// Stops a turn's audio in a fixed order: join playback, then the speaker,
    /// the recognizer, the audio session and finally the reply session.
    private func stopTurnAudio(
        speakerAlreadyStopped: Bool,
        stopRecognizer: Bool,
        resetsReplySession: Bool
    ) async {
        await replyPlayback.cancelAndWait()
        if !speakerAlreadyStopped { await dependencies.speaker.stop() }
        if stopRecognizer {
            await dependencies.recognizer.stop()
        }
        await dependencies.audioSession.deactivate()
        if resetsReplySession {
            await dependencies.reply.reset()
        }
    }

    private func startCapture(
        generation: UInt64,
        recognizerIsPrepared: Bool
    ) async throws {
        guard isCurrent(generation) else { return }
        if !recognizerIsPrepared {
            try await dependencies.recognizer.prepare()
            guard isCurrent(generation) else { return }
        }

        let stream = try await dependencies.recognizer.start()
        guard isCurrent(generation) else {
            await dependencies.recognizer.stop()
            return
        }

        captureCounter &+= 1
        let captureID = captureCounter
        activeCaptureID = captureID
        captureIsClosing = false
        closingTailSegments.removeAll(keepingCapacity: true)
        segmenter = UtteranceSegmenter()
        latestCaptureActivityAt = nil
        transition(to: .listening)
        viewState.provisionalTranscript = ""

        captureTask = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    self?.receiveRecognition(
                        event,
                        generation: generation,
                        captureID: captureID
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self?.captureFailed(
                    error,
                    generation: generation,
                    captureID: captureID
                )
            }
        }
    }

    private func receiveRecognition(
        _ event: SpeechRecognitionEvent,
        generation: UInt64,
        captureID: UInt64
    ) {
        guard isCurrent(generation), activeCaptureID == captureID else { return }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if captureIsClosing {
            if !text.isEmpty {
                voiceLatency.noteASRActivity(generation: generation, captureID: captureID)
                if event.isFinal {
                    closingTailSegments.append(text)
                }
            }
            return
        }
        guard !text.isEmpty else {
            if event.isFinal {
                presentUnrecognizedSpeechWhileListening()
            }
            return
        }

        let timestamp = dependencies.now()
        segmenter.receive(event, at: timestamp)
        latestCaptureActivityAt = timestamp
        viewState.provisionalTranscript = text

        if let utterance = segmenter.utteranceIfReady(at: timestamp) {
            beginClosingCapture(
                utterance: utterance,
                generation: generation,
                captureID: captureID,
                boundaryAt: timestamp
            )
        } else if segmenter.hasActivity {
            scheduleSegmentationFlush(
                generation: generation,
                captureID: captureID,
                at: timestamp
            )
        } else {
            synchronizeCaptureTimingWithSegmenter()
            return
        }
        onPendingSpeechChange()
    }

    private func synchronizeCaptureTimingWithSegmenter() {
        guard !segmenter.hasActivity else { return }
        segmentationTask?.cancel()
        segmentationTask = nil
        latestCaptureActivityAt = nil
        onPendingSpeechChange()
    }

    private func presentUnrecognizedSpeechWhileListening() {
        segmentationTask?.cancel()
        segmentationTask = nil
        segmenter = UtteranceSegmenter()
        latestCaptureActivityAt = nil
        viewState.provisionalTranscript = ""
        let presentation = ConversationErrorPresentation(.speechUnrecognized)
        viewState.errorMessage = presentation.message
        viewState.recoveries = presentation.recoveries
        onPendingSpeechChange()
    }

    private func scheduleSegmentationFlush(
        generation: UInt64,
        captureID: UInt64,
        at timestamp: TimeInterval
    ) {
        segmentationTask?.cancel()
        let delay = segmenter.flushDelay(at: timestamp)
        segmentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(generation),
                  self.activeCaptureID == captureID else { return }
            await self.flushSegmentation(at: self.dependencies.now())
        }
    }

    private func beginClosingCapture(
        utterance: String,
        generation: UInt64,
        captureID: UInt64,
        boundaryAt: TimeInterval
    ) {
        guard isCurrent(generation),
              activeCaptureID == captureID,
              !captureIsClosing else { return }

        dependencies.motion.utteranceConfirmed()
        captureIsClosing = true
        segmentationTask?.cancel()
        segmentationTask = nil
        turnCounter &+= 1
        let turnID = turnCounter
        activeTurnID = turnID
        voiceLatency.begin(
            generation: generation,
            captureID: captureID,
            turnID: turnID,
            boundaryAt: boundaryAt,
            lastASRActivityAt: latestCaptureActivityAt,
            segmentationInterval: segmenter.silenceInterval
        )
        let consumer = captureTask
        closingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dependencies.recognizer.stop()
            await consumer?.value
            await self.finishClosingCapture(
                utterance: utterance,
                generation: generation,
                captureID: captureID,
                turnID: turnID
            )
        }
    }

    private func finishClosingCapture(
        utterance: String,
        generation: UInt64,
        captureID: UInt64,
        turnID: UInt64
    ) async {
        guard isCurrent(generation),
              activeCaptureID == captureID,
              activeTurnID == turnID else { return }
        voiceLatency.trace?.mark(.captureClosed)
        let completedUtterance = ([utterance] + closingTailSegments).joined()
        activeCaptureID = nil
        captureTask = nil
        closingTask = nil
        captureIsClosing = false
        closingTailSegments.removeAll(keepingCapacity: true)
        latestCaptureActivityAt = nil
        viewState.provisionalTranscript = ""

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTurn(
                completedUtterance,
                generation: generation,
                turnID: turnID
            )
        }
        turnTask = task
        await task.value
        if activeTurnID == turnID {
            turnTask = nil
        }
    }

    private func performTurn(
        _ utterance: String,
        generation: UInt64,
        turnID: UInt64
    ) async {
        guard isCurrent(generation, turnID: turnID) else { return }
        let timestamp = dependencies.now()
        if let pendingClarification,
           timestamp >= pendingClarification.expiresAt {
            clearPendingClarification()
        }
        let isCorrectingPending = pendingClarification != nil
        let wasEngaged = engagement.isActive(at: timestamp)
        let explicitWakeRoute = dependencies.addresseePolicy.route(
            utterance,
            at: timestamp,
            engagement: .inactive,
            pending: nil
        )
        let isExplicitWake: Bool
        switch explicitWakeRoute {
        case .wakeOnly, .accept(_):
            isExplicitWake = true
        case .classify(_), .dismissPending, .ignore:
            isExplicitWake = false
        }
        let route = dependencies.addresseePolicy.route(
            utterance,
            at: timestamp,
            engagement: engagement,
            pending: pendingClarification
        )

        switch route {
        case .wakeOnly:
            onAddressedActivity()
            clearPendingClarification()
            voiceLatency.selectPath(.fast, generation: generation, turnID: turnID)
            await speakAndResume(
                "なあに？",
                engagementUpdate: .arm,
                generation: generation,
                turnID: turnID
            )
        case .accept(let accepted):
            onAddressedActivity()
            clearPendingClarification()
            voiceLatency.selectPath(.fast, generation: generation, turnID: turnID)
            await generateReply(
                to: accepted,
                engagementUpdate: isExplicitWake || !wasEngaged ? .arm : .refresh,
                generation: generation,
                turnID: turnID
            )
        case .classify(let candidate):
            clearPendingClarification()
            voiceLatency.selectPath(.classified, generation: generation, turnID: turnID)
            transition(to: .classifying)
            do {
                let trace = voiceLatency.trace
                trace?.mark(.classificationStarted)
                var classificationOutcome = ReplyTraceOutcome.generationFailure
                let target = try await ReplyTraceContext.$current.withValue(trace) {
                    defer { trace?.mark(.classificationFinished, outcome: classificationOutcome) }
                    let value = try await dependencies.classifier.classify(candidate)
                    classificationOutcome = .success
                    return value
                }
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                switch target {
                case .addressed:
                    onAddressedActivity()
                    clearPendingClarification()
                    await generateReply(
                        to: candidate,
                        engagementUpdate: .arm,
                        generation: generation,
                        turnID: turnID
                    )
                case .notAddressed:
                    voiceLatency.cancel(reason: .noResponse, ifOwnedBy: .turn(generation: generation, turnID: turnID))
                    await resumeCapture(generation: generation, turnID: turnID)
                case .ambiguous:
                    voiceLatency.cancel(reason: .ambiguous, ifOwnedBy: .turn(generation: generation, turnID: turnID))
                    if isCorrectingPending {
                        await resumeCapture(generation: generation, turnID: turnID)
                    } else {
                        setPendingClarification(
                            utterance: candidate,
                            at: dependencies.now(),
                            generation: generation
                        )
                        await speakAndResume(
                            "今の、ぼくに言った？",
                            presentationPhase: .clarifying,
                            engagementUpdate: .none,
                            generation: generation,
                            turnID: turnID
                        )
                    }
                }
            } catch {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                await finishVoiceFailure(
                    with: Self.serviceError(from: error),
                    stopRecognizer: false,
                    owner: .turn(generation: generation, turnID: turnID)
                )
            }
        case .dismissPending:
            clearPendingClarification()
            voiceLatency.cancel(reason: .noResponse, ifOwnedBy: .turn(generation: generation, turnID: turnID))
            await resumeCapture(generation: generation, turnID: turnID)
        case .ignore:
            voiceLatency.cancel(reason: .noResponse, ifOwnedBy: .turn(generation: generation, turnID: turnID))
            await resumeCapture(generation: generation, turnID: turnID)
        }
    }

    private func setPendingClarification(
        utterance: String,
        at timestamp: TimeInterval,
        generation: UInt64
    ) {
        clearPendingClarification()
        pendingClarification = PendingClarification(
            utterance: utterance,
            at: timestamp
        )
        pendingClarificationExpirationCounter &+= 1
        let expirationID = pendingClarificationExpirationCounter
        activePendingClarificationExpirationID = expirationID
        let delay = dependencies.clarificationDelay

        pendingClarificationExpirationTask = Task { @MainActor [weak self] in
            await delay(.seconds(PendingClarification.duration))
            guard !Task.isCancelled,
                  let self,
                  self.lifecycleGeneration == generation,
                  self.activePendingClarificationExpirationID == expirationID else { return }
            self.pendingClarification = nil
            self.activePendingClarificationExpirationID = nil
            self.pendingClarificationExpirationTask = nil
        }
    }

    private func clearPendingClarification() {
        pendingClarificationExpirationTask?.cancel()
        pendingClarificationExpirationTask = nil
        activePendingClarificationExpirationID = nil
        pendingClarification = nil
    }

    private func generateReply(
        to utterance: String,
        engagementUpdate: EngagementUpdate,
        generation: UInt64,
        turnID: UInt64
    ) async {
        let trace = voiceLatency.trace
        transition(to: .thinking)
        playbackMouthSequence = SpeechMouthPoseSequence()
        do {
            _ = try await replyPlayback.run(prompt: utterance, trace: trace) { [weak self] update in
                guard let self, self.isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                self.applyPlaybackUpdate(update)
                switch update {
                case .caption(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    self.voiceLatency.recordFirstCaption(generation: generation, turnID: turnID)
                case .speechStarted:
                    self.voiceLatency.recordSpeechStarted(generation: generation, turnID: turnID)
                default: break
                }
            }
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            switch engagementUpdate {
            case .arm: engagement.arm(at: dependencies.now())
            case .refresh: engagement.refresh(afterReplyAt: dependencies.now())
            case .none: break
            }
            await resumeCapture(generation: generation, turnID: turnID)
        } catch {
            let policy = ReplyFailurePolicy(error: Self.serviceError(from: error))
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await finishVoiceFailure(
                with: policy.error,
                includesTypedFallback: policy.includesTypedFallback,
                resetsReplySession: policy.resetsReplySession,
                speakerAlreadyStopped: true,
                stopRecognizer: false,
                owner: .turn(generation: generation, turnID: turnID)
            )
        }
    }

    private func speakAndResume(
        _ text: String,
        presentationPhase: ConversationPhase = .speaking,
        engagementUpdate: EngagementUpdate,
        generation: UInt64,
        turnID: UInt64
    ) async {
        let trace = voiceLatency.trace
        trace?.mark(.speechEnqueued, part: .full)
        transition(to: presentationPhase, caption: text)
        voiceLatency.recordFirstCaption(generation: generation, turnID: turnID)
        do {
            let stream = try await dependencies.speaker.speak(text)
            var finishedNormally = false
            var mouthSequence = SpeechMouthPoseSequence()
            for try await event in stream {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                switch event {
                case .started:
                    trace?.mark(.speechStarted, part: .full, source: .started)
                    voiceLatency.recordSpeechStarted(generation: generation, turnID: turnID)
                    viewState.mouthPose = .small
                case .willSpeak:
                    trace?.mark(.speechStarted, part: .full, source: .willSpeakFallback)
                    voiceLatency.recordSpeechStarted(generation: generation, turnID: turnID)
                    viewState.mouthPose = mouthSequence.nextWordPose()
                case .finished:
                    trace?.mark(.speechFinished, part: .full)
                    finishedNormally = true
                    viewState.mouthPose = .closed
                case .cancelled:
                    throw ConversationServiceError.speechSynthesisFailed
                }
            }
            guard isCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            guard finishedNormally else {
                throw ConversationServiceError.speechSynthesisFailed
            }

            trace?.finish(.success)
            switch engagementUpdate {
            case .arm:
                engagement.arm(at: dependencies.now())
            case .refresh:
                engagement.refresh(afterReplyAt: dependencies.now())
            case .none:
                break
            }
            await resumeCapture(generation: generation, turnID: turnID)
        } catch {
            trace?.finish(Task.isCancelled ? .cancelled : .speechFailure)
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await finishVoiceFailure(
                with: Self.serviceError(from: error),
                stopRecognizer: false,
                owner: .turn(generation: generation, turnID: turnID)
            )
        }
    }

    private func resumeCapture(generation: UInt64, turnID: UInt64) async {
        guard isCurrent(generation, turnID: turnID), wantsListening else { return }
        // A conforming speaker may finish without reporting a start event.
        // Cancel any still-open measurement before releasing the turn token.
        voiceLatency.cancel(reason: .failure, ifOwnedBy: .turn(generation: generation, turnID: turnID))
        activeTurnID = nil
        do {
            try await startCapture(generation: generation, recognizerIsPrepared: false)
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return }
            await finishVoiceFailure(
                with: Self.serviceError(from: error),
                stopRecognizer: true,
                owner: .lifecycle(generation: generation)
            )
        }
    }

    private func captureFailed(
        _ error: any Error,
        generation: UInt64,
        captureID: UInt64
    ) async {
        guard isCurrent(generation),
              activeCaptureID == captureID,
              !captureIsClosing else { return }
        await finishVoiceFailure(
            with: Self.serviceError(from: error),
            stopRecognizer: true,
            owner: .capture(generation: generation, captureID: captureID)
        )
    }

    private func finishVoiceFailure(
        with error: ConversationServiceError,
        includesTypedFallback: Bool = false,
        resetsReplySession: Bool = false,
        speakerAlreadyStopped: Bool = false,
        stopRecognizer: Bool,
        owner: ConversationTurnOwner
    ) async {
        guard ownsVoiceFailure(owner), !Task.isCancelled else { return }
        voiceLatency.cancel(reason: .failure, ifOwnedBy: owner)
        wantsListening = false
        clearPendingClarification()
        engagement.clear()
        segmentationTask?.cancel()
        segmentationTask = nil

        failureCounter &+= 1
        let failureID = failureCounter
        activeFailureID = failureID
        let cleanup = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performVoiceFailureCleanup(
                with: error,
                includesTypedFallback: includesTypedFallback,
                resetsReplySession: resetsReplySession,
                speakerAlreadyStopped: speakerAlreadyStopped,
                stopRecognizer: stopRecognizer,
                owner: owner,
                failureID: failureID
            )
        }
        failureCleanupTask = cleanup
        await cleanup.value
    }

    private func performVoiceFailureCleanup(
        with error: ConversationServiceError,
        includesTypedFallback: Bool,
        resetsReplySession: Bool,
        speakerAlreadyStopped: Bool,
        stopRecognizer: Bool,
        owner: ConversationTurnOwner,
        failureID: UInt64
    ) async {
        await stopTurnAudio(
            speakerAlreadyStopped: speakerAlreadyStopped,
            stopRecognizer: stopRecognizer,
            resetsReplySession: resetsReplySession
        )

        if activeFailureID == failureID, ownsVoiceFailure(owner) {
            if case .lifecycle = owner {
                preflightOwnership.invalidate()
                preflightTask = nil
            }
            if case .capture(_, let captureID) = owner,
               activeCaptureID == captureID {
                activeCaptureID = nil
                captureTask = nil
                captureIsClosing = false
                closingTailSegments.removeAll(keepingCapacity: true)
                segmenter = UtteranceSegmenter()
                latestCaptureActivityAt = nil
                viewState.provisionalTranscript = ""
            }
            publish(error, includesTypedFallback: includesTypedFallback)
        }
        if activeFailureID == failureID {
            activeFailureID = nil
            failureCleanupTask = nil
        }
    }

    private func pauseConversation(force: Bool = false, awaitsTapResume: Bool = false) async {
        viewState.isAwaitingTapToResume = awaitsTapResume
        actionIntentCounter &+= 1
        voiceLatency.cancel(reason: .lifecycle)
        activeMicrophonePermissionAwaitID = nil
        releaseMicrophonePermissionCompletion()
        if let failureCleanupTask {
            lifecycleGeneration &+= 1
            let transitionID = transitionOwnership.begin()
            invalidateForPause()
            // The failure cleanup owns the audio teardown, so capture work is cancelled rather than stopped.
            let detached = detachInFlightTasks(cancelsCapture: true)

            let cleanup = Task { @MainActor in
                await failureCleanupTask.value
                await detached.preflight?.value
                await detached.capture?.value
                await detached.closing?.value
                await detached.turn?.value
            }
            lifecycleTransitionTask = cleanup
            await cleanup.value
            if transitionOwnership.finish(transitionID) {
                lifecycleTransitionTask = nil
            }
            return
        }
        if let lifecycleTransitionTask {
            lifecycleGeneration &+= 1
            invalidateForPause()
            await lifecycleTransitionTask.value
            return
        }
        if !force, viewState.phase == .paused {
            return
        }

        lifecycleGeneration &+= 1
        let transitionID = transitionOwnership.begin()
        invalidateForPause()
        let detached = detachInFlightTasks(cancelsCapture: false)

        let cleanup = Task { @MainActor [dependencies, replyPlayback] in
            await detached.preflight?.value
            await replyPlayback.cancelAndWait()
            await dependencies.speaker.stop()
            await dependencies.recognizer.stop()
            await detached.capture?.value
            await detached.closing?.value
            await detached.turn?.value
            await dependencies.audioSession.deactivate()
        }
        lifecycleTransitionTask = cleanup
        await cleanup.value
        if transitionOwnership.finish(transitionID) {
            lifecycleTransitionTask = nil
        }
    }

    /// The synchronous part of a pause once the generation has advanced:
    /// drop the listening intent, engagement and clarification, then show paused.
    private func invalidateForPause() {
        wantsListening = false
        engagement.clear()
        clearPendingClarification()
        transition(to: .paused)
    }

    /// Detaches in-flight work from the view model. Preflight and turn are cancelled;
    /// capture and closing are cancelled only when `cancelsCapture`, otherwise the
    /// caller ends them by stopping the recognizer.
    private func detachInFlightTasks(cancelsCapture: Bool) -> DetachedLifecycleTasks {
        segmentationTask?.cancel()
        segmentationTask = nil
        let preflight = preflightTask
        preflightTask = nil
        preflightOwnership.invalidate()
        preflight?.cancel()
        let turn = turnTask
        turnTask = nil
        turn?.cancel()
        let capture = captureTask
        captureTask = nil
        if cancelsCapture { capture?.cancel() }
        let closing = closingTask
        closingTask = nil
        if cancelsCapture { closing?.cancel() }
        activeCaptureID = nil
        activeTurnID = nil
        captureIsClosing = false
        closingTailSegments.removeAll(keepingCapacity: true)
        return DetachedLifecycleTasks(preflight: preflight, turn: turn, capture: capture, closing: closing)
    }

    /// Waits for `task`; false when a later start, typed or pause intent arrived meanwhile.
    /// The yield lets an already-enqueued later intent publish before this one decides it still owns the action.
    private func awaitTaskKeepingIntent(
        _ task: Task<Void, Never>,
        checkpoint: ConversationLifecycleCheckpoint? = nil
    ) async -> Bool {
        actionIntentCounter &+= 1
        let intent = actionIntentCounter
        if let checkpoint { await dependencies.lifecycleCheckpoint(checkpoint) }
        await task.value
        await Task.yield()
        return actionIntentCounter == intent
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation && wantsListening && !isShutdown
    }

    private func waitForMicrophonePermissionCompletionIfDeferred(_ id: UInt64) async {
        while deferredMicrophonePermissionAwaitID == id,
              activeMicrophonePermissionAwaitID == id {
            await withCheckedContinuation { continuation in
                guard deferredMicrophonePermissionAwaitID == id,
                      activeMicrophonePermissionAwaitID == id else {
                    continuation.resume()
                    return
                }
                microphonePermissionCompletionWaiter = continuation
            }
        }
    }

    private func isCurrent(_ generation: UInt64, turnID: UInt64) -> Bool {
        isCurrent(generation) && activeTurnID == turnID
    }

    private func isTypedTurnCurrent(_ generation: UInt64, turnID: UInt64) -> Bool {
        lifecycleGeneration == generation
            && activeTurnID == turnID
            && !isShutdown
            && !isShuttingDown
    }

    private func ownsVoiceFailure(_ owner: ConversationTurnOwner) -> Bool {
        guard !isShutdown, !isShuttingDown else { return false }
        switch owner {
        case .lifecycle(let generation):
            return lifecycleGeneration == generation
        case .turn(let generation, let turnID):
            return lifecycleGeneration == generation && activeTurnID == turnID
        case .capture(let generation, let captureID):
            return lifecycleGeneration == generation && activeCaptureID == captureID
        }
    }

    private func transition(
        to phase: ConversationPhase,
        caption: String? = nil
    ) {
        announcePhase(phase)
        switch phase {
        case .classifying, .thinking, .clarifying:
            clearNotice()   // 次に話しかけたら通知は役目を終える
        default:
            break
        }
        viewState.enter(phase, caption: caption)
        onPhaseChange(phase)
    }

    private func publish(
        _ error: ConversationServiceError,
        includesTypedFallback: Bool = false
    ) {
        viewState.isAwaitingTapToResume = false
        let presentation = ConversationErrorPresentation(error)
        var recoveries = presentation.recoveries
        if includesTypedFallback,
           !presentation.offersTypedInput {
            recoveries.append(.typedInput)
        }
        resetTurnPresentation(stopping: .playbackFailed)
        announcePhase(.failed(error))
        viewState.presentFailure(
            error: error,
            message: presentation.message,
            recoveries: recoveries
        )
        onPhaseChange(viewState.phase)
    }

    private static func serviceError(from error: any Error) -> ConversationServiceError {
        if let serviceError = error as? ConversationServiceError {
            return serviceError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .modelGenerationFailed
    }
}
