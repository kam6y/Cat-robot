import Foundation
import Observation

@MainActor
@Observable
final class ConversationViewModel {
    private enum EngagementUpdate {
        case arm
        case refresh
        case none
    }

    private let dependencies: ConversationDependencies
    private(set) var viewState: ConversationViewState = .idle

    @ObservationIgnored private var engagement = EngagementWindow()
    @ObservationIgnored private var pendingClarification: PendingClarification?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var captureCounter: UInt64 = 0
    @ObservationIgnored private var turnCounter: UInt64 = 0
    @ObservationIgnored private var transitionCounter: UInt64 = 0
    @ObservationIgnored private var actionIntentCounter: UInt64 = 0
    @ObservationIgnored private var activeCaptureID: UInt64?
    @ObservationIgnored private var activeTurnID: UInt64?
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
    @ObservationIgnored private var audioEventTask: Task<Void, Never>?

    init(dependencies: ConversationDependencies) {
        self.dependencies = dependencies
    }

    func startConversation() async {
        guard !isShutdown, !isShuttingDown else { return }
        ensureAudioEventConsumer()

        if let lifecycleTransitionTask {
            actionIntentCounter &+= 1
            let resumeIntent = actionIntentCounter
            await lifecycleTransitionTask.value
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
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performVoicePreflight(generation: generation)
        }
        preflightTask = task
        await task.value
        if lifecycleGeneration == generation {
            preflightTask = nil
        }
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
        guard !submitted.isEmpty else { return }
        viewState.typedText = submitted
        viewState.showsTypedInput = false
    }

    func sceneBecameInactive() async {
        await pauseConversation()
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
        guard !isShutdown, !isShuttingDown else { return }
        isShuttingDown = true
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
            captureID: captureID
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
        do {
            let allowed = await dependencies.microphonePermission.requestAccess()
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
            try await dependencies.audioSession.activate()
            guard isCurrent(generation) else { return }
            try await dependencies.recognizer.prepare()
            guard isCurrent(generation) else { return }
            await dependencies.reply.prewarm()
            guard isCurrent(generation) else { return }
            try await startCapture(generation: generation, recognizerIsPrepared: true)
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return }
            wantsListening = false
            publish(Self.serviceError(from: error))
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
                self?.captureFailed(
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
            if event.isFinal, !text.isEmpty {
                closingTailSegments.append(text)
            }
            return
        }
        guard !text.isEmpty else { return }

        let timestamp = dependencies.now()
        segmenter.receive(event, at: timestamp)
        firstCaptureActivityAt = firstCaptureActivityAt ?? timestamp
        latestCaptureActivityAt = timestamp
        viewState.provisionalTranscript = text

        if let utterance = segmenter.utteranceIfReady(at: timestamp) {
            beginClosingCapture(
                utterance: utterance,
                generation: generation,
                captureID: captureID
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
        let delay = min(1.2, hardRemaining)
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
        captureID: UInt64
    ) {
        guard isCurrent(generation),
              activeCaptureID == captureID,
              !captureIsClosing else { return }

        captureIsClosing = true
        segmentationTask?.cancel()
        segmentationTask = nil
        let consumer = captureTask
        closingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dependencies.recognizer.stop()
            await consumer?.value
            await self.finishClosingCapture(
                utterance: utterance,
                generation: generation,
                captureID: captureID
            )
        }
    }

    private func finishClosingCapture(
        utterance: String,
        generation: UInt64,
        captureID: UInt64
    ) async {
        guard isCurrent(generation), activeCaptureID == captureID else { return }
        let completedUtterance = ([utterance] + closingTailSegments).joined()
        activeCaptureID = nil
        captureTask = nil
        closingTask = nil
        captureIsClosing = false
        closingTailSegments.removeAll(keepingCapacity: true)
        firstCaptureActivityAt = nil
        latestCaptureActivityAt = nil
        viewState.provisionalTranscript = ""

        turnCounter &+= 1
        let turnID = turnCounter
        activeTurnID = turnID
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
        case .classify(_), .confirmPending(_), .ignore:
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
            await speakAndResume(
                "なあに？",
                engagementUpdate: .arm,
                generation: generation,
                turnID: turnID
            )
        case .accept(let accepted):
            pendingClarification = nil
            await generateReply(
                to: accepted,
                engagementUpdate: isExplicitWake || !wasEngaged ? .arm : .refresh,
                generation: generation,
                turnID: turnID
            )
        case .classify(let candidate):
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
                    await resumeCapture(generation: generation, turnID: turnID)
                case .ambiguous:
                    pendingClarification = PendingClarification(
                        utterance: candidate,
                        at: dependencies.now()
                    )
                    transition(to: .clarifying, caption: "今の、ぼくに言った？")
                }
            } catch {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
                wantsListening = false
                publish(Self.serviceError(from: error))
            }
        case .confirmPending:
            pendingClarification = nil
            await resumeCapture(generation: generation, turnID: turnID)
        case .ignore:
            pendingClarification = nil
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
                    finalText = snapshot
                }
            }
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            guard let finalText else {
                wantsListening = false
                publish(.modelGenerationFailed, includesTypedFallback: true)
                return
            }
            await speakAndResume(
                finalText,
                engagementUpdate: engagementUpdate,
                generation: generation,
                turnID: turnID
            )
        } catch {
            guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
            wantsListening = false
            publish(Self.serviceError(from: error), includesTypedFallback: true)
        }
    }

    private func speakAndResume(
        _ text: String,
        engagementUpdate: EngagementUpdate,
        generation: UInt64,
        turnID: UInt64
    ) async {
        transition(to: .speaking, caption: text)
        do {
            let stream = try await dependencies.speaker.speak(text)
            var finishedNormally = false
            var mouthIndex = 0
            for try await event in stream {
                guard isCurrent(generation, turnID: turnID), !Task.isCancelled else { return }
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
            wantsListening = false
            publish(Self.serviceError(from: error))
        }
    }

    private func resumeCapture(generation: UInt64, turnID: UInt64) async {
        guard isCurrent(generation, turnID: turnID), wantsListening else { return }
        activeTurnID = nil
        do {
            try await startCapture(generation: generation, recognizerIsPrepared: false)
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return }
            wantsListening = false
            publish(Self.serviceError(from: error))
        }
    }

    private func captureFailed(
        _ error: any Error,
        generation: UInt64,
        captureID: UInt64
    ) {
        guard isCurrent(generation),
              activeCaptureID == captureID,
              !captureIsClosing else { return }
        activeCaptureID = nil
        captureTask = nil
        wantsListening = false
        publish(Self.serviceError(from: error))
    }

    private func pauseConversation(force: Bool = false) async {
        actionIntentCounter &+= 1
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
        transitionCounter &+= 1
        let transitionID = transitionCounter
        wantsListening = false
        engagement.clear()
        pendingClarification = nil
        transition(to: .paused)

        segmentationTask?.cancel()
        segmentationTask = nil
        let oldPreflight = preflightTask
        preflightTask = nil
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
        if transitionCounter == transitionID {
            lifecycleTransitionTask = nil
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation && wantsListening && !isShutdown
    }

    private func isCurrent(_ generation: UInt64, turnID: UInt64) -> Bool {
        isCurrent(generation) && activeTurnID == turnID
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
