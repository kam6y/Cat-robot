import Foundation
import XCTest
@testable import CatRobot

/// Synchronous native callbacks with explicit async observation, without polling.
final class PlaybackTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if signalled { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func signal() {
        let pending = lock.withLock {
            signalled = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

final class PlaybackNativeSession: GemmaSession, @unchecked Sendable {
    let started = PlaybackTestSignal()
    let cancelled = PlaybackTestSignal()
    let closed = PlaybackTestSignal()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func tokenCount() throws -> Int { 100 }
    func inputTokenCount(_ prompt: String) throws -> Int { prompt.count }
    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        lock.withLock { continuation = pair.continuation }
        started.signal()
        return pair.stream
    }
    func yield(_ delta: String) { lock.withLock { continuation }?.yield(delta) }
    func finish() { lock.withLock { continuation }?.finish() }
    func cancel() { cancelled.signal() } // Explicit finish models native drain.
    func close() { closed.signal() }
}

actor PlaybackNativeRuntime: GemmaRuntime {
    let session: PlaybackNativeSession
    init(_ session: PlaybackNativeSession) { self.session = session }
    func prepare() async throws {}
    func countTokens(_ text: String) async throws -> Int { text.count }
    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        session
    }
}

@MainActor
final class ReplyPlaybackMemoryTests: XCTestCase {
    func testCancellationBeforeRunStartsStillHasTerminalTrace() async {
        let gate = ConversationTestGate()
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let sut = ReplyPlaybackCoordinator(reply: ControlledReply(), speaker: ControlledSpeaker(), mode: .firstSentence)
        let run = Task {
            await gate.wait()
            return try await sut.run(prompt: "質問", trace: trace, onUpdate: { _ in })
        }
        await gate.waitUntilEntered()
        run.cancel()
        await gate.open()
        do { _ = try await run.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .cancelled) }
        XCTAssertEqual(sink.events.map(\.point), [.finished])
        XCTAssertEqual(sink.events.last?.outcome, .cancelled)
    }

    func testClassificationDoesNotClaimTheReplyStreamFinishedMilestone() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let service = GemmaConversationService(runtime: StubGemmaRuntime())
        try await ReplyTraceContext.$current.withValue(trace) {
            _ = try await service.classify("質問")
            trace.mark(.request)
            for try await _ in try await service.streamReply(to: "質問") {}
        }
        let points = sink.events.map(\.point)
        XCTAssertEqual(points.filter { $0 == .streamFinished }.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(points.firstIndex(of: .streamFinished)),
                             try XCTUnwrap(points.firstIndex(of: .generationFinished)))
        XCTAssertEqual(points.filter { $0 == .sessionStarted }.count, 2)
    }

    private func seed() -> ConversationMemorySnapshot {
        .init(schemaVersion: 1, memoryCompatibilityID: GemmaMemoryCompatibility.current,
              revision: 1, savedAt: Date(timeIntervalSince1970: 0), summary: "合成の記憶",
              turns: [.init(prompt: "前の質問", response: "前の回答")])
    }
    private func waitForMemory(_ service: GemmaConversationService, _ expected: ConversationMemoryState) async {
        for await state in await service.memoryUpdates() { if state == expected { return } }
    }
    func testSpeechFailureBeforeCommitLeavesOldMemory() async {
        let original = seed()
        let store = MemoryStoreFake(snapshot: original)
        let native = PlaybackNativeSession()
        let service = GemmaConversationService(runtime: PlaybackNativeRuntime(native), memoryStore: store)
        let speaker = ControlledSpeaker()
        let sut = ReplyPlaybackCoordinator(reply: service, speaker: speaker, mode: .firstSentence)
        let run = Task { try await sut.run(prompt: "新しい質問", trace: nil, onUpdate: { _ in }) }
        await native.started.wait()
        native.yield("最初。続き")
        await speaker.waitUntilCallCount(1)
        await speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
        await native.cancelled.wait()
        native.finish()
        do { _ = try await run.value; XCTFail("Expected speech failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed) }
        await native.closed.wait()
        let saved = await store.snapshot
        XCTAssertEqual(saved, original)
        let saves = await store.saveCount
        XCTAssertEqual(saves, 0)
    }

    func testSpeechFailureAfterCommitStillSavesFullReply() async {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(snapshot: seed(), saveGate: gate)
        let native = PlaybackNativeSession()
        let service = GemmaConversationService(runtime: PlaybackNativeRuntime(native), memoryStore: store)
        let speaker = ControlledSpeaker()
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let sut = ReplyPlaybackCoordinator(reply: service, speaker: speaker, mode: .firstSentence)
        let run = Task { try await sut.run(prompt: "新しい質問", trace: trace, onUpdate: { _ in }) }
        await native.started.wait()
        native.yield("最初。続きです。")
        await speaker.waitUntilCallCount(1)
        native.finish()
        await gate.waitUntilEntered()
        await speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
        do { _ = try await run.value; XCTFail("Expected speech failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed) }
        await gate.open()
        await waitForMemory(service, .ready)
        let saved = await store.snapshot
        XCTAssertEqual(saved?.revision, 2)
        XCTAssertEqual(saved?.turns.last?.response, "最初。続きです。")
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertTrue(sink.events.contains { $0.point == .saveFinished && $0.outcome == .success })
    }

    func testSaveGateHoldsRemainderAndMicrophoneAndSaveFailureIsOnlyWarning() async {
        for fails in [false, true] {
            let gate = ConversationTestGate()
            let store = MemoryStoreFake(snapshot: seed(), saveGate: gate)
            await store.setSaveFailure(fails)
            let native = PlaybackNativeSession()
            let service = GemmaConversationService(runtime: PlaybackNativeRuntime(native), memoryStore: store)
            let harness = PlaybackIntegrationHarness(service: service, memory: service)
            let run = await harness.beginVoiceTurn()
            await native.started.wait()
            native.yield("最初。続きです。")
            await harness.speaker.waitUntilCallCount(1)
            await harness.speaker.emit(.started)
            await harness.waitForPhase(.speaking)
            native.finish()
            await gate.waitUntilEntered()
            await harness.speaker.complete()
            await harness.waitForPhase(.thinking)
            let pending = await harness.speaker.texts
            let starts = await harness.recognizer.startCount
            XCTAssertEqual(pending, ["最初。"])
            XCTAssertEqual(starts, 1)
            await gate.open()
            await harness.speaker.waitUntilCallCount(2)
            await harness.speaker.complete()
            await run.value
            await harness.waitForState { $0.memoryState == (fails ? .unsaved : .ready) }
            XCTAssertNil(harness.viewModel.viewState.errorMessage)
            let finalTexts = await harness.speaker.texts
            XCTAssertEqual(finalTexts, ["最初。", "続きです。"])
            let finalStarts = await harness.recognizer.startCount
            XCTAssertEqual(finalStarts, 2)
            await harness.viewModel.shutdown()
        }
    }

    func testForgetDuringEarlySpeechCannotResurrectTextSoundOrSavedMemory() async {
        for clearFails in [false, true] {
            let store = MemoryStoreFake(snapshot: seed())
            await store.setClearFailure(clearFails)
            let native = PlaybackNativeSession()
            let service = GemmaConversationService(runtime: PlaybackNativeRuntime(native), memoryStore: store)
            let harness = PlaybackIntegrationHarness(service: service, memory: service)
            let run = Task { await harness.viewModel.submitTypedText("質問") }
            await native.started.wait()
            native.yield("最初。続き")
            await harness.speaker.waitUntilCallCount(1)
            harness.viewModel.requestForgetConversation()
            let forget = Task { await harness.viewModel.confirmForgetConversation() }
            await native.cancelled.wait()
            native.yield("遅れて届く末尾")
            native.finish()
            await forget.value
            await run.value
            let state = await service.memoryState()
            XCTAssertEqual(state, clearFails ? .forgetFailed(.deleteFailed) : .ready)
            let saved = await store.snapshot
            if clearFails {
                XCTAssertNotNil(saved)
                XCTAssertFalse(harness.viewModel.viewState.allowsTypedSubmission)
            } else {
                XCTAssertNil(saved)
                XCTAssertEqual(harness.viewModel.viewState.caption, "")
            }
            await harness.speaker.complete(run: 0)
            let texts = await harness.speaker.texts
            XCTAssertEqual(texts, ["最初。"])
            let saves = await store.saveCount
            XCTAssertEqual(saves, 0)
            await harness.viewModel.shutdown()
        }
    }

    func testNewInputWaitsForOldSpeakerStopBeforeStarting() async {
        let gate = ConversationTestGate()
        let speaker = ControlledSpeaker(stopGate: gate)
        let harness = PlaybackIntegrationHarness(speaker: speaker)
        let old = Task { await harness.viewModel.submitTypedText("古い質問") }
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("最初。続き")
        await speaker.waitUntilCallCount(1)
        let pause = Task { await harness.viewModel.sceneBecameInactive() }
        await gate.waitUntilEntered()
        let new = Task { await harness.viewModel.submitTypedText("新しい質問") }
        await gate.open()
        await pause.value
        await old.value
        await harness.reply.waitUntilRequested(2)
        await harness.reply.yield("新しい回答。")
        await harness.reply.finish()
        await speaker.waitUntilCallCount(2)
        await speaker.complete(run: 0)
        await speaker.emit(.started, run: 1)
        await harness.waitForPhase(.speaking)
        XCTAssertEqual(harness.viewModel.viewState.caption, "新しい回答。")
        await speaker.complete(run: 1)
        await new.value
        XCTAssertEqual(harness.viewModel.viewState.phase, .paused)
        await harness.viewModel.shutdown()
    }
}
