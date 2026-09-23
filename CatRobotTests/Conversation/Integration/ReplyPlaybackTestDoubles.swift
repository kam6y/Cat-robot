import Foundation
import Observation
import XCTest
@testable import CatRobot

actor ControlledReply: ReplyGenerating {
    nonisolated let supportsStableReplyPrefix: Bool
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var requests = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    let cancellation = ConversationTestGate()
    private(set) var resetCount = 0
    init(stablePrefix: Bool = true) { supportsStableReplyPrefix = stablePrefix }
    func prewarm() async {}
    func reset() async { resetCount += 1 }
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        pair.continuation.onTermination = { [cancellation] reason in
            if case .cancelled = reason { Task { await cancellation.open() } }
        }
        continuation = pair.continuation
        requests += 1
        let ready = waiters.filter { $0.0 <= requests }
        waiters.removeAll { $0.0 <= requests }
        ready.forEach { $0.1.resume() }
        return pair.stream
    }
    func waitUntilRequested(_ count: Int = 1) async {
        if requests >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func yield(_ text: String) { continuation?.yield(text) }
    func finish(throwing error: Error? = nil) { continuation?.finish(throwing: error) }
}

actor ControlledSpeaker: SpeechSpeaking {
    private(set) var texts: [String] = []
    private(set) var stopCount = 0
    private var continuations: [AsyncThrowingStream<SpeechEvent, Error>.Continuation] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    let startError: ConversationServiceError?
    let stopGate: ConversationTestGate?
    init(startError: ConversationServiceError? = nil, stopGate: ConversationTestGate? = nil) {
        self.startError = startError; self.stopGate = stopGate
    }
    func prepare() async throws {}
    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        if let startError { throw startError }
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        texts.append(text)
        let ready = waiters.filter { $0.0 <= texts.count }
        waiters.removeAll { $0.0 <= texts.count }
        ready.forEach { $0.1.resume() }
        return pair.stream
    }
    func waitUntilCallCount(_ count: Int) async {
        if texts.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func emit(_ event: SpeechEvent, run: Int? = nil) { continuation(run)?.yield(event) }
    func finish(throwing error: Error? = nil, run: Int? = nil) { continuation(run)?.finish(throwing: error) }
    func complete(run: Int? = nil) { emit(.started, run: run); emit(.finished, run: run); finish(run: run) }
    func stop() async {
        stopCount += 1
        // Capture the affected streams before suspension, like production's run ID.
        let old = continuations
        await stopGate?.wait()
        old.forEach { $0.yield(.cancelled); $0.finish() }
    }
    private func continuation(_ run: Int?) -> AsyncThrowingStream<SpeechEvent, Error>.Continuation? {
        guard !continuations.isEmpty else { return nil }
        let index = run ?? continuations.count - 1
        return continuations.indices.contains(index) ? continuations[index] : nil
    }
}

@MainActor
final class PlaybackUpdates {
    private(set) var captions: [String] = []
    private(set) var starts: [ReplySpeechPart] = []
    private(set) var finishes: [ReplySpeechPart] = []
    private var waiters: [(predicate: @MainActor () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    func record(_ update: ReplyPlaybackUpdate) {
        switch update {
        case .caption(let text): captions.append(text)
        case .speechStarted(let part, _): starts.append(part)
        case .speechFinished(let part): finishes.append(part)
        case .willSpeak: break
        }
        let ready = waiters.filter { $0.predicate() }
        waiters.removeAll { $0.predicate() }
        ready.forEach { $0.continuation.resume() }
    }
    func waitForCaption(_ text: String) async { await wait { self.captions.last == text } }
    func waitForFinishes(_ count: Int) async { await wait { self.finishes.count >= count } }
    private func wait(_ predicate: @escaping @MainActor () -> Bool) async {
        if predicate() { return }
        await withCheckedContinuation { waiters.append((predicate, $0)) }
    }
}
