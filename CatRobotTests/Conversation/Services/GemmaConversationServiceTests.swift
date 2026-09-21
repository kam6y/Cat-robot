import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class GemmaConversationServiceTests: XCTestCase {
    func testLongConversationCompactsBeforeTheNextReply() async throws {
        let runtime = StubGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        for index in 0..<6 {
            _ = try await collect(service.streamReply(to: "Turn \(index): " + String(repeating: "x", count: 1800)))
        }
        let kinds = await runtime.kinds
        XCTAssertGreaterThan(kinds.count, 1, "Long conversations must summarize and rebuild the reply session")
    }

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
        XCTAssertEqual(kinds, [.reply, .classification, .reply])
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

    func testOversizedInputDoesNotRequestTheUIToResetMemory() async throws {
        let service = GemmaConversationService(runtime: StubGemmaRuntime())
        do {
            _ = try await collect(service.streamReply(to: String(repeating: "x", count: 13000)))
            XCTFail("Expected an input budget error")
        } catch {
            XCTAssertNotEqual(error as? ConversationServiceError, .contextExceeded,
                              "The UI resets all memory for contextExceeded")
        }
    }

    func testOversizedPromptReportsInputTooLongWithoutSendingToNativeRuntime() async throws {
        let runtime = StubGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        do {
            _ = try await collect(service.streamReply(to: String(repeating: "あ", count: 13000)))
            XCTFail("Expected inputTooLong")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .inputTooLong)
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

    func testCompactionKeepsWholeRecentTurnsAndUpdatesPreviousSummary() async throws {
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        // Four 2,100-token prompts + four one-token replies cross 8K.
        for i in 0..<4 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        let before = await runtime.configurations
        XCTAssertEqual(before.count, 1)
        let visible = try await collect(service.streamReply(to: "next"))
        XCTAssertEqual(visible, ["R"], "Summary text must never reach captions or speech")
        let first = await runtime.configurations
        XCTAssertEqual(first.map(\.kind), [.reply, .summary, .reply])
        XCTAssertEqual(first[2].history.map(\.prompt), [longPrompt(3)])
        XCTAssertEqual(first[2].summary, "memory-1")
        let summaryRequests = await runtime.summaryPrompts
        XCTAssertTrue(summaryRequests[0].contains(longPrompt(0)))
        XCTAssertTrue(summaryRequests[0].contains(longPrompt(2)))
        XCTAssertFalse(summaryRequests[0].contains(longPrompt(3)))
        for i in 4..<7 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        _ = try await collect(service.streamReply(to: "again"))
        let second = await runtime.configurations
        XCTAssertEqual(second.last?.summary, "memory-2")
        XCTAssertEqual(second.last?.history.map(\.prompt), [longPrompt(6)])
        let updatedRequests = await runtime.summaryPrompts
        XCTAssertTrue(updatedRequests[1].contains("memory-1"))
        XCTAssertFalse(updatedRequests[1].contains(longPrompt(0)), "Already summarized raw turns must not be replayed")
        let overlap = await runtime.overlappedSessions
        XCTAssertFalse(overlap, "Only one native conversation may own the engine")
    }

    func testEmptyReplyRebuildsOnceFromCommittedHistory() async throws {
        let runtime = RecordingGemmaRuntime(replyResponses: [["R", ""], ["recovered"]])
        let service = GemmaConversationService(runtime: runtime)
        _ = try await collect(service.streamReply(to: "remember"))
        let visible = try await collect(service.streamReply(to: "continue"))
        XCTAssertEqual(visible, ["recovered"])
        let configs = await runtime.configurations
        XCTAssertEqual(configs.map(\.kind), [.reply, .reply])
        XCTAssertEqual(configs.last?.history.map(\.prompt), ["remember"])
        let overlap = await runtime.overlappedSessions
        XCTAssertFalse(overlap)
    }

    func testRepeatedEmptyReplyStopsAfterOneRetry() async throws {
        let runtime = RecordingGemmaRuntime(replyResponses: [[""]])
        let service = GemmaConversationService(runtime: runtime)
        do {
            _ = try await collect(service.streamReply(to: "hello"))
            XCTFail("Expected an error after the bounded retry")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        let configs = await runtime.configurations
        XCTAssertEqual(configs.count, 2)
        XCTAssertTrue(configs.allSatisfy { $0.history.isEmpty })
    }

    func testSuccessfulSummaryIsRolledBackWhenTheReplyFails() async throws {
        let runtime = RecordingGemmaRuntime(failFirstRebuiltReply: true)
        let service = GemmaConversationService(runtime: runtime)
        for i in 0..<4 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        do {
            _ = try await collect(service.streamReply(to: "failed reply"))
            XCTFail("Expected generation failure")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        _ = try await collect(service.streamReply(to: "retry"))
        let requests = await runtime.summaryPrompts
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1], "Neither new summary nor partial reply may replace committed history")
        let configs = await runtime.configurations
        XCTAssertEqual(configs.last?.history.map(\.prompt), [longPrompt(3)])
        XCTAssertEqual(configs.last?.summary, "memory-2")
    }

    func testRetentionRoundsUpToMultipleCompleteTurns() async throws {
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        for i in 0..<8 {
            _ = try await collect(service.streamReply(to: "\(i):" + String(repeating: "x", count: 1098)))
        }
        _ = try await collect(service.streamReply(to: "compact"))
        let configs = await runtime.configurations
        XCTAssertEqual(configs.last?.history.map { String($0.prompt.prefix(2)) }, ["6:", "7:"])
        XCTAssertEqual(configs.last?.history.reduce(0) { $0 + $1.rawTokens }, 2202)
    }

    func testFailedSummaryLeavesOriginalHistoryForRetry() async throws {
        let runtime = RecordingGemmaRuntime(summaryOutputs: ["", "recovered memory"])
        let service = GemmaConversationService(runtime: runtime)
        for i in 0..<4 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        do {
            _ = try await collect(service.streamReply(to: "first attempt"))
            XCTFail("Empty summaries cannot replace memory")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        _ = try await collect(service.streamReply(to: "retry"))
        let requests = await runtime.summaryPrompts
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        let configs = await runtime.configurations
        XCTAssertEqual(configs.last?.summary, "recovered memory")
        XCTAssertEqual(configs.last?.history.map(\.prompt), [longPrompt(3)])
    }

    func testCancelledSummaryDrainsBeforeRetryAndDoesNotReplaceMemory() async throws {
        let held = StubGemmaSession(chunks: nil)
        let runtime = RecordingGemmaRuntime(heldSummary: held)
        let service = GemmaConversationService(runtime: runtime)
        for i in 0..<4 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        let reader = Task { try await self.collect(service.streamReply(to: "interrupted")) }
        await held.waitUntilStarted()
        reader.cancel()
        _ = try? await reader.value
        await held.waitUntilCancelled()
        let retry = Task { try await self.collect(service.streamReply(to: "retry")) }
        await Task.yield()
        let beforeDrain = await runtime.configurations
        XCTAssertEqual(beforeDrain.map(\.kind), [.reply, .summary])
        held.finish()
        let visible = try await retry.value
        XCTAssertEqual(visible, ["R"])
        let requests = await runtime.summaryPrompts
        XCTAssertEqual(requests[0], requests[1])
        let overlap = await runtime.overlappedSessions
        XCTAssertFalse(overlap)
    }

    func testResetClearsBothSummaryAndRetainedHistory() async throws {
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        for i in 0..<4 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        _ = try await collect(service.streamReply(to: "compact"))
        await service.reset()
        _ = try await collect(service.streamReply(to: "new conversation"))
        let configs = await runtime.configurations
        XCTAssertTrue(configs.last!.history.isEmpty)
        XCTAssertTrue(configs.last!.summary.isEmpty)
    }

    func testClassificationRebuildsReplyFromCommittedHistoryOnly() async throws {
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        _ = try await collect(service.streamReply(to: "remember this"))
        _ = try await service.classify("unrelated classification")
        _ = try await collect(service.streamReply(to: "recall"))
        let configs = await runtime.configurations
        XCTAssertEqual(configs.map(\.kind), [.reply, .classification, .reply])
        XCTAssertTrue(configs[1].history.isEmpty)
        XCTAssertTrue(configs[1].summary.isEmpty)
        XCTAssertEqual(configs[2].history.map(\.prompt), ["remember this"])
        XCTAssertEqual(configs[2].history.map(\.response), ["R"])
        let overlap = await runtime.overlappedSessions
        XCTAssertFalse(overlap)
    }

    func testTwelveKBudgetIncludesReplayedPrefaceAndRejectsBeforeSending() async throws {
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime)
        _ = try await collect(service.streamReply(to: String(repeating: "あ", count: 9000)))
        _ = try await service.classify("separate")
        do {
            _ = try await collect(service.streamReply(to: String(repeating: "x", count: 4000)))
            XCTFail("Replayed history must be included in the native budget")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .inputTooLong) }
        // An oversized input has not replaced the committed conversation.
        _ = try await collect(service.streamReply(to: "short"))
        let configs = await runtime.configurations
        XCTAssertEqual(configs.last?.history.first?.prompt.count, 9000)
    }

    private func longPrompt(_ index: Int) -> String {
        "\(index):" + String(repeating: "x", count: 2098)
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
    func countTokens(_ text: String) async throws -> Int { text.count }
    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        let kind = configuration.kind
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
    func inputTokenCount(_ prompt: String) throws -> Int { prompt.count }
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    func close() { lock.withLock { closed = true } }
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

/// Native inference is slow and unavailable in the simulator. This boundary fake
/// models lazy history replay and detects overlapping conversation lifetimes.
private actor RecordingGemmaRuntime: GemmaRuntime {
    private(set) var configurations: [GemmaSessionConfiguration] = []
    private(set) var overlappedSessions = false
    private var sessions: [RecordingGemmaSession] = []
    private var summaries: [StubGemmaSession] = []
    private let summaryOutputs: [String]
    private let heldSummary: StubGemmaSession?
    private var failFirstRebuiltReply: Bool
    private let replyResponses: [[String]]
    private var replyCreations = 0
    var summaryPrompts: [String] { summaries.flatMap(\.prompts) }

    init(summaryOutputs: [String] = ["memory-1", "memory-2"], heldSummary: StubGemmaSession? = nil, failFirstRebuiltReply: Bool = false, replyResponses: [[String]] = [["R"]]) {
        self.summaryOutputs = summaryOutputs
        self.heldSummary = heldSummary
        self.failFirstRebuiltReply = failFirstRebuiltReply
        self.replyResponses = replyResponses
    }
    func prepare() async throws {}
    func countTokens(_ text: String) async throws -> Int { text.count }
    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        overlappedSessions = overlappedSessions || sessions.contains { !$0.isClosed } || summaries.contains { !$0.isClosed }
        configurations.append(configuration)
        if configuration.kind == .summary {
            let index = summaries.count
            let session = index == 0 ? (heldSummary ?? StubGemmaSession(chunks: [summaryOutputs[0]]))
                : StubGemmaSession(chunks: [summaryOutputs[min(index, summaryOutputs.count - 1)]])
            summaries.append(session)
            return session
        }
        let fails = failFirstRebuiltReply && !configuration.summary.isEmpty
        if fails { failFirstRebuiltReply = false }
        let responses = replyResponses[min(replyCreations, replyResponses.count - 1)]
        if configuration.kind == .reply { replyCreations += 1 }
        let session = RecordingGemmaSession(configuration: configuration, fails: fails, responses: responses)
        sessions.append(session)
        return session
    }
}

private final class RecordingGemmaSession: GemmaSession, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: GemmaSessionConfiguration
    private var used = 0
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    private let fails: Bool
    private let responses: [String]
    private var sends = 0
    init(configuration: GemmaSessionConfiguration, fails: Bool, responses: [String]) {
        self.configuration = configuration
        self.fails = fails
        self.responses = responses
    }
    func tokenCount() throws -> Int { lock.withLock { used } }
    func inputTokenCount(_ prompt: String) throws -> Int {
        lock.withLock {
            let preface = used == 0 ? 100 + configuration.summary.count + configuration.history.reduce(0) { $0 + $1.rawTokens } : 0
            return preface + prompt.count + 10
        }
    }
    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        let pending = try! inputTokenCount(prompt)
        let response = lock.withLock {
            used += pending + 1
            let result = responses[min(sends, responses.count - 1)]
            sends += 1
            return result
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(configuration.kind == .classification ? "addressed" : response)
            continuation.finish(throwing: fails ? ConversationServiceError.modelGenerationFailed : nil)
        }
    }
    func cancel() {}
    func close() { lock.withLock { closed = true } }
}
