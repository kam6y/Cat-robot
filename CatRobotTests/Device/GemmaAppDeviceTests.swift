import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class GemmaAppDeviceTests: XCTestCase {
    /// Run each phase in a separate test-host process with the same synthetic UUID.
    /// The normal device scheme skips this probe unless the harness supplies a phase.
    func testPersistentMemoryAcrossProcessLaunches() async throws {
#if targetEnvironment(simulator) || !DEBUG
        throw XCTSkip("Persistent Gemma process probe requires a DEBUG iPhone build")
#else
        let environment = ProcessInfo.processInfo.environment
        guard environment["GEMMA_APP_DEVICE_TESTS"] == "1",
              let phase = environment["GEMMA_MEMORY_PHASE"],
              let rawID = environment["CATROBOT_MEMORY_TEST_ID"], UUID(uuidString: rawID) != nil else {
            throw XCTSkip("Run isolated persistence phases explicitly")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = try ConversationMemoryLocation.directory(applicationSupport: support, environment: environment)
        let expectedDirectory = support.appendingPathComponent("CatRobot/DeviceMemoryTests/\(UUID(uuidString: rawID)!.uuidString)", isDirectory: true)
        guard directory.standardizedFileURL == expectedDirectory.standardizedFileURL else {
            XCTFail("Refusing to modify a non-test memory directory")
            return
        }
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: GemmaMemoryCompatibility.current)
        executionTimeAllowance = 600
        var evidence: [String: Any] = ["phase": phase, "processID": ProcessInfo.processInfo.processIdentifier]
        if phase == "empty" {
            let restored = try await store.load()
            XCTAssertNil(restored, "Forget must survive a new process")
        } else {
            let dependencies = ConversationDependencies.live(memoryStore: store)
            let viewModel = ConversationViewModel(dependencies: dependencies)
            if phase == "seed" {
                try await store.clear()
                for prompt in ["私の好きな飲み物は麦茶です。短く返事して。", "訂正します。私の好きな飲み物はほうじ茶です。覚えてね。"] {
                    await viewModel.submitTypedText(prompt)
                    XCTAssertNil(viewModel.viewState.errorMessage)
                    XCTAssertEqual(viewModel.viewState.memoryState, .ready)
                }
                let loaded = try await store.load()
                let saved = try XCTUnwrap(loaded)
                XCTAssertEqual(saved.turns.count, 2)
                XCTAssertTrue(saved.turns.last?.prompt.contains("ほうじ茶") == true)
                let url = directory.appendingPathComponent("current.json")
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
                XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
                evidence["revision"] = saved.revision
            } else if phase == "recall" {
                let loaded = try await store.load()
                let saved = try XCTUnwrap(loaded)
                XCTAssertEqual(saved.turns.count, 2)
                let start = ProcessInfo.processInfo.systemUptime
                await viewModel.submitTypedText("私の好きな飲み物は何？")
                XCTAssertNil(viewModel.viewState.errorMessage)
                XCTAssertEqual(viewModel.viewState.memoryState, .ready)
                evidence["recallCorrect"] = viewModel.viewState.caption.contains("ほうじ茶")
                evidence["completionSeconds"] = ProcessInfo.processInfo.systemUptime - start
                evidence["answer"] = viewModel.viewState.caption // synthetic fixture only
                let reloaded = try await store.load()
                let updated = try XCTUnwrap(reloaded)
                XCTAssertEqual(updated.turns.count, 3)
            } else if phase == "forget" {
                try await dependencies.memory.prepareMemory()
                // Populate the view model through the normal typed path, then use its destructive action.
                await viewModel.submitTypedText("ひとことで挨拶して。")
                viewModel.requestForgetConversation()
                await viewModel.confirmForgetConversation()
                XCTAssertEqual(viewModel.viewState.phase, .paused)
                XCTAssertEqual(viewModel.viewState.caption, "")
                XCTAssertNotNil(viewModel.viewState.memoryNotice)
                let removed = try await store.load()
                XCTAssertNil(removed)
            } else { XCTFail("Unknown persistence phase") }
            await viewModel.shutdown()
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let output = support.appendingPathComponent("GemmaAppDeviceTest", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("persistence-\(phase).json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Persistent memory phase \(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    func testLiveGemmaClassificationTypedConversationSpeechAndResume() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Gemma app integration requires a physical iPhone.")
#else
        guard ProcessInfo.processInfo.environment["GEMMA_APP_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Run the GemmaAppDeviceTests scheme explicitly.")
        }
        executionTimeAllowance = 600
        let dependencies = ConversationDependencies.live(memoryStore: InMemoryConversationMemoryStore())
        XCTAssertTrue(dependencies.reply is GemmaConversationService)
        XCTAssertTrue(dependencies.classifier is GemmaConversationService)
        XCTAssertTrue(dependencies.modelAvailability is GemmaConversationService)
        let availability = await dependencies.modelAvailability.availability()
        XCTAssertEqual(availability, .available)
        guard availability == .available else { return }
        var records: [[String: Any]] = []
        for (input, expected) in [("猫ちゃん、あなたは何が好き？", AddressTarget.addressed),
                                  ("お母さん、明日のお弁当を作ってください。", .notAddressed),
                                  ("佐藤先生、この問題を教えてください。", .notAddressed),
                                  ("独り言だけど、今日は疲れたな。", .notAddressed),
                                  ("AIのあなたに教えてほしい。猫は何時間寝るの？", .addressed),
                                  ("明日は晴れるかな。", .ambiguous)] {
            let result = try await dependencies.classifier.classify(input)
            records.append(["kind": "classification", "input": input, "result": String(describing: result)])
            XCTAssertEqual(result, expected)
        }
        let viewModel = ConversationViewModel(dependencies: dependencies)
        for prompt in ["私の好きな飲み物は麦茶です。覚えてね。", "訂正です。私が好きなのはほうじ茶です。", "私の好きな飲み物は何？"] {
            let start = ProcessInfo.processInfo.systemUptime
            viewModel.showTypedInput()
            await viewModel.submitTypedText(prompt)
            let state = viewModel.viewState
            records.append(["kind": "typed-with-real-speech", "input": prompt, "caption": state.caption,
                            "phase": String(describing: state.phase),
                            "completionSeconds": ProcessInfo.processInfo.systemUptime - start])
            XCTAssertNil(state.errorMessage, state.errorMessage ?? "")
            XCTAssertFalse(state.caption.isEmpty)
            XCTAssertNotEqual(state.phase, .speaking, "submit must wait for actual speech completion")
        }
        XCTAssertTrue(viewModel.viewState.caption.contains("ほうじ茶"), viewModel.viewState.caption)
        viewModel.showTypedInput()
        await viewModel.submitTypedText(String(repeating: "入力が長すぎる場合の履歴確認。", count: 2000))
        XCTAssertEqual(viewModel.viewState.phase, .failed(.inputTooLong))
        await viewModel.submitTypedText("私の好きな飲み物は何？")
        XCTAssertNil(viewModel.viewState.errorMessage)
        XCTAssertTrue(viewModel.viewState.caption.contains("ほうじ茶"), viewModel.viewState.caption)
        records.append(["kind": "oversized-input-preserves-memory", "caption": viewModel.viewState.caption])
        await viewModel.sceneBecameInactive()
        XCTAssertEqual(viewModel.viewState.phase, .paused)
        viewModel.showTypedInput()
        await viewModel.submitTypedText("おかえり、と短く言って。")
        XCTAssertNil(viewModel.viewState.errorMessage)
        XCTAssertTrue(viewModel.viewState.caption.contains("おかえり"))
        records.append(["kind": "resume", "caption": viewModel.viewState.caption])
        let previousCaption = viewModel.viewState.caption
        viewModel.showTypedInput()
        let interrupted = Task {
            await viewModel.submitTypedText(String(repeating: "The garden has green leaves. ", count: 100)
                                           + "猫の長い冒険物語を書いて。")
        }
        // Wait for the real ViewModel to enter generation, then pause during prefill.
        while viewModel.viewState.phase != .thinking { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        await viewModel.sceneBecameInactive()
        await interrupted.value
        XCTAssertEqual(viewModel.viewState.phase, .paused)
        viewModel.showTypedInput()
        await viewModel.submitTypedText("ただいま、と短く言って。")
        XCTAssertNil(viewModel.viewState.errorMessage)
        XCTAssertTrue(viewModel.viewState.caption.contains("ただいま"))
        XCTAssertNotEqual(viewModel.viewState.caption, previousCaption)
        records.append(["kind": "pause-during-generation-and-immediate-resume", "caption": viewModel.viewState.caption])
        await viewModel.shutdown()

        // Cancel a real native stream, drain it via reset, and prove another turn works.
        let stream = try await dependencies.reply.streamReply(to: "猫の冒険物語を長く書いて。")
        let reader = Task {
            for try await _ in stream { throw CancellationError() }
        }
        // After the first snapshot, explicit reset owns cancellation/draining.
        _ = try? await reader.value
        await dependencies.reply.reset()
        var resumed = ""
        for try await snapshot in try await dependencies.reply.streamReply(to: "ひとことで挨拶して。") {
            resumed = snapshot
        }
        XCTAssertFalse(resumed.isEmpty)
        records.append(["kind": "reset-after-partial-stream", "caption": resumed])
        await dependencies.reply.reset()

        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let output = support.appendingPathComponent("GemmaAppDeviceTest", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["runtime": "LiteRT-LM 0.17.1", "records": records],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("results.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Gemma app integration on iPhone"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }
    func testProductionAutoCompactionAndInterleavedClassification() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Gemma compaction requires a physical iPhone.")
#else
        guard ProcessInfo.processInfo.environment["GEMMA_APP_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Run the GemmaAppDeviceTests scheme explicitly.")
        }
        executionTimeAllowance = 900
        let runtime = ObservedGemmaRuntime()
        let memoryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("GemmaMemory-\(UUID().uuidString)")
        let memoryStore = FileConversationMemoryStore(directory: memoryDirectory, compatibilityID: GemmaMemoryCompatibility.current)
        let service = GemmaConversationService(runtime: runtime, memoryStore: memoryStore)
        let availability = await service.availability()
        XCTAssertEqual(availability, .available)
        guard availability == .available else { return }
        var records: [[String: Any]] = []
        func send(_ prompt: String) async throws -> String {
            let start = ProcessInfo.processInfo.systemUptime
            var first: Double?
            var response = ""
            for try await text in try await service.streamReply(to: prompt) {
                if first == nil { first = ProcessInfo.processInfo.systemUptime - start }
                response = text
            }
            XCTAssertFalse(response.isEmpty)
            print("APP_COMPACTION_REPLY \(response.prefix(100))")
            records.append(["response": response, "firstVisibleSeconds": first ?? -1,
                            "completionSeconds": ProcessInfo.processInfo.systemUptime - start])
            return response
        }
        _ = try await send("私の旅行先は金沢、合言葉は青い栞、好きな飲み物はほうじ茶です。返事は『了解』だけ。")
        var lastCycles = 0
        for turn in 0..<50 {
            let notes = (0..<24).map { offset in
                let i = turn * 24 + offset
                return "日誌\(i)：\(i % 12 + 1)月\(i % 28 + 1)日、図書館で地図と写真を調べた。風が強く、活動時間は\(15 + i % 80)分だった。"
            }.joined(separator: "\n")
            _ = try await send("今日の記録です。返事は『了解』だけ。\n" + notes)
            let configs = await runtime.configurations
            let cycles = configs.filter { $0.kind == .summary }.count
            if cycles > lastCycles {
                let rebuilt = try XCTUnwrap(configs.last)
                XCTAssertEqual(rebuilt.kind, .reply)
                let retained = rebuilt.history.reduce(0) { $0 + $1.rawTokens }
                XCTAssertGreaterThanOrEqual(retained, 2048)
                XCTAssertLessThan(retained - (rebuilt.history.first?.rawTokens ?? 0), 2048)
                XCTAssertFalse(rebuilt.summary.isEmpty)
                let summaryTokens = try await runtime.countTokens(rebuilt.summary)
                XCTAssertLessThanOrEqual(summaryTokens, 512)
                records.append(["compaction": cycles, "retainedRawTokens": retained,
                                "summaryTokens": summaryTokens, "summary": rebuilt.summary])
                // Exercise the production session-switching path with saved memory.
                let target = try await service.classify("お母さん、明日のお弁当を作ってください。")
                XCTAssertEqual(target, .notAddressed)
                let reply = try await send("おかえり、とだけ言って。")
                XCTAssertFalse(["addressed", "notAddressed", "ambiguous"].contains(reply.trimmingCharacters(in: .whitespacesAndNewlines)),
                               "The reply session must not reuse classifier output")
                // Record semantic instruction-following separately from lifecycle
                // correctness; E2B sometimes answers 了解 despite the new request.
                records.append(["greetingInstructionFollowed": reply.contains("おかえり"), "greeting": reply])
                lastCycles = cycles
            }
            if cycles >= 2 { break }
        }
        XCTAssertGreaterThanOrEqual(lastCycles, 2)
        let budgets = runtime.trace.budgets
        XCTAssertFalse(budgets.isEmpty)
        XCTAssertTrue(budgets.allSatisfy { $0 < 12288 }, "Every native request must fit with output and safety reserve")
        let recall = try await send("私の旅行先と好きな飲み物は何？")
        records.append(["recall": recall])
        let loadedMemory = try await memoryStore.load()
        let savedMemory = try XCTUnwrap(loadedMemory)
        XCTAssertFalse(savedMemory.summary.isEmpty)
        // Classification closes the first service's native reply session. The new
        // service can then restore the saved text using the same engine safely.
        _ = try await service.classify("これは独り言です。")
        let restoredService = GemmaConversationService(runtime: runtime, memoryStore: memoryStore)
        try await restoredService.prepareMemory()
        var restoredReply = ""
        for try await text in try await restoredService.streamReply(to: "私の旅行先と好きな飲み物は何？") {
            restoredReply = text
        }
        let restoredConfigs = await runtime.configurations
        let restoredConfig = try XCTUnwrap(restoredConfigs.last)
        XCTAssertEqual(restoredConfig.summary, savedMemory.summary)
        XCTAssertEqual(restoredConfig.history.map(\.prompt), savedMemory.turns.map(\.prompt))
        records.append(["restoredRecall": restoredReply, "savedRevision": savedMemory.revision,
                        "restoredSummaryMatches": restoredConfig.summary == savedMemory.summary])
        await restoredService.reset()
        await service.reset()
        try? FileManager.default.removeItem(at: memoryDirectory)
        let data = try JSONSerialization.data(withJSONObject: ["records": records, "nativeBudgets": budgets],
                                              options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Production Gemma 12K auto-compaction"
        attachment.lifetime = .keepAlways
        add(attachment)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let output = support.appendingPathComponent("GemmaAppDeviceTest", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("compaction.json"), options: .atomic)
#endif
    }

}

private actor ObservedGemmaRuntime: GemmaRuntime {
    private let base = LiteRTGemmaRuntime()
    nonisolated let trace = GemmaDeviceBudgetTrace()
    private(set) var configurations: [GemmaSessionConfiguration] = []
    func prepare() async throws { try await base.prepare() }
    func countTokens(_ text: String) async throws -> Int {
        let count = try await base.countTokens(text)
        print("APP_TOKEN_COUNT kind=\(String(describing: configurations.last?.kind)) count=\(count) chars=\(text.count)")
        return count
    }
    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        let session = try await base.makeSession(configuration)
        configurations.append(configuration)
        print("APP_SESSION kind=\(configuration.kind) rawHistory=\(configuration.history.reduce(0) { $0 + $1.rawTokens }) summaryChars=\(configuration.summary.count)")
        return ObservedGemmaSession(base: session, trace: trace, kind: configuration.kind)
    }
}

private final class GemmaDeviceBudgetTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var budgets: [Int] { lock.withLock { values } }
    func append(_ value: Int) { lock.withLock { values.append(value) } }
}

private struct ObservedGemmaSession: GemmaSession {
    let base: any GemmaSession
    let trace: GemmaDeviceBudgetTrace
    let kind: GemmaSessionKind
    func tokenCount() throws -> Int { try base.tokenCount() }
    func inputTokenCount(_ prompt: String) throws -> Int { try base.inputTokenCount(prompt) }
    func cancel() { base.cancel() }
    func close() { base.close() }
    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        do {
            let budget = try base.tokenCount() + base.inputTokenCount(prompt) + outputLimit + 32
            trace.append(budget)
            print("APP_STREAM_START kind=\(kind) budget=\(budget) limit=\(outputLimit)")
            let source = base.stream(prompt, outputLimit: outputLimit)
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            Task {
                var response = ""
                do {
                    for try await delta in source {
                        response += delta
                        continuation.yield(delta)
                    }
                    print("APP_STREAM_END kind=\(kind) chars=\(response.count)")
                    continuation.finish()
                } catch {
                    print("APP_STREAM_ERROR kind=\(kind) error=\(error)")
                    continuation.finish(throwing: error)
                }
            }
            return stream
        } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
    }
}
