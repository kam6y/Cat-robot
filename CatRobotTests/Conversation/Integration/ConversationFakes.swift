import Foundation
import XCTest
@testable import CatRobot

enum ConversationTestCall: Equatable, Sendable {
    case requestMicrophone
    case checkAvailability
    case prepareSpeaker
    case activateAudio
    case prepareRecognizer
    case prewarmReply
    case startRecognizer
    case stopRecognizer
    case classify(String)
    case generateReply(String)
    case speak(String)
    case stopSpeaker
    case deactivateAudio
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
    private let result: ModelAvailability
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
}

actor FakeSpeechRecognizer: SpeechRecognizing {
    typealias Continuation = AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation

    private let log: ConversationTestCallLog
    private let prepareGate: ConversationTestGate?
    private let stopGate: ConversationTestGate?
    private let tailOnFirstStop: SpeechRecognitionEvent?
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
        tailOnFirstStop: SpeechRecognitionEvent? = nil
    ) {
        self.log = log
        self.prepareGate = prepareGate
        self.stopGate = stopGate
        self.tailOnFirstStop = tailOnFirstStop
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareRecognizer)
        await prepareGate?.wait()
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        startCount += 1
        log.append(.startRecognizer)
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
    typealias Continuation = AsyncThrowingStream<String, Error>.Continuation

    private let automaticSnapshots: [String]?
    private let log: ConversationTestCallLog
    private var continuations: [Continuation] = []
    private var promptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var prompts: [String] = []
    private(set) var prewarmCount = 0
    private(set) var resetCount = 0

    init(automaticSnapshots: [String]?, log: ConversationTestCallLog) {
        self.automaticSnapshots = automaticSnapshots
        self.log = log
    }

    func prewarm() async {
        prewarmCount += 1
        log.append(.prewarmReply)
    }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(utterance)
        log.append(.generateReply(utterance))
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        continuations.append(pair.continuation)
        resumePromptWaiters()
        if let automaticSnapshots {
            automaticSnapshots.forEach { pair.continuation.yield($0) }
            pair.continuation.finish()
        }
        return pair.stream
    }

    func reset() async {
        resetCount += 1
    }

    func yield(_ snapshot: String, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(snapshot)
    }

    func finish(run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func fail(_ error: ConversationServiceError, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish(throwing: error)
    }

    func waitUntilPromptCount(_ count: Int) async {
        guard prompts.count < count else { return }
        await withCheckedContinuation { continuation in
            promptWaiters.append((count, continuation))
        }
    }

    private func resumePromptWaiters() {
        let ready = promptWaiters.filter { prompts.count >= $0.count }
        promptWaiters.removeAll { prompts.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeSpeechSpeaker: SpeechSpeaking {
    typealias Continuation = AsyncThrowingStream<SpeechEvent, Error>.Continuation

    private let automaticallyFinishes: Bool
    private let speakError: ConversationServiceError?
    private let log: ConversationTestCallLog
    private var continuations: [Continuation] = []
    private var textWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var texts: [String] = []
    private(set) var prepareCount = 0
    private(set) var stopCount = 0

    init(
        automaticallyFinishes: Bool,
        speakError: ConversationServiceError?,
        log: ConversationTestCallLog
    ) {
        self.automaticallyFinishes = automaticallyFinishes
        self.speakError = speakError
        self.log = log
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareSpeaker)
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
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var isActive = false

    init(log: ConversationTestCallLog) {
        let pair = AsyncStream<AudioSessionEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        self.log = log
    }

    func activate() async throws {
        activateCount += 1
        isActive = true
        log.append(.activateAudio)
    }

    func deactivate() async {
        deactivateCount += 1
        isActive = false
        log.append(.deactivateAudio)
    }

    nonisolated func emit(_ event: AudioSessionEvent) {
        eventContinuation.yield(event)
    }
}

actor FakeServiceTeardown {
    private(set) var callCount = 0

    func call() {
        callCount += 1
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
    let sut: ConversationViewModel

    init(
        classification: AddressTarget = .addressed,
        microphoneAllowed: Bool = true,
        permissionGate: ConversationTestGate? = nil,
        replySnapshots: [String]? = ["わかったよ"],
        speakerAutomaticallyFinishes: Bool = true,
        speakerError: ConversationServiceError? = nil,
        recognizerPrepareGate: ConversationTestGate? = nil,
        recognizerStopGate: ConversationTestGate? = nil,
        recognizerTail: SpeechRecognitionEvent? = nil
    ) {
        let calls = ConversationTestCallLog()
        let now = ConversationTestNow()
        let microphone = FakeMicrophonePermission(
            allowed: microphoneAllowed,
            gate: permissionGate,
            log: calls
        )
        let modelAvailability = FakeModelAvailability(log: calls)
        let recognizer = FakeSpeechRecognizer(
            log: calls,
            prepareGate: recognizerPrepareGate,
            stopGate: recognizerStopGate,
            tailOnFirstStop: recognizerTail
        )
        let classifier = FakeAddressClassifier(result: classification, log: calls)
        let reply = FakeReplyService(automaticSnapshots: replySnapshots, log: calls)
        let speaker = FakeSpeechSpeaker(
            automaticallyFinishes: speakerAutomaticallyFinishes,
            speakError: speakerError,
            log: calls
        )
        let audio = FakeConversationAudioSession(log: calls)
        let teardownProbe = FakeServiceTeardown()

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
        sut = ConversationViewModel(
            dependencies: ConversationDependencies(
                microphonePermission: microphone,
                modelAvailability: modelAvailability,
                recognizer: recognizer,
                classifier: classifier,
                reply: reply,
                speaker: speaker,
                audioSession: audio,
                now: { now.value },
                serviceTeardown: { await teardownProbe.call() }
            )
        )
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
