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

    func testSummaryCapacityFailurePreservesMemoryAndDoesNotSendOversizedInput() async throws {
        let oversized = StubGemmaSession(chunks: ["unused"], usedTokens: GemmaContext.capacity)
        let runtime = RecordingGemmaRuntime(heldSummary: oversized)
        let service = GemmaConversationService(runtime: runtime)
        for i in 0..<4 { _ = try await collect(service.streamReply(to: longPrompt(i))) }
        do {
            _ = try await collect(service.streamReply(to: "first attempt"))
            XCTFail("An oversized summary must fail without resetting memory")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed)
        }
        XCTAssertTrue(oversized.prompts.isEmpty)
        XCTAssertTrue(oversized.isClosed)
        _ = try await collect(service.streamReply(to: "retry"))
        let requests = await runtime.summaryPrompts
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].contains(longPrompt(0)))
        let configurations = await runtime.configurations
        XCTAssertEqual(configurations.last?.history.map(\.prompt), [longPrompt(3)])
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
