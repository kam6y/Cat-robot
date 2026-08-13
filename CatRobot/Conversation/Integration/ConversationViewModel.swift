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
    private static let segmentationSilenceInterval: TimeInterval = 1.2

    private enum VoiceFailureOwner {
        case lifecycle(generation: UInt64)
        case turn(generation: UInt64, turnID: UInt64)
        case capture(generation: UInt64, captureID: UInt64)
    }

    private enum EngagementUpdate {
        case arm
        case refresh
        case none
    }

    private struct ActiveVoiceLatency {
        let generation: UInt64
        let captureID: UInt64
        let turnID: UInt64
        let token: ConversationLatencyToken
    }

    private let dependencies: ConversationDependencies
    private(set) var viewState: ConversationViewState = .idle

    @ObservationIgnored private var engagement = EngagementWindow()
    @ObservationIgnored private var pendingClarification: PendingClarification?
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
    @ObservationIgnored private var activeVoiceLatency: ActiveVoiceLatency?
    @ObservationIgnored private var captureIsClosing = false
    @ObservationIgnored private var closingTailSegments: [String] = []
    @ObservationIgnored private var segmenter = UtteranceSegmenter()
    @ObservationIgnored private var firstCaptureActivityAt: TimeInterval?
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
    @ObservationIgnored private var audioEventTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    init(dependencies: ConversationDependencies) {
        self.dependencies = dependencies
    }

    var isAwaitingMicrophonePermission: Bool {
        activeMicrophonePermissionAwaitID != nil
    }

    func startConversation() async {
        guard !isShutdown, !isShuttingDown else { return }
        ensureAudioEventConsumer()

        if let failureCleanupTask {
            actionIntentCounter &+= 1
            let resumeIntent = actionIntentCounter
            await failureCleanupTask.value
            await Task.yield()
            guard actionIntentCounter == resumeIntent else { return }
        }

        if let lifecycleTransitionTask {
            actionIntentCounter &+= 1
            let resumeIntent = actionIntentCounter
            await lifecycleTransitionTask.value
            // Let an already-enqueued later lifecycle intent publish before
            // this queued resume decides whether it still owns the action.
            await Task.yield()
            guard actionIntentCounter == resumeIntent else { return }
        }
        guard !isShutdown, !isShuttingDown else { return }

        if let preflightTask {
            await preflightTask.value
            return
        }
        switch viewState.phase {
        case .listening, .classifying, .clarifying, .thinking, .speaking:
            return
        case .idle, .preparing, .paused, .failed:
            break
        }

        wantsListening = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        transition(to: .preparing)
        let preflightID = preflightOwnership.begin()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performVoicePreflight(generation: generation)
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
            await pauseConversation()
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
        guard !submitted.isEmpty, !isShutdown, !isShuttingDown else { return }
        viewState.showsTypedInput = false

        if let failureCleanupTask {
            actionIntentCounter &+= 1
            let typedIntent = actionIntentCounter
            await failureCleanupTask.value
            await Task.yield()
            guard actionIntentCounter == typedIntent,
                  !isShutdown,
                  !isShuttingDown else { return }
        }

        if let lifecycleTransitionTask {
            actionIntentCounter &+= 1
            let typedIntent = actionIntentCounter
            await lifecycleTransitionTask.value
            await Task.yield()
            guard actionIntentCounter == typedIntent,
                  !isShutdown,
                  !isShuttingDown else { return }
        }

        switch viewState.phase {
        case .preparing, .classifying, .thinking, .speaking:
            return
        case .idle, .listening, .clarifying, .paused, .failed:
            break
        }

        cancelActiveVoiceLatency(reason: .typedReplacement)
        ensureAudioEventConsumer()
        let shouldResumeVoice = wantsListening
            && microphoneWasAllowed
            && activeCaptureID != nil
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        wantsListening = false
        pendingClarification = nil
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
        actionIntentCounter &+= 1
        lifecycleGeneration &+= 1
        wantsListening = false
        cancelActiveVoiceLatency(reason: .lifecycle)
        activeMicrophonePermissionAwaitID = nil
        releaseMicrophonePermissionCompletion()
    }

    func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
        switch event {
        case .interruptionBegan, .routeChanged:
            await pauseConversation()
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
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        cancelActiveVoiceLatency(reason: .shutdown)
        await pauseConversation(force: true)

        let eventTask = audioEventTask
        audioEventTask = nil
        eventTask?.cancel()
        await eventTask?.value
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
            firstCaptureActivityAt = nil
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
        transition(to: .thinking)
        do {
            let stream = try await dependencies.reply.streamReply(to: submitted)
            var finalText: String?
            for try await snapshot in stream {
                guard isTypedTurnCurrent(generation, turnID: turnID),
                      !Task.isCancelled else { return }
                viewState.caption = snapshot
                if !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = snapshot
                }
            }
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            guard let finalText else {
                await finishTypedTurn(
                    with: .modelGenerationFailed,
                    includesTypedFallback: true,
                    generation: generation,
                    turnID: turnID
                )
                return
            }
            await speakTypedReply(
                finalText,
                shouldResumeVoice: shouldResumeVoice,
                generation: generation,
                turnID: turnID
            )
        } catch {
            let serviceError = Self.serviceError(from: error)
            await finishTypedTurn(
                with: serviceError,
                includesTypedFallback: true,
                resetsReplySession: serviceError == .contextExceeded,
                generation: generation,
                turnID: turnID
            )
        }
    }

    private func speakTypedReply(
        _ text: String,
        shouldResumeVoice: Bool,
        generation: UInt64,
        turnID: UInt64
    ) async {
        transition(to: .speaking, caption: text)
        do {
            let stream = try await dependencies.speaker.speak(text)
            var finishedNormally = false
            var mouthIndex = 0
            for try await event in stream {
                guard isTypedTurnCurrent(generation, turnID: turnID),
                      !Task.isCancelled else { return }
                switch event {
                case .started:
                    viewState.mouthPose = .small
                case .willSpeak:
                    let poses: [MouthPose] = [.small, .medium, .wide]
                    viewState.mouthPose = poses[mouthIndex % poses.count]
                    mouthIndex += 1
                case .finished:
                    finishedNormally = true
                    viewState.mouthPose = .closed
                case .cancelled:
                    throw ConversationServiceError.speechSynthesisFailed
                }
            }
            guard isTypedTurnCurrent(generation, turnID: turnID),
                  !Task.isCancelled else { return }
            guard finishedNormally else {
                throw ConversationServiceError.speechSynthesisFailed
            }

            if shouldResumeVoice {
                engagement.arm(at: dependencies.now())
                wantsListening = true
                do {
                    try await startCapture(generation: generation, recognizerIsPrepared: false)
                } catch {
                    guard isTypedTurnCurrent(generation, turnID: turnID),
                          !Task.isCancelled else { return }
                    wantsListening = false
                    await dependencies.recognizer.stop()
                    await finishTypedTurn(
                        with: Self.serviceError(from: error),
                        generation: generation,
                        turnID: turnID
                    )
                }
            } else {
                await dependencies.audioSession.deactivate()
                guard isTypedTurnCurrent(generation, turnID: turnID),
                      !Task.isCancelled else { return }
                transition(to: .paused)
            }
        } catch {
            await finishTypedTurn(
                with: Self.serviceError(from: error),
                generation: generation,
                turnID: turnID
            )
        }
    }

    private func finishTypedTurn(
        with error: ConversationServiceError,
        includesTypedFallback: Bool = false,
        resetsReplySession: Bool = false,
        generation: UInt64,
        turnID: UInt64
    ) async {
        await dependencies.speaker.stop()
        await dependencies.audioSession.deactivate()
        if resetsReplySession {
            await dependencies.reply.reset()
        }
        guard isTypedTurnCurrent(generation, turnID: turnID),
              !Task.isCancelled else { return }
        publish(error, includesTypedFallback: includesTypedFallback)
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
        firstCaptureActivityAt = nil
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
                if let latency = activeVoiceLatency,
                   latency.generation == generation,
                   latency.captureID == captureID {
                    dependencies.latency.noteASRActivity(
                        at: dependencies.now(),
                        for: latency.token
                    )
                }
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
        firstCaptureActivityAt = firstCaptureActivityAt ?? timestamp
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
        }
    }

    private func synchronizeCaptureTimingWithSegmenter() {
        guard !segmenter.hasActivity else { return }
        segmentationTask?.cancel()
        segmentationTask = nil
        firstCaptureActivityAt = nil
        latestCaptureActivityAt = nil
    }

    private func presentUnrecognizedSpeechWhileListening() {
        segmentationTask?.cancel()
        segmentationTask = nil
        segmenter = UtteranceSegmenter()
        firstCaptureActivityAt = nil
        latestCaptureActivityAt = nil
        viewState.provisionalTranscript = ""
        let presentation = ConversationErrorPresentation(.speechUnrecognized)
        viewState.errorMessage = presentation.message
        viewState.recoveries = presentation.recoveries
    }

    private func scheduleSegmentationFlush(
        generation: UInt64,
        captureID: UInt64,
        at timestamp: TimeInterval
    ) {
        segmentationTask?.cancel()
        let hardRemaining = max(
            0,
            20 - (timestamp - (firstCaptureActivityAt ?? timestamp))
        )
        let delay = min(Self.segmentationSilenceInterval, hardRemaining)
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

        captureIsClosing = true
        segmentationTask?.cancel()
        segmentationTask = nil
        turnCounter &+= 1
        let turnID = turnCounter
        activeTurnID = turnID
        let latencyToken = dependencies.latency.beginVoiceTurn(
            turnID: turnID,
            boundaryAt: boundaryAt,
            lastASRActivityAt: latestCaptureActivityAt,
            segmentationInterval: Self.segmentationSilenceInterval
        )
        activeVoiceLatency = ActiveVoiceLatency(
            generation: generation,
            captureID: captureID,
            turnID: turnID,
            token: latencyToken
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
        let completedUtterance = ([utterance] + closingTailSegments).joined()
        activeCaptureID = nil
        captureTask = nil
        closingTask = nil
        captureIsClosing = false
        closingTailSegments.removeAll(keepingCapacity: true)
        firstCaptureActivityAt = nil
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
            self.pendingClarification = nil
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
        case .classify(_), .confirmPending(_), .dismissPending, .ignore:
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
            pendingClarification = nil
            selectVoiceLatency(.fast, generation: generation, turnID: turnID)
            await speakAndResume(
                "なあに？",
                engagementUpdate: .arm,
                generation: generation,
                turnID: turnID
            )
        case .accept(let accepted):
            pendingClarification = nil
            selectVoiceLatency(.fast, generation: generation, turnID: turnID)
            await generateReply(
                to: accepted,
                engagementUpdate: isExplicitWake || !wasEngaged ? .arm : .refresh,
                generation: generation,
                turnID: turnID
            )
        case .classify(let candidate):
            pendingClarification = nil
            selectVoiceLatency(.classified, generation: generation, turnID: turnID)
            transition(to: .classifying)
            do {
                let target = try await dependencies.classifier.classify(candidate)
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                switch target {
                case .addressed:
                    pendingClarification = nil
                    await generateReply(
                        to: candidate,
                        engagementUpdate: .arm,
                        generation: generation,
                        turnID: turnID
                    )
                case .notAddressed:
                    cancelVoiceLatency(
                        reason: .noResponse,
                        generation: generation,
                        turnID: turnID
                    )
                    await resumeCapture(generation: generation, turnID: turnID)
                case .ambiguous:
                    cancelVoiceLatency(
                        reason: .ambiguous,
                        generation: generation,
                        turnID: turnID
                    )
                    if isCorrectingPending {
                        await resumeCapture(generation: generation, turnID: turnID)
                    } else {
                        pendingClarification = PendingClarification(
                            utterance: candidate,
                            at: dependencies.now()
                        )
                        await speakAndResume(
                            "今の、ぼくに言った？",
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
        case .confirmPending:
            pendingClarification = nil
            cancelVoiceLatency(
                reason: .noResponse,
                generation: generation,
                turnID: turnID
            )
            await resumeCapture(generation: generation, turnID: turnID)
        case .dismissPending:
            pendingClarification = nil
            cancelVoiceLatency(
                reason: .noResponse,
                generation: generation,
                turnID: turnID
            )
            await resumeCapture(generation: generation, turnID: turnID)
        case .ignore:
            cancelVoiceLatency(
                reason: .noResponse,
                generation: generation,
                turnID: turnID
            )
            await resumeCapture(generation: generation, turnID: turnID)
        }
    }

    private func generateReply(
        to utterance: String,
        engagementUpdate: EngagementUpdate,
        generation: UInt64,
        turnID: UInt64
    ) async {
        transition(to: .thinking)
        do {
            let stream = try await dependencies.reply.streamReply(to: utterance)
            var finalText: String?
            for try await snapshot in stream {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                viewState.caption = snapshot
                if !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    recordFirstVoiceCaption(
                        generation: generation,
                        turnID: turnID
                    )
                    finalText = snapshot
                }
            }
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            guard let finalText else {
                await finishVoiceFailure(
                    with: .modelGenerationFailed,
                    includesTypedFallback: true,
                    stopRecognizer: false,
                    owner: .turn(generation: generation, turnID: turnID)
                )
                return
            }
            await speakAndResume(
                finalText,
                engagementUpdate: engagementUpdate,
                generation: generation,
                turnID: turnID
            )
        } catch {
            let serviceError = Self.serviceError(from: error)
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            await finishVoiceFailure(
                with: serviceError,
                includesTypedFallback: true,
                resetsReplySession: serviceError == .contextExceeded,
                stopRecognizer: false,
                owner: .turn(generation: generation, turnID: turnID)
            )
        }
    }

    private func speakAndResume(
        _ text: String,
        engagementUpdate: EngagementUpdate,
        generation: UInt64,
        turnID: UInt64
    ) async {
        transition(to: .speaking, caption: text)
        recordFirstVoiceCaption(generation: generation, turnID: turnID)
        do {
            let stream = try await dependencies.speaker.speak(text)
            var finishedNormally = false
            var mouthIndex = 0
            for try await event in stream {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                switch event {
                case .started:
                    recordVoiceSpeechStarted(
                        generation: generation,
                        turnID: turnID
                    )
                    viewState.mouthPose = .small
                case .willSpeak:
                    recordVoiceSpeechStarted(
                        generation: generation,
                        turnID: turnID
                    )
                    let poses: [MouthPose] = [.small, .medium, .wide]
                    viewState.mouthPose = poses[mouthIndex % poses.count]
                    mouthIndex += 1
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
        cancelVoiceLatency(
            reason: .failure,
            generation: generation,
            turnID: turnID
        )
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
        stopRecognizer: Bool,
        owner: VoiceFailureOwner
    ) async {
        guard ownsVoiceFailure(owner), !Task.isCancelled else { return }
        cancelVoiceLatency(reason: .failure, owner: owner)
        wantsListening = false
        pendingClarification = nil
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
        stopRecognizer: Bool,
        owner: VoiceFailureOwner,
        failureID: UInt64
    ) async {
        await dependencies.speaker.stop()
        if stopRecognizer {
            await dependencies.recognizer.stop()
        }
        await dependencies.audioSession.deactivate()
        if resetsReplySession {
            await dependencies.reply.reset()
        }

        if activeFailureID == failureID, ownsVoiceFailure(owner) {
            if case .capture(_, let captureID) = owner,
               activeCaptureID == captureID {
                activeCaptureID = nil
                captureTask = nil
                captureIsClosing = false
                closingTailSegments.removeAll(keepingCapacity: true)
                segmenter = UtteranceSegmenter()
                firstCaptureActivityAt = nil
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

    private func pauseConversation(force: Bool = false) async {
        actionIntentCounter &+= 1
        cancelActiveVoiceLatency(reason: .lifecycle)
        activeMicrophonePermissionAwaitID = nil
        releaseMicrophonePermissionCompletion()
        if let failureCleanupTask {
            lifecycleGeneration &+= 1
            let transitionID = transitionOwnership.begin()
            wantsListening = false
            engagement.clear()
            pendingClarification = nil
            transition(to: .paused)

            segmentationTask?.cancel()
            segmentationTask = nil
            let oldPreflight = preflightTask
            preflightTask = nil
            preflightOwnership.invalidate()
            oldPreflight?.cancel()
            let oldTurn = turnTask
            turnTask = nil
            oldTurn?.cancel()
            let oldCapture = captureTask
            captureTask = nil
            oldCapture?.cancel()
            let oldClosing = closingTask
            closingTask = nil
            oldClosing?.cancel()
            activeCaptureID = nil
            activeTurnID = nil
            captureIsClosing = false
            closingTailSegments.removeAll(keepingCapacity: true)

            let cleanup = Task { @MainActor in
                await failureCleanupTask.value
                await oldPreflight?.value
                await oldCapture?.value
                await oldClosing?.value
                await oldTurn?.value
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
            wantsListening = false
            engagement.clear()
            pendingClarification = nil
            transition(to: .paused)
            await lifecycleTransitionTask.value
            return
        }
        if !force, viewState.phase == .paused {
            return
        }

        lifecycleGeneration &+= 1
        let transitionID = transitionOwnership.begin()
        wantsListening = false
        engagement.clear()
        pendingClarification = nil
        transition(to: .paused)

        segmentationTask?.cancel()
        segmentationTask = nil
        let oldPreflight = preflightTask
        preflightTask = nil
        preflightOwnership.invalidate()
        oldPreflight?.cancel()
        let oldTurn = turnTask
        turnTask = nil
        oldTurn?.cancel()
        let oldCapture = captureTask
        captureTask = nil
        let oldClosing = closingTask
        closingTask = nil
        activeCaptureID = nil
        activeTurnID = nil
        captureIsClosing = false
        closingTailSegments.removeAll(keepingCapacity: true)

        let cleanup = Task { @MainActor [dependencies] in
            await oldPreflight?.value
            await dependencies.speaker.stop()
            await dependencies.recognizer.stop()
            await oldCapture?.value
            await oldClosing?.value
            await oldTurn?.value
            await dependencies.audioSession.deactivate()
        }
        lifecycleTransitionTask = cleanup
        await cleanup.value
        if transitionOwnership.finish(transitionID) {
            lifecycleTransitionTask = nil
        }
    }

    private func selectVoiceLatency(
        _ path: ConversationLatencyPath,
        generation: UInt64,
        turnID: UInt64
    ) {
        guard let latency = activeVoiceLatency,
              latency.generation == generation,
              latency.turnID == turnID else { return }
        dependencies.latency.selectPath(
            path,
            for: latency.token,
            at: dependencies.now()
        )
    }

    private func recordFirstVoiceCaption(
        generation: UInt64,
        turnID: UInt64
    ) {
        guard let latency = activeVoiceLatency,
              latency.generation == generation,
              latency.turnID == turnID else { return }
        dependencies.latency.firstCaptionVisible(
            for: latency.token,
            at: dependencies.now()
        )
    }

    private func recordVoiceSpeechStarted(
        generation: UInt64,
        turnID: UInt64
    ) {
        guard let latency = activeVoiceLatency,
              latency.generation == generation,
              latency.turnID == turnID else { return }
        dependencies.latency.speechStarted(
            for: latency.token,
            at: dependencies.now()
        )
    }

    private func cancelActiveVoiceLatency(
        reason: ConversationLatencyCancellation
    ) {
        guard let latency = activeVoiceLatency else { return }
        activeVoiceLatency = nil
        dependencies.latency.cancel(
            latency.token,
            reason: reason,
            at: dependencies.now()
        )
    }

    private func cancelVoiceLatency(
        reason: ConversationLatencyCancellation,
        generation: UInt64,
        turnID: UInt64
    ) {
        guard let latency = activeVoiceLatency,
              latency.generation == generation,
              latency.turnID == turnID else { return }
        cancelActiveVoiceLatency(reason: reason)
    }

    private func cancelVoiceLatency(
        reason: ConversationLatencyCancellation,
        owner: VoiceFailureOwner
    ) {
        guard let latency = activeVoiceLatency else { return }
        let isOwner: Bool
        switch owner {
        case .lifecycle(let generation):
            isOwner = latency.generation == generation
        case .turn(let generation, let turnID):
            isOwner = latency.generation == generation
                && latency.turnID == turnID
        case .capture(let generation, let captureID):
            isOwner = latency.generation == generation
                && latency.captureID == captureID
        }
        guard isOwner else { return }
        cancelActiveVoiceLatency(reason: reason)
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

    private func ownsVoiceFailure(_ owner: VoiceFailureOwner) -> Bool {
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
        viewState.phase = phase
        viewState.errorMessage = nil
        viewState.recoveries = []
        if let caption { viewState.caption = caption }

        switch phase {
        case .idle:
            viewState.catState = .idle
            viewState.mouthPose = .closed
            viewState.microphoneStatus = "マイクは待機中"
            viewState.activityStatus = "会話を始める準備ができました"
        case .preparing:
            viewState.catState = .thinking
            viewState.mouthPose = .closed
            viewState.microphoneStatus = "会話の準備中"
            viewState.activityStatus = "準備しています"
        case .listening:
            viewState.catState = .listening
            viewState.mouthPose = .closed
            viewState.microphoneStatus = "端末上で聞き取り中"
            viewState.activityStatus = "話しかけてください"
        case .classifying:
            viewState.catState = .thinking
            viewState.mouthPose = .closed
            viewState.microphoneStatus = "聞き取りを休止"
            viewState.activityStatus = "呼びかけを確認しています"
        case .clarifying:
            viewState.catState = .clarifying
            viewState.mouthPose = .small
            viewState.microphoneStatus = "聞き返しの間は聞き取りを休止"
            viewState.activityStatus = "聞き返しています"
        case .thinking:
            viewState.catState = .thinking
            viewState.mouthPose = .closed
            viewState.microphoneStatus = "聞き取りを休止"
            viewState.activityStatus = "考えています"
        case .speaking:
            viewState.catState = .speaking
            viewState.mouthPose = .medium
            viewState.microphoneStatus = "返事の間は聞き取りを休止"
            viewState.activityStatus = "話しています"
        case .paused:
            viewState.catState = .idle
            viewState.mouthPose = .closed
            viewState.microphoneStatus = "マイクは一時停止中"
            viewState.activityStatus = "再開するまで待っています"
            viewState.provisionalTranscript = ""
        case .failed:
            break
        }
    }

    private func publish(
        _ error: ConversationServiceError,
        includesTypedFallback: Bool = false
    ) {
        let presentation = ConversationErrorPresentation(error)
        var recoveries = presentation.recoveries
        if includesTypedFallback,
           !recoveries.contains(where: { $0.action == .showTypedInput }) {
            recoveries.append(.init(title: "文字で話す", action: .showTypedInput))
        }
        let typedText = viewState.typedText
        let showsTypedInput = viewState.showsTypedInput
        let caption = viewState.caption
        viewState = .failed(
            error: error,
            message: presentation.message,
            recoveries: recoveries
        )
        viewState.typedText = typedText
        viewState.showsTypedInput = showsTypedInput
        viewState.caption = caption
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
