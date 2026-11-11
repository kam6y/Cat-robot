import Foundation
import Observation
import os

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

    /// 失敗の起点が資源をどこまで進めていたか（所有者の種類は ConversationTurnOwner が持つ）。
    /// turn: audio session は有効。preflight: 開始前で、有効化と認識の準備をどこまで試みたか。
    private enum FailureOrigin {
        case turn(stopRecognizer: Bool)
        case preflight(audioActivationAttempted: Bool, recognizerAttempted: Bool)
    }

    /// 失敗の終わりに反映する結果。
    private enum FailureOutcome {
        case publish(ConversationServiceError, includesTypedFallback: Bool)
        case memoryPaused(ConversationMemoryState)
    }

    private static let guidanceLogger = Logger(subsystem: "com.kamby.CatRobot", category: "ConversationFailureGuidance")

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
    @ObservationIgnored private var failureSpeechTask: Task<Void, Never>?
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

    /// rechecksAvailability は「もう一度確認」の操作だけが true にする（使えなかった会話モデルを開始の中で 1 回確かめ直す）。
    func startConversation(rechecksAvailability: Bool = false) async {
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
            await self.performVoicePreflight(generation: generation, rechecksAvailability: rechecksAvailability)
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
        var rechecksAvailability = false
        if case .failed(.modelUnavailable) = viewState.phase { rechecksAvailability = true }
        viewState.errorMessage = nil
        viewState.recoveries = []
        switch viewState.phase {
        case .failed, .paused, .idle:
            await startConversation(rechecksAvailability: rechecksAvailability)
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

        if viewState.isSpeakingFailureGuidance, let failureCleanupTask {
            // 失敗の案内を読み上げている間の文字入力は、受理した時点で置き換えが確定する。
            // 最初の await より前に、古い所有者の無効化とこの要求の意図の採取を同時に済ませる。
            // awaitTaskKeepingIntent は使わない（呼び出し時に新しい意図を採るため、stop 中に来た一時停止などを追い越してしまう）。
            actionIntentCounter &+= 1
            let intent = actionIntentCounter
            lifecycleGeneration &+= 1
            let generation = lifecycleGeneration
            activeTurnID = nil
            failureSpeechTask?.cancel()
            await dependencies.speaker.stop()
            guard actionIntentCounter == intent else { return }
            await failureCleanupTask.value
            await Task.yield()
            guard actionIntentCounter == intent, lifecycleGeneration == generation else { return }
            if let lifecycleTransitionTask {
                await lifecycleTransitionTask.value
                await Task.yield()
                guard actionIntentCounter == intent, lifecycleGeneration == generation else { return }
            }
            // 受理済みの置き換えは phase（.speaking のまま）を見ない。
            guard !isShutdown, !isShuttingDown, !memoryActionInProgress, !viewState.isSleeping,
                  !viewState.memoryPresentation.blocksConversation else { return }
        } else {
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
        }
        onAddressedActivity()
        ensureMemoryEventConsumer()

        voiceLatency.cancel(reason: .typedReplacement)
        ensureAudioEventConsumer()
        let shouldResumeVoice = wantsListening
            && microphoneWasAllowed
            && activeCaptureID != nil
        // 音声の会話中（聞き取り・確認待ちなど）に来た文字入力は、音声側が有効化した audio session を引き継ぐ。
        // 失敗の操作はこれを「有効化を試みた」と扱い、案内の準備を省いて 1 回だけ解除する。
        let inheritsAudioSession = wantsListening && microphoneWasAllowed
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
                inheritsAudioSession: inheritsAudioSession,
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
        case .outputVolumeChanged:
            guard !isShutdown, !isShuttingDown, !Task.isCancelled else { return }
            let volume = await dependencies.audioSession.outputVolume
            guard !isShutdown, !isShuttingDown, !Task.isCancelled else { return }
            let isMuted = volume == 0
            if viewState.isAudioOutputMuted != isMuted {
                viewState.isAudioOutputMuted = isMuted
            }
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

    /// 長期メモと短期の会話記憶を消す。失敗時は忘却の復旧経路を保つ。
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

    /// 会話を新しく始め直す（Hermes では新しい session に替わる）。進行中のターンは取り消すが、
    /// 前の会話を Hermes から消したり、前の run を止めたと扱ったりはしない。
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
            await self?.handleAudioSessionEvent(.outputVolumeChanged)
            for await event in events {
                guard let self else { return }
                await self.handleAudioSessionEvent(event)
            }
        }
    }

    private func performVoicePreflight(generation: UInt64, rechecksAvailability: Bool) async {
        var audioActivationAttempted = false
        var recognizerPreparationAttempted = false
        let owner = ConversationTurnOwner.lifecycle(generation: generation)
        if rechecksAvailability {
            // マイクの許可より前に確かめる（文字だけで話す人も同じ操作で戻れる）。待つ間に場面が変われば、ここで止める。
            await dependencies.modelAvailability.recheckAvailability()
            guard isCurrent(generation) else { return }
        }
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
                // マイク拒否は声なし（spokenGuidance が nil）。音声出力の準備もしない。
                await finishFailure(.publish(.microphoneDenied, includesTypedFallback: false), guidance: nil,
                                    origin: .preflight(audioActivationAttempted: false, recognizerAttempted: false),
                                    owner: owner)
                return
            }
            microphoneWasAllowed = true

            let availability = await dependencies.modelAvailability.availability()
            guard isCurrent(generation) else { return }
            guard availability == .available else {
                let error = ConversationServiceError.modelUnavailable(availability)
                await finishFailure(.publish(error, includesTypedFallback: false), guidance: error.spokenGuidance,
                                    origin: .preflight(audioActivationAttempted: false, recognizerAttempted: false),
                                    owner: owner)
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
            // 開始前の失敗は、audio session と認識をどこまで試みたかを失敗の操作に渡す（試みた以上は止めて解除する）。
            let origin = FailureOrigin.preflight(audioActivationAttempted: audioActivationAttempted,
                                                 recognizerAttempted: recognizerPreparationAttempted)
            if error is ConversationMemoryError {
                let state = await dependencies.memory.memoryState()
                guard isCurrent(generation) else { return }
                await finishFailure(.memoryPaused(state), guidance: ConversationFailureGuidance.memory,
                                    origin: origin, owner: owner)
                return
            }
            let serviceError = Self.serviceError(from: error)
            await finishFailure(.publish(serviceError, includesTypedFallback: false),
                                guidance: serviceError.spokenGuidance, origin: origin, owner: owner)
        }
    }

    private func performTypedTurn(
        _ submitted: String,
        shouldResumeVoice: Bool,
        inheritsAudioSession: Bool,
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

        // 開始前の失敗は、audio session をどこまで試みたかを失敗の操作に渡す（試みた以上は解除する）。
        // 音声から引き継いだ audio session は最初から「試みた」扱い。
        var audioActivationAttempted = inheritsAudioSession
        do {
            let availability = await dependencies.modelAvailability.availability()
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            guard availability == .available else {
                await finishTypedTurn(
                    with: .modelUnavailable(availability),
                    includesTypedFallback: true,
                    origin: .preflight(audioActivationAttempted: audioActivationAttempted, recognizerAttempted: false),
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
            audioActivationAttempted = true
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
            guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            let origin = FailureOrigin.preflight(audioActivationAttempted: audioActivationAttempted,
                                                 recognizerAttempted: false)
            if error is ConversationMemoryError {
                let state = await dependencies.memory.memoryState()
                guard isTypedTurnCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                await finishFailure(.memoryPaused(state), guidance: ConversationFailureGuidance.memory,
                                    origin: origin, owner: .turn(generation: generation, turnID: turnID))
                return
            }
            await finishTypedTurn(
                with: Self.serviceError(from: error),
                includesTypedFallback: true,
                origin: origin,
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

    /// 文字入力ターンの失敗。所有者は .turn(generation, turnID)（ownsVoiceFailure の判定は isTypedTurnCurrent と同じ条件）。
    private func finishTypedTurn(
        with error: ConversationServiceError,
        includesTypedFallback: Bool = false,
        resetsReplySession: Bool = false,
        origin: FailureOrigin = .turn(stopRecognizer: false),
        generation: UInt64,
        turnID: UInt64
    ) async {
        await finishFailure(
            .publish(error, includesTypedFallback: includesTypedFallback),
            guidance: error.spokenGuidance,
            origin: origin,
            owner: .turn(generation: generation, turnID: turnID),
            resetsReplySession: resetsReplySession
        )
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
        if let signal = event.audioTurnEnd {
            let timestamp = dependencies.now()
            guard !captureIsClosing, signal.isValid(at: timestamp),
                  let prefix = segmenter.closeForAudioEndpoint() else { return }
            beginClosingCapture(utterance: prefix, generation: generation, captureID: captureID,
                                boundaryAt: timestamp, silenceIntervalUsed: 0)
            onPendingSpeechChange()
            return
        }
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
        boundaryAt: TimeInterval,
        silenceIntervalUsed: TimeInterval? = nil
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
            segmentationInterval: silenceIntervalUsed ?? segmenter.silenceInterval
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
        // Keep the routing-start context even if the pending timer expires during classification.
        let clarification = pendingClarification.map { ClarificationContext(originalUtterance: $0.utterance) }
        let isCorrectingPending = clarification != nil
        let wasEngaged = engagement.isActive(at: timestamp)
        let isFacingScreen = dependencies.isFacingScreen()
        let route = dependencies.addresseePolicy.route(
            utterance,
            at: timestamp,
            engagement: engagement,
            pending: pendingClarification,
            isFacingScreen: isFacingScreen
        )

        switch route {
        case .accept(let accepted):
            onAddressedActivity()
            clearPendingClarification()
            voiceLatency.selectPath(.fast, generation: generation, turnID: turnID)
            await generateReply(
                to: accepted,
                engagementUpdate: isFacingScreen || !wasEngaged ? .arm : .refresh,
                generation: generation,
                turnID: turnID
            )
        case .classify(let candidate):
            let request = AddressClassificationRequest(utterance: candidate, clarification: clarification)
            voiceLatency.selectPath(.classified, generation: generation, turnID: turnID)
            transition(to: .classifying)
            await classifyAndRespond(
                request,
                wasCorrectingPending: isCorrectingPending,
                generation: generation,
                turnID: turnID
            )
        case .ignore:
            voiceLatency.cancel(reason: .noResponse, ifOwnedBy: .turn(generation: generation, turnID: turnID))
            await resumeCapture(generation: generation, turnID: turnID)
        }
    }

    /// Only the classifier call throws; the routed responses report their own failures.
    private func classifyAndRespond(
        _ request: AddressClassificationRequest,
        wasCorrectingPending: Bool,
        generation: UInt64,
        turnID: UInt64
    ) async {
        let target: AddressTarget
        do {
            let trace = voiceLatency.trace
            trace?.mark(.classificationStarted)
            var classificationOutcome = ReplyTraceOutcome.generationFailure
            target = try await ReplyTraceContext.$current.withValue(trace) {
                defer { trace?.mark(.classificationFinished, outcome: classificationOutcome) }
                let value = try await dependencies.classifier.classify(request)
                classificationOutcome = .success
                return value
            }
        } catch {
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await finishVoiceFailure(
                with: Self.serviceError(from: error),
                stopRecognizer: false,
                owner: .turn(generation: generation, turnID: turnID)
            )
            return
        }
        guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
        switch target {
        case .addressed:
            onAddressedActivity()
            clearPendingClarification()
            await generateReply(
                to: request.utterance,
                engagementUpdate: .arm,
                generation: generation,
                turnID: turnID
            )
        case .notAddressed:
            voiceLatency.cancel(reason: .noResponse, ifOwnedBy: .turn(generation: generation, turnID: turnID))
            await resumeCapture(generation: generation, turnID: turnID)
        case .ambiguous:
            voiceLatency.cancel(reason: .ambiguous, ifOwnedBy: .turn(generation: generation, turnID: turnID))
            if wasCorrectingPending {
                await resumeCapture(generation: generation, turnID: turnID)
            } else {
                setPendingClarification(
                    utterance: request.utterance,
                    at: dependencies.now(),
                    generation: generation
                )
                await askForClarification(candidate: request.utterance, generation: generation, turnID: turnID)
            }
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
            }
            await resumeCapture(generation: generation, turnID: turnID)
        } catch {
            let policy = ReplyFailurePolicy(error: Self.serviceError(from: error))
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await finishVoiceFailure(
                with: policy.error,
                includesTypedFallback: policy.includesTypedFallback,
                resetsReplySession: policy.resetsReplySession,
                stopRecognizer: false,
                owner: .turn(generation: generation, turnID: turnID)
            )
        }
    }

    /// The turn's measurement already ended as ambiguous, so the fixed question is not traced.
    /// The original comes from the routed candidate: the expiry task may clear the pending context while speaking.
    private func askForClarification(candidate: String, generation: UInt64, turnID: UInt64) async {
        let question = ClarificationContext.question
        let original = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        transition(to: .clarifying, caption: question)
        do {
            let stream = try await dependencies.speaker.speak(question)
            var finishedNormally = false
            var mouthSequence = SpeechMouthPoseSequence()
            for try await event in stream {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                switch event {
                case .started:
                    viewState.mouthPose = .small
                case .willSpeak:
                    viewState.mouthPose = mouthSequence.nextWordPose()
                case .finished:
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

            await dependencies.memory.recordExternalTurn(prompt: original, response: question)
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await resumeCapture(generation: generation, turnID: turnID)
        } catch {
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

    /// 音声ターン・聞き取り・開始後の再開の失敗。audio session は有効なので origin は .turn。
    private func finishVoiceFailure(
        with error: ConversationServiceError,
        includesTypedFallback: Bool = false,
        resetsReplySession: Bool = false,
        stopRecognizer: Bool,
        owner: ConversationTurnOwner
    ) async {
        await finishFailure(
            .publish(error, includesTypedFallback: includesTypedFallback),
            guidance: error.spokenGuidance,
            origin: .turn(stopRecognizer: stopRecognizer),
            owner: owner,
            resetsReplySession: resetsReplySession
        )
    }

    /// 失敗終了の唯一の入口。音声ターン・聞き取り・文字入力・開始前（可否確認・記憶・認識の準備と開始）のすべてがここを通る。
    /// 同期部（所有者の確定、聞く意図の解除、pending / engagement の解除、segmentation の取消、failureID の確保）を済ませ、
    /// 手順 2〜6 を 1 つの Task にして failureCleanupTask に登録してから待つ。最初の await より前に登録する。
    private func finishFailure(
        _ outcome: FailureOutcome,
        guidance: String?,
        origin: FailureOrigin,
        owner: ConversationTurnOwner,
        resetsReplySession: Bool = false
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
            await self.performFailureOperation(
                outcome,
                guidance: guidance,
                origin: origin,
                owner: owner,
                resetsReplySession: resetsReplySession,
                failureID: failureID
            )
        }
        failureCleanupTask = cleanup
        await cleanup.value
    }

    /// failureCleanupTask の中身。所有確認は全起点で ownsVoiceFailure を使う。
    /// 2: 再生の中断と、試みた認識の停止。3: 案内があり開始前で未有効化なら、音声出力の準備と有効化（失敗や所有喪失は案内を省くだけで、元の結果は保つ）。
    /// 4: 所有が続く間、案内を最後まで読み上げる（失敗・取消・未完了は握りつぶす）。5: 音声出力を止め、試みた audio session を解除し、必要なら返答セッションを捨てる。
    /// 6: 所有が続いていれば結果を反映する（表示、または記憶の状態と一時停止）。既存の lifecycle / capture の後片付けもここ。
    private func performFailureOperation(
        _ outcome: FailureOutcome,
        guidance: String?,
        origin: FailureOrigin,
        owner: ConversationTurnOwner,
        resetsReplySession: Bool,
        failureID: UInt64
    ) async {
        func owned() -> Bool { activeFailureID == failureID && ownsVoiceFailure(owner) }
        var audioActivationAttempted: Bool
        let stopsRecognizer: Bool
        switch origin {
        case .turn(let stopRecognizer):
            audioActivationAttempted = true
            stopsRecognizer = stopRecognizer
        case .preflight(let activationAttempted, let recognizerAttempted):
            audioActivationAttempted = activationAttempted
            stopsRecognizer = recognizerAttempted
        }

        // 2
        await replyPlayback.cancelAndWait()
        if stopsRecognizer {
            await dependencies.recognizer.stop()
        }

        // 3
        var speaksGuidance = guidance != nil && owned()
        if speaksGuidance, !audioActivationAttempted {
            do {
                try await dependencies.speaker.prepare()
                guard owned() else { throw CancellationError() }
                audioActivationAttempted = true
                try await dependencies.audioSession.activate()
                guard owned() else { throw CancellationError() }
            } catch {
                speaksGuidance = false
            }
        }

        // 4
        if let guidance, speaksGuidance, owned() {
            Self.guidanceLogger.info("event=failureGuidance kind=\(Self.failureKind(outcome), privacy: .public)")
            viewState.isSpeakingFailureGuidance = true
            transition(to: .speaking, caption: guidance)
            // 開始前の actor hop も取り消す。後始末の Task 自体は取り消さず、子を待ってから手順 5 に進む。
            let speech = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.speakFailureGuidance(guidance, owner: owner, failureID: failureID)
            }
            failureSpeechTask = speech
            await speech.value
            if activeFailureID == failureID { failureSpeechTask = nil }
            viewState.mouthPose = .closed
            viewState.isSpeakingFailureGuidance = false
        }

        // 5
        await dependencies.speaker.stop()
        if audioActivationAttempted {
            await dependencies.audioSession.deactivate()
        }
        if resetsReplySession {
            await dependencies.reply.reset()
        }

        // 6
        if owned() {
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
            switch outcome {
            case .publish(let error, let includesTypedFallback):
                publish(error, includesTypedFallback: includesTypedFallback)
            case .memoryPaused(let state):
                viewState.memoryState = state
                transition(to: .paused)
            }
        }
        if activeFailureID == failureID {
            activeFailureID = nil
            failureCleanupTask = nil
        }
    }

    private func speakFailureGuidance(_ guidance: String, owner: ConversationTurnOwner, failureID: UInt64) async {
        func owned() -> Bool { activeFailureID == failureID && ownsVoiceFailure(owner) && !Task.isCancelled }
        guard owned() else { return }
        var mouthSequence = SpeechMouthPoseSequence()
        do {
            let stream = try await dependencies.speaker.speak(guidance)
            for try await event in stream {
                guard owned() else { break }
                switch event {
                case .started:
                    viewState.mouthPose = .small
                case .willSpeak:
                    viewState.mouthPose = mouthSequence.nextWordPose()
                case .finished, .cancelled:
                    viewState.mouthPose = .closed
                }
            }
        } catch {}
    }

    /// ログ用の種類名（case 名だけ）。判定には使わない。
    private static func failureKind(_ outcome: FailureOutcome) -> String {
        switch outcome {
        case .publish(let error, _):
            String(String(describing: error).prefix { $0 != "(" })
        case .memoryPaused:
            "memory"
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
            failureSpeechTask?.cancel()
            // The failure cleanup owns the audio teardown, so capture work is cancelled rather than stopped.
            let detached = detachInFlightTasks(cancelsCapture: true)

            let cleanup = Task { @MainActor [replyPlayback, dependencies] in
                // 案内の読み上げを止めてから待つ。後始末（deactivate）は失敗の操作だけが行う。
                await replyPlayback.cancelAndWait()
                await dependencies.speaker.stop()
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
        return owner.isOwned(generation: lifecycleGeneration, turnID: activeTurnID, captureID: activeCaptureID)
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
