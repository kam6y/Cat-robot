import Foundation
import XCTest
@testable import CatRobot

enum ConversationTestCall: Equatable, Sendable {
    case requestMicrophone
    case checkAvailability
    case prepareSpeaker
    case activateAudio
    case prepareRecognizer
    case prepareReply
    case startRecognizer
    case stopRecognizer
    case classify(String)
    case generateReply(String)
    case speak(String)
    case stopSpeaker
    case deactivateAudio
}

enum ConversationLatencyTestEvent: Equatable, Sendable {
    case began(
        token: ConversationLatencyToken,
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    )
    case asrActivity(token: ConversationLatencyToken, at: TimeInterval)
    case selected(token: ConversationLatencyToken, path: ConversationLatencyPath, at: TimeInterval)
    case caption(token: ConversationLatencyToken, at: TimeInterval)
    case speech(token: ConversationLatencyToken, at: TimeInterval)
    case cancelled(
        token: ConversationLatencyToken,
        reason: ConversationLatencyCancellation,
        at: TimeInterval
    )
}

@MainActor
final class FakeConversationLatencyTracker: ConversationLatencyTracking {
    private struct Milestones {
        var pathWasSelected = false
        var captionWasRecorded = false
        var speechWasRecorded = false
    }

    private(set) var events: [ConversationLatencyTestEvent] = []
    private var milestones: [ConversationLatencyToken: Milestones] = [:]

    func beginVoiceTurn(
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    ) -> ConversationLatencyToken {
        let token = ConversationLatencyToken(rawValue: UUID())
        milestones[token] = Milestones()
        events.append(
            .began(
                token: token,
                turnID: turnID,
                boundaryAt: boundaryAt,
                lastASRActivityAt: lastASRActivityAt,
                segmentationInterval: segmentationInterval
            )
        )
        return token
    }

    func noteASRActivity(at timestamp: TimeInterval, for token: ConversationLatencyToken) {
        guard milestones[token] != nil else { return }
        events.append(.asrActivity(token: token, at: timestamp))
    }

    func selectPath(
        _ path: ConversationLatencyPath,
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    ) {
        guard var state = milestones[token], !state.pathWasSelected else { return }
        state.pathWasSelected = true
        milestones[token] = state
        events.append(.selected(token: token, path: path, at: timestamp))
    }

    func firstCaptionVisible(for token: ConversationLatencyToken, at timestamp: TimeInterval) {
        guard var state = milestones[token],
              state.pathWasSelected,
              !state.captionWasRecorded else { return }
        state.captionWasRecorded = true
        milestones[token] = state
        events.append(.caption(token: token, at: timestamp))
    }

    func speechStarted(for token: ConversationLatencyToken, at timestamp: TimeInterval) {
        guard var state = milestones[token],
              state.pathWasSelected,
              !state.speechWasRecorded else { return }
        state.speechWasRecorded = true
        milestones[token] = state
        events.append(.speech(token: token, at: timestamp))
        if state.captionWasRecorded {
            milestones[token] = nil
        }
    }

    func cancel(
        _ token: ConversationLatencyToken,
        reason: ConversationLatencyCancellation,
        at timestamp: TimeInterval
    ) {
        guard milestones.removeValue(forKey: token) != nil else { return }
        events.append(.cancelled(token: token, reason: reason, at: timestamp))
    }
}

final class ConversationTestCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversationTestCall] = []

    var values: [ConversationTestCall] {
        lock.withLock { storage }
    }

    func append(_ call: ConversationTestCall) {
        lock.withLock { storage.append(call) }
    }
}

final class ConversationTestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(_ value: TimeInterval = 0) {
        storage = value
    }

    var value: TimeInterval {
        lock.withLock { storage }
    }

    func set(_ value: TimeInterval) {
        lock.withLock { storage = value }
    }
}

actor ConversationTestSleeper {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private(set) var durations: [Duration] = []
    private(set) var cancellationCount = 0

    func sleep(for duration: Duration) async {
        durations.append(duration)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    private func recordCancellation() {
        cancellationCount += 1
    }

    func release(_ index: Int) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume()
    }

    func releaseAll() {
        let pending = continuations.compactMap { $0 }
        continuations = Array(repeating: nil, count: continuations.count)
        pending.forEach { $0.resume() }
    }
}

actor ConversationTestGate {
    private var isOpen: Bool
    private var entryCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func wait() async {
        entryCount += 1
        resumeEntryWaiters()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        guard entryCount < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeEntryWaiters() {
        let ready = entryWaiters.filter { entryCount >= $0.count }
        entryWaiters.removeAll { entryCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

enum ConversationPreflightRaceOutcome: Equatable {
    case freshPreflight
    case joinedExistingPreflight
}

actor ConversationPreflightRaceProbe {
    private var preflightStartCount = 0
    private var outcome: ConversationPreflightRaceOutcome?
    private var waiter: CheckedContinuation<ConversationPreflightRaceOutcome, Never>?

    func record(_ checkpoint: ConversationLifecycleCheckpoint) {
        switch checkpoint {
        case .preflightWillStart:
            preflightStartCount += 1
            if preflightStartCount == 2 {
                complete(with: .freshPreflight)
            }
        case .joiningExistingPreflight:
            complete(with: .joinedExistingPreflight)
        case .waitingForFailureCleanup, .preflightWillFinish:
            break
        }
    }

    func waitForOutcome() async -> ConversationPreflightRaceOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    private func complete(with outcome: ConversationPreflightRaceOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let waiter = waiter
        self.waiter = nil
        waiter?.resume(returning: outcome)
    }
}

actor FakeMicrophonePermission: MicrophoneAuthorizing {
    private let allowed: Bool
    private let gate: ConversationTestGate?
    private let log: ConversationTestCallLog
    private(set) var requestCount = 0

    init(
        allowed: Bool,
        gate: ConversationTestGate?,
        log: ConversationTestCallLog
    ) {
        self.allowed = allowed
        self.gate = gate
        self.log = log
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        log.append(.requestMicrophone)
        await gate?.wait()
        return allowed
    }
}

actor FakeModelAvailability: ModelAvailabilityChecking {
    private var result: ModelAvailability
    private let log: ConversationTestCallLog
    private(set) var checkCount = 0

    init(result: ModelAvailability = .available, log: ConversationTestCallLog) {
        self.result = result
        self.log = log
    }

    func availability() async -> ModelAvailability {
        checkCount += 1
        log.append(.checkAvailability)
        return result
    }

    func setResult(_ result: ModelAvailability) {
        self.result = result
    }
}

actor FakeSpeechRecognizer: SpeechRecognizing {
    typealias Continuation = AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation

    private let log: ConversationTestCallLog
    private let prepareGate: ConversationTestGate?
    private let stopGate: ConversationTestGate?
    private let tailOnFirstStop: SpeechRecognitionEvent?
    private let prepareError: ConversationServiceError?
    private let startError: ConversationServiceError?
    private var continuations: [Continuation] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    init(
        log: ConversationTestCallLog,
        prepareGate: ConversationTestGate? = nil,
        stopGate: ConversationTestGate? = nil,
        tailOnFirstStop: SpeechRecognitionEvent? = nil,
        prepareError: ConversationServiceError? = nil,
        startError: ConversationServiceError? = nil
    ) {
        self.log = log
        self.prepareGate = prepareGate
        self.stopGate = stopGate
        self.tailOnFirstStop = tailOnFirstStop
        self.prepareError = prepareError
        self.startError = startError
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareRecognizer)
        await prepareGate?.wait()
        if let prepareError { throw prepareError }
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        startCount += 1
        log.append(.startRecognizer)
        if let startError { throw startError }
        let pair = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        isRunning = true
        resumeStartWaiters()
        return pair.stream
    }

    func stop() async {
        stopCount += 1
        log.append(.stopRecognizer)
        let captureIndex = continuations.indices.last
        await stopGate?.wait()
        if stopCount == 1, let tailOnFirstStop, let captureIndex {
            continuations[captureIndex].yield(tailOnFirstStop)
        }
        if let captureIndex {
            continuations[captureIndex].finish()
        }
        isRunning = false
    }

    func emit(_ event: SpeechRecognitionEvent, capture index: Int? = nil) {
        guard let index = index ?? continuations.indices.last,
              continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(capture index: Int? = nil) {
        guard let index = index ?? continuations.indices.last,
              continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func fail(
        _ error: ConversationServiceError,
        capture index: Int? = nil
    ) {
        guard let index = index ?? continuations.indices.last,
              continuations.indices.contains(index) else { return }
        continuations[index].finish(throwing: error)
    }

    func waitUntilStarted(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeAddressClassifier: AddressClassifying {
    private let result: AddressTarget
    private let log: ConversationTestCallLog
    private(set) var calls: [String] = []

    init(result: AddressTarget, log: ConversationTestCallLog) {
        self.result = result
        self.log = log
    }

    func classify(_ utterance: String) async throws -> AddressTarget {
        calls.append(utterance)
        log.append(.classify(utterance))
        return result
    }
}

actor FakeReplyService: ReplyGenerating {
    typealias Continuation = AsyncThrowingStream<ReplyStreamEvent, Error>.Continuation

    private let automaticSnapshots: [String]?
    private let resetGate: ConversationTestGate?
    private let cleanupGate: ConversationTestGate?
    private let prepareError: ConversationServiceError?
    private let log: ConversationTestCallLog
    private var continuations: [Continuation] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [ReplyTurnRequest] = []
    private(set) var prepareCount = 0
    private(set) var cancelActiveReplyCount = 0
    private(set) var resetCount = 0

    var prompts: [String] { requests.map(\.userText) }

    init(
        automaticSnapshots: [String]?,
        resetGate: ConversationTestGate?,
        cleanupGate: ConversationTestGate?,
        prepareError: ConversationServiceError?,
        log: ConversationTestCallLog
    ) {
        self.automaticSnapshots = automaticSnapshots
        self.resetGate = resetGate
        self.cleanupGate = cleanupGate
        self.prepareError = prepareError
        self.log = log
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareReply)
        if let prepareError { throw prepareError }
    }

    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error> {
        requests.append(request)
        log.append(.generateReply(request.userText))
        let pair = AsyncThrowingStream<ReplyStreamEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        resumeRequestWaiters()
        if let automaticSnapshots {
            automaticSnapshots.forEach { pair.continuation.yield(.draft($0)) }
            if let finalText = automaticSnapshots.last(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                pair.continuation.yield(
                    .committed(.init(finalText: finalText, memoryChange: nil))
                )
            }
            pair.continuation.finish()
        }
        return pair.stream
    }

    func cancelActiveReply() async {
        cancelActiveReplyCount += 1
        await cleanupGate?.wait()
        continuations.forEach { $0.finish(throwing: ConversationServiceError.cancelled) }
    }

    func reset() async {
        resetCount += 1
        await resetGate?.wait()
    }

    func yield(_ event: ReplyStreamEvent, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func fail(_ error: ConversationServiceError, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish(throwing: error)
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func waitUntilPromptCount(_ count: Int) async {
        await waitUntilRequestCount(count)
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requests.count >= $0.count }
        requestWaiters.removeAll { requests.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeSpeechSpeaker: SpeechSpeaking {
    typealias Continuation = AsyncThrowingStream<SpeechEvent, Error>.Continuation

    private let automaticallyFinishes: Bool
    private var prepareError: ConversationServiceError?
    private let speakError: ConversationServiceError?
    private let stopGate: ConversationTestGate?
    private let log: ConversationTestCallLog
    private var continuations: [Continuation] = []
    private var textWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var texts: [String] = []
    private(set) var prepareCount = 0
    private(set) var stopCount = 0

    init(
        automaticallyFinishes: Bool,
        prepareError: ConversationServiceError?,
        speakError: ConversationServiceError?,
        stopGate: ConversationTestGate?,
        log: ConversationTestCallLog
    ) {
        self.automaticallyFinishes = automaticallyFinishes
        self.prepareError = prepareError
        self.speakError = speakError
        self.stopGate = stopGate
        self.log = log
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareSpeaker)
        if let prepareError { throw prepareError }
    }

    func setPrepareError(_ error: ConversationServiceError?) {
        prepareError = error
    }

    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        if let speakError { throw speakError }
        texts.append(text)
        log.append(.speak(text))
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        resumeTextWaiters()
        if automaticallyFinishes {
            pair.continuation.yield(.started)
            pair.continuation.yield(.willSpeak(range: 0..<max(1, text.count)))
            pair.continuation.yield(.finished)
            pair.continuation.finish()
        }
        return pair.stream
    }

    func stop() async {
        stopCount += 1
        log.append(.stopSpeaker)
        await stopGate?.wait()
        for continuation in continuations {
            continuation.yield(.cancelled)
            continuation.finish()
        }
    }

    func yield(_ event: SpeechEvent, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func waitUntilTextCount(_ count: Int) async {
        guard texts.count < count else { return }
        await withCheckedContinuation { continuation in
            textWaiters.append((count, continuation))
        }
    }

    private func resumeTextWaiters() {
        let ready = textWaiters.filter { texts.count >= $0.count }
        textWaiters.removeAll { texts.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeConversationAudioSession: AudioSessionControlling {
    nonisolated let events: AsyncStream<AudioSessionEvent>
    private nonisolated let eventContinuation: AsyncStream<AudioSessionEvent>.Continuation
    private let log: ConversationTestCallLog
    private let deactivateGate: ConversationTestGate?
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var isActive = false

    init(
        log: ConversationTestCallLog,
        deactivateGate: ConversationTestGate? = nil
    ) {
        let pair = AsyncStream<AudioSessionEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        self.log = log
        self.deactivateGate = deactivateGate
    }

    func activate() async throws {
        activateCount += 1
        isActive = true
        log.append(.activateAudio)
    }

    func deactivate() async {
        deactivateCount += 1
        log.append(.deactivateAudio)
        await deactivateGate?.wait()
        isActive = false
    }

    nonisolated func emit(_ event: AudioSessionEvent) {
        eventContinuation.yield(event)
    }
}

actor FakeServiceTeardown {
    private let gate: ConversationTestGate?
    private(set) var callCount = 0

    init(gate: ConversationTestGate? = nil) {
        self.gate = gate
    }

    func call() async {
        callCount += 1
        await gate?.wait()
    }
}

actor ConversationCompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

@MainActor
final class ConversationHarness {
    let calls: ConversationTestCallLog
    let now: ConversationTestNow
    let microphone: FakeMicrophonePermission
    let modelAvailability: FakeModelAvailability
    let recognizer: FakeSpeechRecognizer
    let classifier: FakeAddressClassifier
    let reply: FakeReplyService
    let speaker: FakeSpeechSpeaker
    let audio: FakeConversationAudioSession
    let teardownProbe: FakeServiceTeardown
    let latency: FakeConversationLatencyTracker
    let dependencies: ConversationDependencies
    let sut: ConversationViewModel

    init(
        classification: AddressTarget = .addressed,
        microphoneAllowed: Bool = true,
        modelAvailabilityResult: ModelAvailability = .available,
        permissionGate: ConversationTestGate? = nil,
        replySnapshots: [String]? = ["わかったよ"],
        speakerAutomaticallyFinishes: Bool = true,
        speakerPrepareError: ConversationServiceError? = nil,
        speakerError: ConversationServiceError? = nil,
        speakerStopGate: ConversationTestGate? = nil,
        recognizerPrepareGate: ConversationTestGate? = nil,
        recognizerStopGate: ConversationTestGate? = nil,
        recognizerTail: SpeechRecognitionEvent? = nil,
        recognizerPrepareError: ConversationServiceError? = nil,
        recognizerStartError: ConversationServiceError? = nil,
        replyResetGate: ConversationTestGate? = nil,
        replyCleanupGate: ConversationTestGate? = nil,
        replyPrepareError: ConversationServiceError? = nil,
        serviceTeardownGate: ConversationTestGate? = nil,
        audioDeactivateGate: ConversationTestGate? = nil,
        latency: FakeConversationLatencyTracker? = nil,
        clarificationDelay: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        lifecycleCheckpoint: @escaping @Sendable (ConversationLifecycleCheckpoint) async -> Void = { _ in }
    ) {
        let calls = ConversationTestCallLog()
        let now = ConversationTestNow()
        let microphone = FakeMicrophonePermission(
            allowed: microphoneAllowed,
            gate: permissionGate,
            log: calls
        )
        let modelAvailability = FakeModelAvailability(
            result: modelAvailabilityResult,
            log: calls
        )
        let recognizer = FakeSpeechRecognizer(
            log: calls,
            prepareGate: recognizerPrepareGate,
            stopGate: recognizerStopGate,
            tailOnFirstStop: recognizerTail,
            prepareError: recognizerPrepareError,
            startError: recognizerStartError
        )
        let classifier = FakeAddressClassifier(result: classification, log: calls)
        let reply = FakeReplyService(
            automaticSnapshots: replySnapshots,
            resetGate: replyResetGate,
            cleanupGate: replyCleanupGate,
            prepareError: replyPrepareError,
            log: calls
        )
        let speaker = FakeSpeechSpeaker(
            automaticallyFinishes: speakerAutomaticallyFinishes,
            prepareError: speakerPrepareError,
            speakError: speakerError,
            stopGate: speakerStopGate,
            log: calls
        )
        let audio = FakeConversationAudioSession(
            log: calls,
            deactivateGate: audioDeactivateGate
        )
        let teardownProbe = FakeServiceTeardown(gate: serviceTeardownGate)
        let latency = latency ?? FakeConversationLatencyTracker()

        self.calls = calls
        self.now = now
        self.microphone = microphone
        self.modelAvailability = modelAvailability
        self.recognizer = recognizer
        self.classifier = classifier
        self.reply = reply
        self.speaker = speaker
        self.audio = audio
        self.teardownProbe = teardownProbe
        self.latency = latency
        let dependencies = ConversationDependencies(
            microphonePermission: microphone,
            modelAvailability: modelAvailability,
            recognizer: recognizer,
            classifier: classifier,
            reply: reply,
            speaker: speaker,
            audioSession: audio,
            latency: latency,
            now: { now.value },
            clarificationDelay: clarificationDelay,
            lifecycleCheckpoint: lifecycleCheckpoint,
            replyCleanup: { await reply.cancelActiveReply() },
            serviceTeardown: { await teardownProbe.call() }
        )
        self.dependencies = dependencies
        sut = ConversationViewModel(dependencies: dependencies)
    }

    func emit(_ event: SpeechRecognitionEvent, at timestamp: TimeInterval? = nil) async {
        if let timestamp { now.set(timestamp) }
        await recognizer.emit(event)
        await waitUntil {
            self.sut.viewState.provisionalTranscript == event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func emitCompletedUtterance(
        _ text: String,
        at timestamp: TimeInterval? = nil
    ) async {
        let eventTime = timestamp ?? now.value
        now.set(eventTime)
        await emit(.finalized(text), at: eventTime)
        now.set(eventTime + 1.2)
        await sut.flushSegmentation(at: eventTime + 1.2)
    }

    func completeTurn(_ text: String, at timestamp: TimeInterval) async {
        now.set(timestamp)
        if sut.viewState.phase == .idle || sut.viewState.phase == .paused {
            await sut.startConversation()
        }
        await emitCompletedUtterance(text, at: timestamp)
    }

    func completeUnengagedTurn(_ text: String, at timestamp: TimeInterval) async {
        await completeTurn(text, at: timestamp)
    }

    @discardableResult
    func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}
