import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class GemmaConversationServiceTests: XCTestCase {
    func testDeltasBecomeCumulativeSnapshotsAndReplyHistorySurvivesClassification() async throws {
        let runtime = StubGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        let first = try await collect(service.streamReply(to: "こんにちは"))
        let target = try await service.classify("これは猫への質問？")
        let second = try await collect(service.streamReply(to: "続き"))
        XCTAssertEqual(first, ["にゃ", "にゃん。"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(target, .addressed)
        let kinds = await runtime.kinds
        XCTAssertEqual(kinds, [.reply, .classification])
    }

    func testResetDiscardsConversationButKeepsSharedRuntime() async throws {
        let runtime = StubGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        _ = try await collect(service.streamReply(to: "一回目"))
        await service.reset()
        _ = try await collect(service.streamReply(to: "二回目"))
        let kinds = await runtime.kinds
        XCTAssertEqual(kinds, [.reply, .reply])
    }

    func testInvalidClassifierOutputIsAmbiguousRatherThanAccidentalAddressMatch() async throws {
        let service = GemmaConversationService(runtime: StubGemmaRuntime(classification: "notAddressed because addressed"))
        let target = try await service.classify("発話")
        XCTAssertEqual(target, .ambiguous)
    }

    func testOversizedPromptReportsContextExceededWithoutSendingToNativeRuntime() async throws {
        let runtime = StubGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        do {
            _ = try await collect(service.streamReply(to: String(repeating: "あ", count: 3000)))
            XCTFail("Expected contextExceeded")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .contextExceeded)
        }
        let sent = runtime.reply.prompts
        XCTAssertTrue(sent.isEmpty)
        await service.reset()
        let recovered = try await collect(service.streamReply(to: "再開"))
        XCTAssertEqual(recovered.last, "にゃん。")
    }

    func testMissingAndInvalidModelsHaveGemmaSpecificAvailability() async {
        for (failure, expected) in [(GemmaRuntimeFailure.missingModel, ModelAvailability.gemmaModelMissing),
                                    (.invalidModel, .gemmaModelInvalid), (.unavailable, .gemmaUnavailable)] {
            let service = GemmaConversationService(runtime: StubGemmaRuntime(failure: failure))
            let actual = await service.availability()
            XCTAssertEqual(actual, expected)
            let message = ConversationErrorPresentation(.modelUnavailable(actual)).message
            XCTAssertFalse(message.contains("Apple Intelligence"))
        }
    }

    func testCancellationStopsNativeSessionAndWaitsForDrainBeforeNextGeneration() async throws {
        let session = StubGemmaSession(chunks: nil)
        let runtime = StubGemmaRuntime(reply: session)
        let service = GemmaConversationService(runtime: runtime)
        let stream = try await service.streamReply(to: "長い返答")
        let reader = Task { try await collect(stream) }
        await session.waitUntilStarted()
        reader.cancel()
        _ = try? await reader.value
        await session.waitUntilCancelled()
        let resumed = Task { try await self.collect(service.streamReply(to: "すぐ再開")) }
        await Task.yield()
        XCTAssertEqual(session.prompts, ["長い返答"])
        session.finish()
        let result = try await resumed.value
        XCTAssertEqual(result.last, "再開できた。")
        let kinds = await runtime.kinds
        XCTAssertEqual(kinds, [.reply, .reply])
    }

    func testConcurrentUncancelledGenerationStillReportsBusy() async throws {
        let session = StubGemmaSession(chunks: nil)
        let service = GemmaConversationService(runtime: StubGemmaRuntime(reply: session))
        let stream = try await service.streamReply(to: "実行中")
        let reader = Task { try await self.collect(stream) }
        await session.waitUntilStarted()
        do {
            _ = try await service.streamReply(to: "同時実行")
            XCTFail("Expected modelBusy")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .modelBusy) }
        reader.cancel()
        session.finish()
        _ = try? await reader.value
        await service.reset()
    }

    func testModelValidationRejectsMissingAndTruncatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = GemmaModelFile(url: directory.appendingPathComponent("model.litertlm"))
        XCTAssertThrowsError(try file.validate()) { error in
            guard case GemmaRuntimeFailure.missingModel = error else { return XCTFail("Expected missing model") }
        }
        try Data("partial download".utf8).write(to: file.url)
        XCTAssertThrowsError(try file.validate()) { error in
            guard case GemmaRuntimeFailure.invalidModel = error else { return XCTFail("Expected invalid model") }
        }
    }

    func testCancelledClassificationDrainsBeforeReplyStarts() async throws {
        let classifier = StubGemmaSession(chunks: nil)
        let runtime = StubGemmaRuntime(classifierSession: classifier)
        let service = GemmaConversationService(runtime: runtime)
        let classification = Task { try await service.classify("宛先の判定") }
        await classifier.waitUntilStarted()
        classification.cancel()
        _ = try? await classification.value
        await classifier.waitUntilCancelled()
        let reply = Task { try await self.collect(service.streamReply(to: "猫への質問")) }
        classifier.finish()
        let result = try await reply.value
        XCTAssertEqual(result.last, "にゃん。")
        let kinds = await runtime.kinds
        XCTAssertEqual(kinds, [.classification, .reply])
    }

    func testTerminalArbitrationDiscardsCancelledSessionButDoesNotCancelFinishedSession() throws {
        let cancelledSession = StubGemmaSession(chunks: nil)
        let cancelled = GemmaInferenceCancellation()
        _ = try cancelled.start(cancelledSession, prompt: "A", outputLimit: 160)
        cancelled.cancel()
        XCTAssertTrue(cancelled.finish(), "Cancel won: native conversation must be discarded")
        XCTAssertTrue(cancelledSession.wasCancelled)
        cancelledSession.finish()

        let finishedSession = StubGemmaSession(chunks: ["完了"])
        let finished = GemmaInferenceCancellation()
        _ = try finished.start(finishedSession, prompt: "B", outputLimit: 160)
        XCTAssertFalse(finished.finish())
        finished.cancel()
        XCTAssertFalse(finishedSession.wasCancelled, "Completion won: stale cancellation must be ignored")
    }

    private func collect(_ source: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var values: [String] = []
        for try await value in source { values.append(value) }
        return values
    }
}

private actor StubGemmaRuntime: GemmaRuntime {
    let reply: StubGemmaSession
    let classification: String
    let classifierSession: StubGemmaSession?
    let failure: GemmaRuntimeFailure?
    private(set) var kinds: [GemmaSessionKind] = []

    init(reply: StubGemmaSession = StubGemmaSession(chunks: ["にゃ", "ん。"]),
         classification: String = "addressed", failure: GemmaRuntimeFailure? = nil,
         classifierSession: StubGemmaSession? = nil) {
        self.reply = reply
        self.classification = classification
        self.classifierSession = classifierSession
        self.failure = failure
    }
    func prepare() async throws { if let failure { throw failure } }
    func makeSession(_ kind: GemmaSessionKind) async throws -> any GemmaSession {
        kinds.append(kind)
        return kind == .reply ? reply : (classifierSession ?? StubGemmaSession(chunks: [classification]))
    }
}

private final class StubGemmaSession: GemmaSession, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [String]?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var storedPrompts: [String] = []
    private var started = false
    private var cancelled = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var prompts: [String] { lock.withLock { storedPrompts } }
    init(chunks: [String]?) { self.chunks = chunks }
    func tokenCount() throws -> Int { 100 }
    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
                storedPrompts.append(prompt)
                started = true
            }
            if let chunks {
                chunks.forEach { continuation.yield($0) }
                continuation.finish()
            } else if prompts.count > 1 {
                continuation.yield("再開できた。")
                continuation.finish()
            }
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func finish() { lock.withLock { continuation }?.finish() }
    func waitUntilStarted() async { while !lock.withLock({ started }) { await Task.yield() } }
    func waitUntilCancelled() async { while !lock.withLock({ cancelled }) { await Task.yield() } }
}
