import Foundation
import FoundationModels
import XCTest
@testable import CatRobot

final class ToolEnabledReplyServiceTests: XCTestCase {
    private enum ResetInterleavingOutcome: Equatable, Sendable {
        case replyRejectedAsBusy
        case replyWasNotRejectedAsBusy
        case sharedPreparationWasCancelled
    }

    func testPrepareIsLazyAndRegistersExactlyFourStableSharedTools() async throws {
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let storeCreationCount = LockedCounter()
        let client = ReplySessionClientSpy { _, _, _, continuation in
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(clients: [client])
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: {
                storeCreationCount.increment()
                return try LocalMemoryStore(persistence: persistence)
            },
            dateTimeProvider: RecordingDateTimeProvider()
        )

        XCTAssertEqual(storeCreationCount.value, 0)
        async let first: Void = service.prepare()
        async let second: Void = service.prepare()
        try await first
        try await second
        try await service.prepare()

        let toolArrays = await factory.receivedToolArrays
        let prepareCount = await factory.prepareCount
        let makeCount = await factory.makeCount
        let prewarmCount = await client.prewarmCount
        XCTAssertEqual(storeCreationCount.value, 1)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(makeCount, 1)
        XCTAssertEqual(prewarmCount, 1)
        XCTAssertEqual(toolArrays.count, 1)
        let tools = try XCTUnwrap(toolArrays.first)
        XCTAssertEqual(
            tools.map(\.name),
            ["rememberMemory", "forgetMemory", "searchMemory", "getCurrentDateTime"]
        )
        XCTAssertTrue(tools[0] is RememberMemoryTool)
        XCTAssertTrue(tools[1] is ForgetMemoryTool)
        XCTAssertTrue(tools[2] is SearchMemoryTool)
        XCTAssertTrue(tools[3] is CurrentDateTimeTool)
    }

    func testSuccessfulReplyEmitsDraftsThenOneCommittedAfterMemoryCommit() async throws {
        let sourceFinishGate = ReplySessionBlockingGate()
        let draftsReceived = ReplySessionSignal()
        let harness = try ToolEnabledReplyServiceHarness { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(
                    arguments: .init(fact: "青が好き", supportingQuote: "青が好き")
                )
                continuation.yield("わかった")
                continuation.yield("わかった、覚えたよ")
                await sourceFinishGate.enterAndWaitIgnoringCancellation()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let collection = Task { () throws -> [ReplyStreamEvent] in
            let stream = try await harness.service.streamReply(
                to: .init(turnID: 41, userText: "青が好きです")
            )
            var events: [ReplyStreamEvent] = []
            var draftCount = 0
            for try await event in stream {
                events.append(event)
                switch event {
                case .draft:
                    harness.timeline.append(.draft)
                    draftCount += 1
                    if draftCount == 2 {
                        await draftsReceived.signal()
                    }
                case .committed:
                    harness.timeline.append(.committed)
                }
            }
            return events
        }
        await draftsReceived.wait()
        await sourceFinishGate.release()
        let events = try await collection.value

        XCTAssertEqual(
            events,
            [
                .draft("わかった"),
                .draft("わかった、覚えたよ"),
                .committed(
                    .init(finalText: "わかった、覚えたよ", memoryChange: .remembered)
                ),
            ]
        )
        let savedFacts = harness.persistence.savedFacts
        let timeline = harness.timeline.values
        let prompts = await harness.client.prompts
        let options = await harness.client.options
        let transcriptCount = await harness.client.transcriptCount
        let restoreCount = await harness.client.restoreCount
        XCTAssertEqual(savedFacts.count, 1)
        XCTAssertEqual(savedFacts.first?.fact, "青が好き")
        XCTAssertEqual(
            timeline,
            [.draft, .draft, .memorySaved, .committed]
        )
        XCTAssertEqual(prompts, ["青が好きです"])
        XCTAssertEqual(
            options,
            [.init(ReplyGenerationPolicy.live.makeOptions())]
        )
        XCTAssertEqual(transcriptCount, 1)
        XCTAssertEqual(restoreCount, 0)
    }

    func testCommitAggregatesRememberNoticesAsRemembered() async throws {
        let harness = try ToolEnabledReplyServiceHarness { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                _ = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
                continuation.yield("覚えたよ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let events = try await harness.collect(
            request: .init(turnID: 1, userText: "青が好きで猫が好き")
        )

        XCTAssertEqual(events.last, .committed(.init(finalText: "覚えたよ", memoryChange: .remembered)))
        XCTAssertEqual(Set(harness.persistence.savedFacts.map(\.fact)), ["青が好き", "猫が好き"])
    }

    func testCommitAggregatesForgetNoticesAsForgotten() async throws {
        let fact = makeFact(id: "00000000-0000-0000-0000-000000000001", text: "赤が好き")
        let harness = try ToolEnabledReplyServiceHarness(facts: [fact]) { tools, _, _, continuation in
            do {
                let search = try requireTool(SearchMemoryTool.self, in: tools)
                let forget = try requireTool(ForgetMemoryTool.self, in: tools)
                let output = try await search.call(arguments: .init(query: "赤", limit: 1))
                let result = try JSONDecoder().decode([MemorySearchResult].self, from: Data(output.utf8))
                let id = try XCTUnwrap(result.first?.id)
                _ = try await forget.call(arguments: .init(memoryIDs: [id], supportingQuote: "赤は忘れて"))
                continuation.yield("忘れたよ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let events = try await harness.collect(
            request: .init(turnID: 2, userText: "赤は忘れて")
        )

        XCTAssertEqual(events.last, .committed(.init(finalText: "忘れたよ", memoryChange: .forgotten)))
        XCTAssertTrue(harness.persistence.savedFacts.isEmpty)
    }

    func testCommitAggregatesMixedNoticesAsUpdated() async throws {
        let fact = makeFact(id: "00000000-0000-0000-0000-000000000001", text: "赤が好き")
        let harness = try ToolEnabledReplyServiceHarness(facts: [fact]) { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                let search = try requireTool(SearchMemoryTool.self, in: tools)
                let forget = try requireTool(ForgetMemoryTool.self, in: tools)
                let output = try await search.call(arguments: .init(query: "赤", limit: 1))
                let result = try JSONDecoder().decode([MemorySearchResult].self, from: Data(output.utf8))
                let id = try XCTUnwrap(result.first?.id)
                _ = try await forget.call(arguments: .init(memoryIDs: [id], supportingQuote: "赤は忘れて"))
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield("更新したよ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let events = try await harness.collect(
            request: .init(turnID: 3, userText: "赤は忘れて、青が好き")
        )

        XCTAssertEqual(events.last, .committed(.init(finalText: "更新したよ", memoryChange: .updated)))
        XCTAssertEqual(harness.persistence.savedFacts.map(\.fact), ["青が好き"])
    }

    func testSearchAndDateOnlyReplyCommitsWithoutMemoryChange() async throws {
        let fact = makeFact(id: "00000000-0000-0000-0000-000000000001", text: "青が好き")
        let provider = RecordingDateTimeProvider()
        let harness = try ToolEnabledReplyServiceHarness(
            facts: [fact],
            dateTimeProvider: provider
        ) { tools, _, _, continuation in
            do {
                let search = try requireTool(SearchMemoryTool.self, in: tools)
                let date = try requireTool(CurrentDateTimeTool.self, in: tools)
                _ = try await search.call(arguments: .init(query: "青", limit: 1))
                _ = try await date.call(arguments: .init(includeSeconds: false))
                continuation.yield("今日は月曜日だよ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let events = try await harness.collect(
            request: .init(turnID: 4, userText: "今日と好きな色を教えて")
        )

        XCTAssertEqual(events.last, .committed(.init(finalText: "今日は月曜日だよ", memoryChange: nil)))
        XCTAssertEqual(harness.persistence.savedFacts, [fact])
        XCTAssertEqual(provider.callCount, 1)
    }

    func testGenerationFailureRollsBackStagedMemoryAndRestoresTranscript() async throws {
        let harness = try ToolEnabledReplyServiceHarness { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield("覚え")
                continuation.finish(throwing: ReplyServiceTestFailure.generation)
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let error = await capturedServiceError {
            _ = try await harness.collect(request: .init(turnID: 5, userText: "青が好き"))
        }
        let committedFacts = await harness.store.committedFacts()
        let restoreCount = await harness.client.restoreCount
        let didEmitCommitted = await harness.didEmitCommitted

        XCTAssertEqual(error, .modelGenerationFailed)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertTrue(harness.persistence.savedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(didEmitCommitted)
    }

    func testToolDecodingFailureRollsBackAndRestoresTranscript() async throws {
        let harness = try ToolEnabledReplyServiceHarness { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.finish(throwing: ReplyServiceTestFailure.decoding)
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let error = await capturedServiceError {
            _ = try await harness.collect(request: .init(turnID: 6, userText: "青が好き"))
        }
        let committedFacts = await harness.store.committedFacts()
        let restoreCount = await harness.client.restoreCount
        let didEmitCommitted = await harness.didEmitCommitted

        XCTAssertEqual(error, .modelGenerationFailed)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(didEmitCommitted)
    }

    func testCancellationAfterDraftWaitsForRollbackAndRestoresTranscript() async throws {
        let draftReceived = ReplySessionSignal()
        let harness = try ToolEnabledReplyServiceHarness(blocksRestore: true) { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield("覚えた")
                try await Task.sleep(for: .seconds(60))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let consumer = Task {
            let stream = try await harness.service.streamReply(
                to: .init(turnID: 7, userText: "青が好き")
            )
            for try await event in stream {
                if case .draft = event {
                    harness.timeline.append(.draft)
                    await draftReceived.signal()
                }
            }
        }
        await draftReceived.wait()
        consumer.cancel()

        let completion = CompletionProbe()
        let cleanup = Task {
            await harness.service.cancelActiveReply()
            await completion.markCompleted()
        }
        await harness.waitUntilRestoreStarted()
        let completedWhileRestoreWasBlocked = await completion.isCompleted
        XCTAssertFalse(completedWhileRestoreWasBlocked)
        await harness.releaseRestore()
        await cleanup.value
        _ = await consumer.result

        let committedFacts = await harness.store.committedFacts()
        let restoreCount = await harness.client.restoreCount
        let didEmitCommitted = await harness.didEmitCommitted
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(didEmitCommitted)
    }

    func testCancellationDuringSetupWaitsForSetupAndCleanupBarrier() async throws {
        let snapshotsGate = ReplySessionBlockingGate()
        let toolBodyCount = LockedCounter()
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let client = PullDrivenReplySessionClientSpy(snapshotsGate: snapshotsGate) { tools, _, index in
            guard index == 0 else { return nil }
            toolBodyCount.increment()
            let remember = try requireTool(RememberMemoryTool.self, in: tools)
            _ = try await remember.call(arguments: .init(fact: "古い記憶", supportingQuote: "古い記憶"))
            return "古い応答"
        }
        let factory = ReplySessionFactorySpy(clients: [client])
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider()
        )
        let request = Task {
            try await service.streamReply(
                to: .init(turnID: 71, userText: "古い記憶")
            )
        }
        await snapshotsGate.waitUntilStarted()

        let completion = CompletionProbe()
        let cleanup = Task {
            await service.cancelActiveReply()
            await completion.markCompleted()
        }
        await snapshotsGate.waitUntilCancellationObserved()
        let completedWhileSetupWasBlocked = await completion.isCompleted
        await snapshotsGate.release()
        _ = await request.result
        await cleanup.value

        let committedFacts = await store.committedFacts()
        let restoreCount = await client.restoreCount
        XCTAssertFalse(completedWhileSetupWasBlocked)
        XCTAssertEqual(toolBodyCount.value, 0)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
    }

    func testResetDuringSetupWaitsAndPreventsOldClientFromCommitting() async throws {
        let snapshotsGate = ReplySessionBlockingGate()
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let oldClient = PullDrivenReplySessionClientSpy(snapshotsGate: snapshotsGate) { tools, _, index in
            guard index == 0 else { return nil }
            let remember = try requireTool(RememberMemoryTool.self, in: tools)
            _ = try await remember.call(arguments: .init(fact: "古い記憶", supportingQuote: "古い記憶"))
            return "古い応答"
        }
        let freshClient = ReplySessionClientSpy { _, _, _, continuation in
            continuation.yield("新しい応答")
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(clients: [oldClient, freshClient])
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider()
        )
        let oldRequest = Task {
            try await service.streamReply(
                to: .init(turnID: 72, userText: "古い記憶")
            )
        }
        await snapshotsGate.waitUntilStarted()

        let resetCompletion = CompletionProbe()
        let reset = Task {
            await service.reset()
            await resetCompletion.markCompleted()
        }
        await snapshotsGate.waitUntilCancellationObserved()
        let resetReturnedWhileSetupWasBlocked = await resetCompletion.isCompleted
        await snapshotsGate.release()

        switch await oldRequest.result {
        case let .success(stream):
            do {
                for try await _ in stream {}
            } catch {}
        case .failure:
            break
        }
        await reset.value
        _ = try await collect(
            service: service,
            request: .init(turnID: 73, userText: "新しい会話")
        )

        let committedFacts = await store.committedFacts()
        let oldRestoreCount = await oldClient.restoreCount
        XCTAssertFalse(resetReturnedWhileSetupWasBlocked)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(oldRestoreCount, 1)
    }

    func testResetOwnsBarrierAcrossOldCleanupAndFreshPreparation() async throws {
        let oldSourceGate = ReplySessionBlockingGate()
        let freshPreparationGate = ReplySessionBlockingGate()
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let oldClient = PullDrivenReplySessionClientSpy { _, prompt, index in
            guard prompt == "old", index == 0 else { return nil }
            await oldSourceGate.enterAndWaitIgnoringCancellation()
            return nil
        }
        let freshClient = ReplySessionClientSpy { _, _, _, continuation in
            continuation.yield("fresh")
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(
            clients: [oldClient, freshClient],
            prepareGate: freshPreparationGate,
            gatedPrepareCall: 2
        )
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider()
        )
        try await service.prepare()
        let oldConsumer = Task {
            try await collect(
                service: service,
                request: .init(turnID: 721, userText: "old")
            )
        }
        await oldSourceGate.waitUntilStarted()

        let resetCompletion = CompletionProbe()
        let reset = Task {
            await service.reset()
            await resetCompletion.markCompleted()
        }
        await oldSourceGate.waitUntilCancellationObserved()
        await oldSourceGate.release()
        await freshPreparationGate.waitUntilStarted()

        let firstOutcome = FirstValue<ResetInterleavingOutcome>()
        let replyDuringReset = Task {
            let error = await capturedServiceError {
                _ = try await service.streamReply(
                    to: .init(turnID: 722, userText: "during reset")
                )
            }
            await firstOutcome.resolve(
                error == .modelBusy
                    ? .replyRejectedAsBusy
                    : .replyWasNotRejectedAsBusy
            )
            return error
        }
        replyDuringReset.cancel()
        let preparationObserver = Task {
            let wasCancelled = await freshPreparationGate.waitForCancellationOrRelease()
            if wasCancelled {
                await firstOutcome.resolve(.sharedPreparationWasCancelled)
            }
        }

        let outcome = await firstOutcome.wait()
        let resetReturnedWhilePreparationWasBlocked = await resetCompletion.isCompleted
        await freshPreparationGate.release()
        await reset.value
        _ = await oldConsumer.result
        let replyError = await replyDuringReset.value
        await preparationObserver.value

        let makeCountAtResetCompletion = await factory.makeCount
        let oldPrompts = await oldClient.prompts
        let freshPromptsBeforePostResetReply = await freshClient.prompts
        let postResetEvents = try await collect(
            service: service,
            request: .init(turnID: 723, userText: "after reset")
        )
        let freshPrompts = await freshClient.prompts

        XCTAssertEqual(outcome, .replyRejectedAsBusy)
        XCTAssertEqual(replyError, .modelBusy)
        XCTAssertFalse(resetReturnedWhilePreparationWasBlocked)
        XCTAssertEqual(makeCountAtResetCompletion, 2)
        XCTAssertEqual(oldPrompts, ["old"])
        XCTAssertTrue(freshPromptsBeforePostResetReply.isEmpty)
        XCTAssertEqual(freshPrompts, ["after reset"])
        XCTAssertEqual(
            postResetEvents.last,
            .committed(.init(finalText: "fresh", memoryChange: nil))
        )
    }

    func testCancelledPublicPrepareCannotCancelResetOwnedPreparation() async throws {
        let freshPreparationGate = ReplySessionBlockingGate()
        let prepareDuringReset = ReplySessionPulse()
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let oldClient = ReplySessionClientSpy { _, _, _, continuation in
            continuation.finish()
        }
        let freshClient = ReplySessionClientSpy { _, _, _, continuation in
            continuation.yield("fresh")
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(
            clients: [oldClient, freshClient],
            prepareGate: freshPreparationGate,
            gatedPrepareCall: 2
        )
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider(),
            testHooks: .init(
                publicPrepareEnteredDuringReset: {
                    await prepareDuringReset.signal()
                }
            )
        )
        try await service.prepare()

        let reset = Task { await service.reset() }
        await freshPreparationGate.waitUntilStarted()
        await prepareDuringReset.discardPending()

        let externalPrepare = Task { () -> ConversationServiceError? in
            do {
                try await service.prepare()
                return nil
            } catch let error as ConversationServiceError {
                return error
            } catch {
                XCTFail("Expected ConversationServiceError")
                return nil
            }
        }
        await prepareDuringReset.wait()
        externalPrepare.cancel()
        await freshPreparationGate.release()
        await reset.value
        let externalPrepareError = await externalPrepare.value

        let makeCountAtResetCompletion = await factory.makeCount
        let freshPromptsBeforeReply = await freshClient.prompts
        let events = try await collect(
            service: service,
            request: .init(turnID: 724, userText: "after reset")
        )
        let makeCountAfterReply = await factory.makeCount
        let freshPrompts = await freshClient.prompts

        XCTAssertEqual(externalPrepareError, .cancelled)
        XCTAssertEqual(makeCountAtResetCompletion, 2)
        XCTAssertEqual(makeCountAfterReply, 2)
        XCTAssertTrue(freshPromptsBeforeReply.isEmpty)
        XCTAssertEqual(freshPrompts, ["after reset"])
        XCTAssertEqual(
            events.last,
            .committed(.init(finalText: "fresh", memoryChange: nil))
        )
    }

    func testConcurrentResetWaiterCanImmediatelyUseFreshClient() async throws {
        let freshPreparationGate = ReplySessionBlockingGate()
        let concurrentResetJoined = ReplySessionSignal()
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let oldClient = ReplySessionClientSpy { _, _, _, continuation in
            continuation.finish()
        }
        let freshClient = ReplySessionClientSpy { _, _, _, continuation in
            continuation.yield("fresh")
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(
            clients: [oldClient, freshClient],
            prepareGate: freshPreparationGate,
            gatedPrepareCall: 2
        )
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider(),
            testHooks: .init(
                concurrentResetJoined: {
                    await concurrentResetJoined.signal()
                }
            )
        )
        try await service.prepare()

        let originalReset = Task(priority: .background) {
            await service.reset()
        }
        await freshPreparationGate.waitUntilStarted()
        let secondResetAndReply = Task(priority: .userInitiated) {
            await service.reset()
            do {
                return Result<[ReplyStreamEvent], ConversationServiceError>.success(
                    try await collect(
                        service: service,
                        request: .init(turnID: 725, userText: "after shared reset")
                    )
                )
            } catch let error as ConversationServiceError {
                return .failure(error)
            } catch {
                return .failure(.modelGenerationFailed)
            }
        }
        await concurrentResetJoined.wait()
        await freshPreparationGate.release()

        let result = await secondResetAndReply.value
        await originalReset.value
        let makeCount = await factory.makeCount
        let freshPrompts = await freshClient.prompts

        switch result {
        case let .success(events):
            XCTAssertEqual(
                events.last,
                .committed(.init(finalText: "fresh", memoryChange: nil))
            )
        case let .failure(error):
            XCTFail("Expected immediate post-reset reply, got \(error)")
        }
        XCTAssertEqual(makeCount, 2)
        XCTAssertEqual(freshPrompts, ["after shared reset"])
    }

    func testCancellationWaitsForPullDrivenSourceBeforeRollbackAndNewTurn() async throws {
        let oldSourceGate = ReplySessionBlockingGate()
        let newSourceGate = ReplySessionBlockingGate()
        let oldMutationFinished = ReplySessionSignal()
        let stagedRememberResult = LockedValue<String?>(nil)
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let client = PullDrivenReplySessionClientSpy { tools, prompt, index in
            if prompt == "古い記憶" {
                if index == 0 { return "draft" }
                if index == 1 {
                    await oldSourceGate.enterAndWaitIgnoringCancellation()
                    let remember = try requireTool(RememberMemoryTool.self, in: tools)
                    let result = try await remember.call(
                        arguments: .init(fact: "古い記憶", supportingQuote: "古い記憶")
                    )
                    stagedRememberResult.set(result)
                    await oldMutationFinished.signal()
                }
                return nil
            }

            if index == 0 {
                await newSourceGate.enterAndWaitIgnoringCancellation()
                return "new"
            }
            return nil
        }
        let factory = ReplySessionFactorySpy(clients: [client])
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider()
        )
        let oldConsumer = Task {
            try await collect(
                service: service,
                request: .init(turnID: 74, userText: "古い記憶")
            )
        }
        await oldSourceGate.waitUntilStarted()

        let cleanupCompletion = CompletionProbe()
        let cleanup = Task {
            await service.cancelActiveReply()
            await cleanupCompletion.markCompleted()
        }
        await oldSourceGate.waitUntilCancellationObserved()
        let cleanupReturnedBeforeSourceFinished = await cleanupCompletion.isCompleted

        var overlappingNewTurn: Task<Result<[ReplyStreamEvent], Error>, Never>?
        if cleanupReturnedBeforeSourceFinished {
            overlappingNewTurn = Task {
                do {
                    return .success(
                        try await collect(
                            service: service,
                            request: .init(turnID: 75, userText: "new")
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }
            await newSourceGate.waitUntilStarted()
        }

        await oldSourceGate.release()
        await oldMutationFinished.wait()
        if overlappingNewTurn != nil {
            await newSourceGate.release()
        }
        _ = await oldConsumer.result
        await cleanup.value
        if let overlappingNewTurn {
            _ = await overlappingNewTurn.value
        } else {
            let newTurn = Task {
                try await collect(
                    service: service,
                    request: .init(turnID: 75, userText: "new")
                )
            }
            await newSourceGate.waitUntilStarted()
            await newSourceGate.release()
            _ = try await newTurn.value
        }

        let committedFacts = await store.committedFacts()
        let restoreCount = await client.restoreCount
        XCTAssertFalse(cleanupReturnedBeforeSourceFinished)
        XCTAssertEqual(stagedRememberResult.value, "Remember staged: 古い記憶")
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
    }

    func testThirteenthToolCallDoesNotRunToolBodyAndRollsBack() async throws {
        let provider = RecordingDateTimeProvider()
        let harness = try ToolEnabledReplyServiceHarness(
            dateTimeProvider: provider
        ) { tools, _, _, continuation in
            do {
                let date = try requireTool(CurrentDateTimeTool.self, in: tools)
                for _ in 0..<13 {
                    _ = try await date.call(arguments: .init(includeSeconds: true))
                }
                continuation.yield("unreachable")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let error = await capturedServiceError {
            _ = try await harness.collect(request: .init(turnID: 8, userText: "今何時？"))
        }
        let committedFacts = await harness.store.committedFacts()
        let restoreCount = await harness.client.restoreCount
        let didEmitCommitted = await harness.didEmitCommitted

        XCTAssertEqual(error, .toolRuntimeFailed)
        XCTAssertEqual(provider.callCount, 12)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(didEmitCommitted)
    }

    func testPersistenceFailureRestoresCheckpointAndDoesNotEmitCommitted() async throws {
        let harness = try ToolEnabledReplyServiceHarness(shouldFailSave: true) { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield("覚えたよ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let error = await capturedServiceError {
            _ = try await harness.collect(request: .init(turnID: 9, userText: "青が好き"))
        }
        let committedFacts = await harness.store.committedFacts()
        let restoreCount = await harness.client.restoreCount
        let didEmitCommitted = await harness.didEmitCommitted

        XCTAssertEqual(error, .toolRuntimeFailed)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertTrue(harness.persistence.savedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(didEmitCommitted)
        XCTAssertEqual(harness.timeline.values, [.draft])
    }

    func testStoreInitializationFailureDoesNotCreateSessionOrEmitEvents() async throws {
        let provider = RecordingDateTimeProvider()
        let client = ReplySessionClientSpy { _, _, _, continuation in
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(clients: [client])
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { throw ReplyServiceTestFailure.storeInitialization },
            dateTimeProvider: provider
        )

        let error = await capturedServiceError {
            _ = try await service.streamReply(to: .init(turnID: 10, userText: "こんにちは"))
        }
        let prepareCount = await factory.prepareCount
        let makeCount = await factory.makeCount
        let prewarmCount = await client.prewarmCount
        let promptCount = await client.prompts.count

        XCTAssertEqual(error, .toolRuntimeFailed)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(makeCount, 0)
        XCTAssertEqual(prewarmCount, 0)
        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testSessionPreparationFailureDoesNotBeginMemoryTurnOrEmitEvents() async throws {
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let storeCreationCount = LockedCounter()
        let provider = RecordingDateTimeProvider()
        let client = ReplySessionClientSpy { _, _, _, continuation in
            continuation.finish()
        }
        let factory = ReplySessionFactorySpy(
            clients: [client],
            prepareError: ConversationServiceError.modelUnavailable(.modelNotReady)
        )
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: {
                storeCreationCount.increment()
                return try LocalMemoryStore(persistence: persistence)
            },
            dateTimeProvider: provider
        )

        let error = await capturedServiceError {
            _ = try await service.streamReply(to: .init(turnID: 11, userText: "こんにちは"))
        }
        let prepareCount = await factory.prepareCount
        let makeCount = await factory.makeCount
        let transcriptCount = await client.transcriptCount

        XCTAssertEqual(error, .modelUnavailable(.modelNotReady))
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(makeCount, 0)
        XCTAssertEqual(storeCreationCount.value, 0)
        XCTAssertEqual(transcriptCount, 0)
        XCTAssertTrue(timeline.values.isEmpty)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testResetCreatesFreshSessionAndRetainsPersistentToolRuntime() async throws {
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(timeline: timeline)
        let store = try LocalMemoryStore(persistence: persistence)
        let searchedFact = LockedValue<String?>(nil)
        let firstClient = ReplySessionClientSpy { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield("覚えた")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let secondClient = ReplySessionClientSpy { tools, _, _, continuation in
            do {
                let search = try requireTool(SearchMemoryTool.self, in: tools)
                let output = try await search.call(arguments: .init(query: "青", limit: 1))
                let results = try JSONDecoder().decode([MemorySearchResult].self, from: Data(output.utf8))
                searchedFact.set(results.first?.fact)
                continuation.yield("見つけた")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let factory = ReplySessionFactorySpy(clients: [firstClient, secondClient])
        let service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: RecordingDateTimeProvider()
        )

        _ = try await collect(
            service: service,
            request: .init(turnID: 12, userText: "青が好き")
        )
        await service.reset()
        let events = try await collect(
            service: service,
            request: .init(turnID: 13, userText: "好きな色は？")
        )
        let makeCount = await factory.makeCount
        let firstPrewarmCount = await firstClient.prewarmCount
        let secondPrewarmCount = await secondClient.prewarmCount

        XCTAssertEqual(makeCount, 2)
        XCTAssertEqual(firstPrewarmCount, 1)
        XCTAssertEqual(secondPrewarmCount, 1)
        XCTAssertEqual(searchedFact.value, "青が好き")
        XCTAssertEqual(events.last, .committed(.init(finalText: "見つけた", memoryChange: nil)))
        XCTAssertEqual(persistence.savedFacts.map(\.fact), ["青が好き"])
    }

    func testSameTurnIDDoesNotResetBudgetButNewTurnIDDoes() async throws {
        let provider = RecordingDateTimeProvider()
        let harness = try ToolEnabledReplyServiceHarness(dateTimeProvider: provider) { tools, prompt, _, continuation in
            do {
                let date = try requireTool(CurrentDateTimeTool.self, in: tools)
                let callCount = prompt == "first" ? 12 : 1
                for _ in 0..<callCount {
                    _ = try await date.call(arguments: .init(includeSeconds: false))
                }
                continuation.yield("ok")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        _ = try await harness.collect(request: .init(turnID: 14, userText: "first"))
        let sameTurnError = await capturedServiceError {
            _ = try await harness.collect(request: .init(turnID: 14, userText: "same"))
        }
        let newTurnEvents = try await harness.collect(request: .init(turnID: 15, userText: "new"))
        let restoreCount = await harness.client.restoreCount

        XCTAssertEqual(sameTurnError, .toolRuntimeFailed)
        XCTAssertEqual(newTurnEvents.last, .committed(.init(finalText: "ok", memoryChange: nil)))
        XCTAssertEqual(provider.callCount, 13)
        XCTAssertEqual(restoreCount, 1)
    }

    func testConcurrentStreamReplyIsRejectedUntilCleanupCompletes() async throws {
        let draftReceived = ReplySessionSignal()
        let harness = try ToolEnabledReplyServiceHarness(blocksRestore: true) { _, prompt, _, continuation in
            if prompt == "first" {
                do {
                    continuation.yield("draft")
                    try await Task.sleep(for: .seconds(60))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            } else {
                continuation.yield("next")
                continuation.finish()
            }
        }
        let consumer = Task {
            let stream = try await harness.service.streamReply(
                to: .init(turnID: 16, userText: "first")
            )
            for try await event in stream {
                if case .draft = event {
                    await draftReceived.signal()
                }
            }
        }
        await draftReceived.wait()

        let busyBeforeCancellation = await capturedServiceError {
            _ = try await harness.service.streamReply(to: .init(turnID: 17, userText: "second"))
        }
        consumer.cancel()
        let cleanup = Task { await harness.service.cancelActiveReply() }
        await harness.waitUntilRestoreStarted()
        let busyDuringRestore = await capturedServiceError {
            _ = try await harness.service.streamReply(to: .init(turnID: 17, userText: "second"))
        }
        await harness.releaseRestore()
        await cleanup.value
        _ = await consumer.result
        let events = try await harness.collect(request: .init(turnID: 17, userText: "second"))

        XCTAssertEqual(busyBeforeCancellation, .modelBusy)
        XCTAssertEqual(busyDuringRestore, .modelBusy)
        XCTAssertEqual(events.last, .committed(.init(finalText: "next", memoryChange: nil)))
    }

    func testEmptyFinalSnapshotRollsBackAndDoesNotCommit() async throws {
        let harness = try ToolEnabledReplyServiceHarness { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield(" \n ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        let error = await capturedServiceError {
            _ = try await harness.collect(request: .init(turnID: 18, userText: "青が好き"))
        }
        let committedFacts = await harness.store.committedFacts()
        let restoreCount = await harness.client.restoreCount
        let didEmitCommitted = await harness.didEmitCommitted

        XCTAssertEqual(error, .modelGenerationFailed)
        XCTAssertTrue(committedFacts.isEmpty)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(didEmitCommitted)
    }

    func testNewServiceInstanceLoadsCommittedFactsFromSharedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("memories.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstClient = ReplySessionClientSpy { tools, _, _, continuation in
            do {
                let remember = try requireTool(RememberMemoryTool.self, in: tools)
                _ = try await remember.call(arguments: .init(fact: "青が好き", supportingQuote: "青が好き"))
                continuation.yield("覚えた")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let firstFactory = ReplySessionFactorySpy(clients: [firstClient])
        var firstService: ToolEnabledReplyService? = ToolEnabledReplyService(
            sessionFactory: firstFactory,
            makeMemoryStore: { try LocalMemoryStore(fileURL: fileURL) },
            dateTimeProvider: RecordingDateTimeProvider()
        )
        _ = try await collect(
            service: try XCTUnwrap(firstService),
            request: .init(turnID: 19, userText: "青が好き")
        )
        firstService = nil

        let searchedFact = LockedValue<String?>(nil)
        let secondClient = ReplySessionClientSpy { tools, _, _, continuation in
            do {
                let search = try requireTool(SearchMemoryTool.self, in: tools)
                let output = try await search.call(arguments: .init(query: "青", limit: 1))
                let results = try JSONDecoder().decode([MemorySearchResult].self, from: Data(output.utf8))
                searchedFact.set(results.first?.fact)
                continuation.yield("青だよ")
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let secondFactory = ReplySessionFactorySpy(clients: [secondClient])
        let secondService = ToolEnabledReplyService(
            sessionFactory: secondFactory,
            makeMemoryStore: { try LocalMemoryStore(fileURL: fileURL) },
            dateTimeProvider: RecordingDateTimeProvider()
        )

        let events = try await collect(
            service: secondService,
            request: .init(turnID: 20, userText: "好きな色は？")
        )
        let firstMakeCount = await firstFactory.makeCount
        let secondMakeCount = await secondFactory.makeCount

        XCTAssertEqual(searchedFact.value, "青が好き")
        XCTAssertEqual(events.last, .committed(.init(finalText: "青だよ", memoryChange: nil)))
        XCTAssertEqual(firstMakeCount, 1)
        XCTAssertEqual(secondMakeCount, 1)
    }
}

private enum ReplyServiceTestFailure: Error {
    case generation
    case decoding
    case storeInitialization
    case missingTool
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value { lock.withLock { storage } }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}

private func requireTool<T>(_ type: T.Type, in tools: [any Tool]) throws -> T {
    guard let tool = tools.first(where: { $0 is T }) as? T else {
        throw ReplyServiceTestFailure.missingTool
    }
    return tool
}

private func capturedServiceError(
    _ operation: () async throws -> Void
) async -> ConversationServiceError? {
    do {
        try await operation()
        XCTFail("Expected a service error")
        return nil
    } catch let error as ConversationServiceError {
        return error
    } catch {
        XCTFail("Expected ConversationServiceError")
        return nil
    }
}

private func collect(
    service: ToolEnabledReplyService,
    request: ReplyTurnRequest
) async throws -> [ReplyStreamEvent] {
    let stream = try await service.streamReply(to: request)
    var events: [ReplyStreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func makeFact(id: String, text: String) -> MemoryFact {
    MemoryFact(
        id: UUID(uuidString: id)!,
        fact: text,
        supportingQuote: text,
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 10),
        sourceTurnID: 1
    )
}
