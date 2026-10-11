import ClaudeForFoundationModels
import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class OnDeviceFallbackReplyGeneratorTests: XCTestCase {
    actor SecondaryReply: ReplyGenerating {
        nonisolated let supportsStableReplyPrefix: Bool
        private(set) var prompts: [String] = []
        private(set) var resets = 0
        private(set) var prewarms = 0
        let snapshots: [String]
        private let onStart: (@Sendable () -> Void)?
        init(snapshots: [String] = ["短い", "短い返事。"], stablePrefix: Bool = true, onStart: (@Sendable () -> Void)? = nil) {
            self.snapshots = snapshots
            self.supportsStableReplyPrefix = stablePrefix
            self.onStart = onStart
        }
        func prewarm() async { prewarms += 1 }
        func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
            prompts.append(utterance)
            onStart?()
            let values = snapshots
            return AsyncThrowingStream { c in values.forEach { c.yield($0) }; c.finish() }
        }
        func reset() async { resets += 1 }
    }
    actor Availability: ModelAvailabilityChecking {
        private var value: ModelAvailability
        private let gate: ConversationTestGate?
        init(value: ModelAvailability, gate: ConversationTestGate? = nil) {
            self.value = value
            self.gate = gate
        }
        func set(_ value: ModelAvailability) { self.value = value }
        func availability() async -> ModelAvailability { await gate?.wait(); return value }
    }
    struct HeldSecondary: ReplyGenerating {
        let supportsStableReplyPrefix = false
        let stream: AsyncThrowingStream<String, Error>
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        init(cancelled: XCTestExpectation) {
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
            continuation.onTermination = { termination in
                if case .cancelled = termination { cancelled.fulfill() }
            }
        }
        func prewarm() async {}
        func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> { stream }
        func reset() async {}
    }
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await snapshot in stream { out.append(snapshot) }
        try Task.checkCancellation()
        return out
    }
    private func claude(_ factory: StubSessionFactory, store: any ConversationMemoryStore = InMemoryConversationMemoryStore(),
                        usage: ClaudeConversationServiceTests.UsageSpy = .init()) -> ClaudeConversationService {
        ClaudeConversationService(factory: factory, memoryStore: store,
                                  longTermMemory: LongTermMemoryManager(store: InMemoryLongTermMemoryStore()),
                                  tools: StaticToolProvider([]), configuration: { .init() }, usage: usage)
    }
    private func sut(_ primary: ClaudeConversationService, secondary: any ReplyGenerating = SecondaryReply(),
                     onDevice: ModelAvailability = .available, usage: ClaudeConversationServiceTests.UsageSpy = .init(),
                     limit: Int = 300) -> OnDeviceFallbackReplyGenerator {
        OnDeviceFallbackReplyGenerator(primary: primary, secondary: secondary, secondaryAvailability: Availability(value: onDevice),
                                       usage: usage, configuration: { .init(dailyTurnLimit: limit) })
    }

    func testHealthyClaudePassesThroughUntouched() async throws {
        let generator = sut(claude(StubSessionFactory()))
        let snapshots = try await collect(generator.streamReply(to: "こんにちは"))
        XCTAssertEqual(snapshots, ["にゃ", "にゃん。"])
    }

    func testUnreachableBeforeVisibleTextSwitchesToOnDeviceWithNoticeAndCarriesTheTurnOver() async throws {
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [" \n"], failure: URLError(.notConnectedToInternet)),
                                                   ScriptedSessionClient(chunks: ["戻った。"])])
        let store = InMemoryConversationMemoryStore()
        let secondary = SecondaryReply()
        let primary = claude(factory, store: store)
        let generator = sut(primary, secondary: secondary)
        let snapshots = try await collect(generator.streamReply(to: "電波が弱いとき"))
        XCTAssertEqual(snapshots, [" \n", OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い",
                                   OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い返事。"])
        let prompts = await secondary.prompts
        XCTAssertEqual(prompts, ["電波が弱いとき"])
        let saved = await store.load()
        XCTAssertEqual(saved?.turns, [.init(prompt: "電波が弱いとき", response: OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い返事。")])
        let back = try await collect(generator.streamReply(to: "戻った？"))
        XCTAssertEqual(back.last, "戻った。")
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2, "次のターンは Claude に戻り、端末内モデルの往復を含めて作り直す")
        XCTAssertTrue(sessions.last!.configuration.instructions.contains("利用者: 電波が弱いとき"))
    }

    func testFailureAfterFirstSnapshotIsNotSilentlyReplacedByOnDeviceReply() async throws {
        let held = ScriptedSessionClient(chunks: nil)
        let secondary = SecondaryReply()
        let generator = sut(claude(StubSessionFactory(scripts: [held])), secondary: secondary)
        let stream = try await generator.streamReply(to: "途中で切れる")
        let reader = Task { try await self.collect(stream) }
        defer { reader.cancel(); held.finish() }
        await held.waitUntilStarted()
        held.yield("一文目。")
        held.fail(URLError(.networkConnectionLost))
        do { _ = try await reader.value; XCTFail("expected modelUnreachable") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let prompts = await secondary.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testUnreachableWithoutOnDeviceModelPropagatesTheError() async throws {
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.notConnectedToInternet))])
        let secondary = SecondaryReply()
        let generator = sut(claude(factory), secondary: secondary, onDevice: .deviceNotEligible)
        do { _ = try await collect(generator.streamReply(to: "x")); XCTFail("expected modelUnreachable") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let prompts = await secondary.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testGenericGenerationFailureBeforeFirstSnapshotAlsoSwitchesToOnDevice() async throws {
        // HTTP 5xx はパッケージの公開 API では種別を見分けられず .modelGenerationFailed に写る（Task 2）。それでも切り替える。
        struct OpaqueAPIFailure: Error {}
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: OpaqueAPIFailure())])
        let secondary = SecondaryReply()
        let generator = sut(claude(factory), secondary: secondary)
        let snapshots = try await collect(generator.streamReply(to: "サーバが落ちているとき"))
        XCTAssertEqual(snapshots.last, OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い返事。")
        let prompts = await secondary.prompts
        XCTAssertEqual(prompts, ["サーバが落ちているとき"])
    }

    func testGenericGenerationFailureAfterFirstSnapshotIsNotReplaced() async throws {
        struct OpaqueAPIFailure: Error {}
        let held = ScriptedSessionClient(chunks: nil)
        let secondary = SecondaryReply()
        let generator = sut(claude(StubSessionFactory(scripts: [held])), secondary: secondary)
        let stream = try await generator.streamReply(to: "途中で壊れる")
        let reader = Task { try await self.collect(stream) }
        defer { reader.cancel(); held.finish() }
        await held.waitUntilStarted()
        held.yield("一文目。")
        held.fail(OpaqueAPIFailure())
        do { _ = try await reader.value; XCTFail("expected modelGenerationFailed") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        let prompts = await secondary.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testGenericGenerationFailureWithoutOnDeviceModelPropagatesTheError() async throws {
        struct OpaqueAPIFailure: Error {}
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: OpaqueAPIFailure())])
        let secondary = SecondaryReply()
        let generator = sut(claude(factory), secondary: secondary, onDevice: .deviceNotEligible)
        do { _ = try await collect(generator.streamReply(to: "x")); XCTFail("expected modelGenerationFailed") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        let prompts = await secondary.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testKnownAuthAndNonFallbackFailuresNeverSwitchToOnDevice() async throws {
        for (failure, expected) in [(ClaudeError.missingCredential, ModelAvailability.claudeCredentialMissing),
                                    (.attestationUnsupported, .claudeAttestationUnsupported),
                                    (.attestationFailed, .claudeAttestationFailed)] {
            let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: failure)])
            let secondary = SecondaryReply()
            let generator = sut(claude(factory), secondary: secondary)
            do { _ = try await collect(generator.streamReply(to: "x")); XCTFail("expected modelUnavailable") }
            catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(expected)) }
            let prompts = await secondary.prompts
            XCTAssertTrue(prompts.isEmpty, "\(failure)")
        }
        for failure: ConversationServiceError in [.refusal, .guardrailViolation, .contextExceeded, .inputTooLong, .cancelled] {
            let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: failure)])
            let secondary = SecondaryReply()
            let generator = sut(claude(factory), secondary: secondary)
            do { _ = try await collect(generator.streamReply(to: "切り替えない")); XCTFail("expected failure") }
            catch { XCTAssertEqual(error as? ConversationServiceError, failure) }
            let prompts = await secondary.prompts
            XCTAssertTrue(prompts.isEmpty, "\(failure)")
        }
    }

    func testDailyLimitRoutesToOnDeviceModelWithNotice() async throws {
        let usage = ClaudeConversationServiceTests.UsageSpy()
        await usage.setLimitReached(true)
        let factory = StubSessionFactory()
        let store = InMemoryConversationMemoryStore()
        let secondary = SecondaryReply()
        let generator = sut(claude(factory, store: store, usage: usage), secondary: secondary, usage: usage, limit: 3)
        let snapshots = try await collect(generator.streamReply(to: "上限後"))
        XCTAssertEqual(snapshots.last, OnDeviceFallbackReplyGenerator.dailyLimitNotice + "短い返事。")
        let sessions = await factory.sessions
        XCTAssertTrue(sessions.isEmpty, "Claude には送らない")
        let saved = await store.load()
        XCTAssertEqual(saved?.turns, [.init(prompt: "上限後", response: OnDeviceFallbackReplyGenerator.dailyLimitNotice + "短い返事。")])
        await usage.setLimitReached(false)
        _ = try await collect(generator.streamReply(to: "上限解除後"))
        let resumed = await factory.sessions
        XCTAssertTrue(resumed.last!.configuration.instructions.contains("利用者: 上限後"))
        XCTAssertTrue(resumed.last!.configuration.instructions.contains(OnDeviceFallbackReplyGenerator.dailyLimitNotice + "短い返事。"))
    }

    func testDailyLimitWithoutOnDeviceModelReportsUnavailable() async throws {
        let usage = ClaudeConversationServiceTests.UsageSpy()
        await usage.setLimitReached(true)
        let generator = sut(claude(StubSessionFactory(), usage: usage), onDevice: .deviceNotEligible, usage: usage, limit: 3)
        do { _ = try await collect(generator.streamReply(to: "上限後")); XCTFail("expected dailyLimitReached") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .dailyLimitReached) }
    }

    func testAvailabilityPrefersClaudeThenOnDeviceWhenOffline() async {
        let online = await sut(claude(StubSessionFactory())).availability()
        XCTAssertEqual(online, .available)
        let offlineWithDevice = await sut(claude(StubSessionFactory(authenticationError: URLError(.notConnectedToInternet)))).availability()
        XCTAssertEqual(offlineWithDevice, .available)
        let offlineNoDevice = await sut(claude(StubSessionFactory(authenticationError: URLError(.notConnectedToInternet))), onDevice: .deviceNotEligible).availability()
        XCTAssertEqual(offlineNoDevice, .claudeUnreachable)
        let misconfigured = await sut(claude(StubSessionFactory(authenticationError: ClaudeError.missingCredential))).availability()
        XCTAssertEqual(misconfigured, .claudeCredentialMissing, "設定ミスは端末内モデルで隠さない")
        let unsupported = await sut(claude(StubSessionFactory(authenticationError: ClaudeError.attestationUnsupported))).availability()
        XCTAssertEqual(unsupported, .claudeAttestationUnsupported)
        let attestationFailed = await sut(claude(StubSessionFactory(authenticationError: ClaudeError.attestationFailed))).availability()
        XCTAssertEqual(attestationFailed, .claudeAttestationFailed, "既知の認証エラーはそのまま案内し、端末内モデルで隠さない")
    }

    func testResetReachesBothGeneratorsAndPrewarmOnlyReachesPrimary() async throws {
        let script = ScriptedSessionClient(chunks: ["Claudeの返事。"])
        let factory = StubSessionFactory(scripts: [script])
        let secondary = SecondaryReply()
        let generator = sut(claude(factory), secondary: secondary)
        await generator.prewarm()
        _ = try await collect(generator.streamReply(to: "リセット前の質問"))
        await generator.reset()
        _ = try await collect(generator.streamReply(to: "リセット後の質問"))
        let resets = await secondary.resets
        XCTAssertEqual(resets, 1)
        let secondaryPrewarms = await secondary.prewarms
        XCTAssertEqual(secondaryPrewarms, 0)
        XCTAssertEqual(script.prewarms, 1)
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(sessions.last!.configuration.instructions.contains("リセット前の質問"))
    }

    func testThirdConsecutiveClaudeFailureAsksToWait() async throws {
        let failures: [any ConversationSessionClient] = [
            ScriptedSessionClient(chunks: [], failure: URLError(.notConnectedToInternet)),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.modelGenerationFailed),
            ScriptedSessionClient(chunks: [], failure: URLError(.timedOut)),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.modelGenerationFailed),
        ]
        let generator = sut(claude(StubSessionFactory(scripts: failures)))
        for (prompt, notice) in [
            ("1回目", OnDeviceFallbackReplyGenerator.claudeFailureNotice),
            ("2回目", OnDeviceFallbackReplyGenerator.claudeFailureNotice),
            ("3回目", OnDeviceFallbackReplyGenerator.consecutiveFailureNotice),
            ("4回目", OnDeviceFallbackReplyGenerator.consecutiveFailureNotice),
        ] {
            let snapshots = try await collect(generator.streamReply(to: prompt))
            XCTAssertEqual(snapshots.last, notice + "短い返事。", prompt)
        }
        // 端末内モデルが使えなかった失敗も同じ連続回数に含める。
        let availability = Availability(value: .deviceNotEligible)
        let withoutDevice = OnDeviceFallbackReplyGenerator(
            primary: claude(StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.timedOut))])),
            secondary: SecondaryReply(), secondaryAvailability: availability, usage: ClaudeConversationServiceTests.UsageSpy(),
            configuration: { .init() })
        for prompt in ["端末内なし1", "端末内なし2"] {
            do { _ = try await collect(withoutDevice.streamReply(to: prompt)); XCTFail("expected failure") }
            catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        }
        await availability.set(.available)
        let third = try await collect(withoutDevice.streamReply(to: "端末内あり3"))
        XCTAssertEqual(third.last, OnDeviceFallbackReplyGenerator.consecutiveFailureNotice + "短い返事。")
    }

    func testSuccessfulClaudeReplyResetsTheFailureCount() async throws {
        let factory = StubSessionFactory(scripts: [
            ScriptedSessionClient(chunks: [], failure: URLError(.notConnectedToInternet)),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.modelGenerationFailed),
            ScriptedSessionClient(chunks: ["Claudeの返事。"]),
            ScriptedSessionClient(chunks: [], failure: URLError(.timedOut)),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.modelGenerationFailed),
            ScriptedSessionClient(chunks: [], failure: URLError(.notConnectedToInternet)),
        ])
        let primary = claude(factory)
        let generator = sut(primary)
        for prompt in ["失敗1", "失敗2"] {
            let snapshots = try await collect(generator.streamReply(to: prompt))
            XCTAssertEqual(snapshots.last, OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い返事。")
        }
        let success = try await collect(generator.streamReply(to: "成功"))
        XCTAssertEqual(success, ["Claudeの返事。"])
        // 成功したセッションを作り直して次の障害を注入する。wrapper の reset で回数を変更しない。
        await primary.reset()
        for (prompt, notice) in [
            ("成功後の失敗1", OnDeviceFallbackReplyGenerator.claudeFailureNotice),
            ("成功後の失敗2", OnDeviceFallbackReplyGenerator.claudeFailureNotice),
            ("成功後の失敗3", OnDeviceFallbackReplyGenerator.consecutiveFailureNotice),
        ] {
            let snapshots = try await collect(generator.streamReply(to: prompt))
            XCTAssertEqual(snapshots.last, notice + "短い返事。", prompt)
        }
    }

    func testNonFallbackErrorsNeitherIncrementNorResetTheFailureCount() async throws {
        let factory = StubSessionFactory(scripts: [
            ScriptedSessionClient(chunks: [], failure: URLError(.timedOut)),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.refusal),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.cancelled),
            ScriptedSessionClient(chunks: [], failure: ConversationServiceError.modelGenerationFailed),
            ScriptedSessionClient(chunks: [], failure: URLError(.timedOut)),
        ])
        let generator = sut(claude(factory))
        let first = try await collect(generator.streamReply(to: "対象の失敗1"))
        XCTAssertEqual(first.last, OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い返事。")
        for failure: ConversationServiceError in [.refusal, .cancelled] {
            do { _ = try await collect(generator.streamReply(to: "対象外の失敗")); XCTFail("expected failure") }
            catch { XCTAssertEqual(error as? ConversationServiceError, failure) }
        }
        let second = try await collect(generator.streamReply(to: "対象の失敗2"))
        XCTAssertEqual(second.last, OnDeviceFallbackReplyGenerator.claudeFailureNotice + "短い返事。")
        let third = try await collect(generator.streamReply(to: "対象の失敗3"))
        XCTAssertEqual(third.last, OnDeviceFallbackReplyGenerator.consecutiveFailureNotice + "短い返事。")
    }

    func testConcurrentFailedTurnsKeepTheirOwnFailureNotice() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.timedOut))])
        let generator = OnDeviceFallbackReplyGenerator(
            primary: claude(factory), secondary: SecondaryReply(),
            secondaryAvailability: Availability(value: .available, gate: gate),
            usage: ClaudeConversationServiceTests.UsageSpy(), configuration: { .init() })
        var readers: [Task<[String], Error>] = []
        defer { readers.forEach { $0.cancel() } }
        for index in 1...3 {
            readers.append(Task { try await self.collect(generator.streamReply(to: "失敗\(index)")) })
            await gate.waitUntilEntered(index)
        }
        await gate.open()
        for (index, reader) in readers.enumerated() {
            let snapshots = try await reader.value
            let notice = index < 2 ? OnDeviceFallbackReplyGenerator.claudeFailureNotice
                : OnDeviceFallbackReplyGenerator.consecutiveFailureNotice
            XCTAssertEqual(snapshots.last, notice + "短い返事。")
        }
    }

    func testEmptyOnDeviceReplyFailsWithoutSavingTheNotice() async throws {
        let cases: [([String], Bool)] = [
            ([], true), ([""], true), ([" ", " \n"], true),
            ([], false), ([""], false), ([" ", " \n"], false),
        ]
        for (values, stablePrefix) in cases {
            let store = InMemoryConversationMemoryStore()
            let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.timedOut))])
            let generator = sut(claude(factory, store: store), secondary: SecondaryReply(snapshots: values, stablePrefix: stablePrefix))
            do { _ = try await collect(generator.streamReply(to: "空の返事")); XCTFail("expected failure") }
            catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
            let saved = await store.load()
            XCTAssertNil(saved, "通知文だけの往復は保存しない")
        }
    }

    func testUnstableOnDeviceReplyEmitsOnlyTheFinalRevision() async throws {
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.timedOut))])
        let secondary = SecondaryReply(snapshots: ["古い返事。", "新しい返事。"], stablePrefix: false)
        let generator = sut(claude(factory, store: store), secondary: secondary)
        XCTAssertTrue(generator.supportsStableReplyPrefix)
        let snapshots = try await collect(generator.streamReply(to: "書き換わる返事"))
        XCTAssertEqual(snapshots, [OnDeviceFallbackReplyGenerator.claudeFailureNotice,
                                  OnDeviceFallbackReplyGenerator.claudeFailureNotice + "新しい返事。"])
        let saved = await store.load()
        XCTAssertEqual(saved?.turns, [.init(prompt: "書き換わる返事", response: OnDeviceFallbackReplyGenerator.claudeFailureNotice + "新しい返事。")])
    }

    func testCancellingUnstableOnDeviceReplyEndsItsSourceWithoutSaving() async throws {
        let cancelled = expectation(description: "secondary iterator observes cancellation")
        let noticeSeen = expectation(description: "notice arrives before the final on-device text")
        let secondary = HeldSecondary(cancelled: cancelled)
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.timedOut))])
        let generator = sut(claude(factory, store: store), secondary: secondary)
        let stream = try await generator.streamReply(to: "端末内の生成中に取り消す")
        let reader = Task {
            for try await snapshot in stream {
                if snapshot == OnDeviceFallbackReplyGenerator.claudeFailureNotice { noticeSeen.fulfill() }
            }
            try Task.checkCancellation()
        }
        defer { reader.cancel(); secondary.continuation.finish() }
        secondary.continuation.yield("書き換わる途中の返事。")
        await fulfillment(of: [noticeSeen], timeout: 1)
        reader.cancel()
        do { try await reader.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? ConversationServiceError == .cancelled) }
        await fulfillment(of: [cancelled], timeout: 1)
        let saved = await store.load()
        XCTAssertNil(saved)
    }

    func testCancellationWhileCheckingAvailabilityNeverStartsOnDevice() async throws {
        for dailyLimit in [false, true] {
            let gate = ConversationTestGate()
            addTeardownBlock { await gate.open() }
            let forbiddenStart = expectation(description: "cancelled request must not start secondary: \(dailyLimit)")
            forbiddenStart.isInverted = true
            let secondary = SecondaryReply(onStart: { forbiddenStart.fulfill() })
            let usage = ClaudeConversationServiceTests.UsageSpy()
            await usage.setLimitReached(dailyLimit)
            let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [], failure: URLError(.timedOut))])
            let generator = OnDeviceFallbackReplyGenerator(
                primary: claude(factory, usage: usage), secondary: secondary,
                secondaryAvailability: Availability(value: .available, gate: gate), usage: usage, configuration: { .init() })
            let reader = Task { try await self.collect(generator.streamReply(to: "取消")) }
            defer { reader.cancel() }
            await gate.waitUntilEntered()
            reader.cancel()
            await gate.open()
            do { _ = try await reader.value; XCTFail("expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError || error as? ConversationServiceError == .cancelled) }
            // 取消済みの reader の終了は relay の終了を保証しないため、禁止した副作用を観測する。
            await fulfillment(of: [forbiddenStart], timeout: 0.25)
            let prompts = await secondary.prompts
            XCTAssertTrue(prompts.isEmpty)
        }
    }

    func testDailyLimitDoesNotBypassMemoryRestoreOrForgetFailure() async throws {
        let invalid = ConversationMemorySnapshot(schemaVersion: 99, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: "", turns: [])
        for forgetFailed in [false, true] {
            let store = MemoryStoreFake(snapshot: forgetFailed ? nil : invalid)
            let factory = StubSessionFactory()
            let primary = claude(factory, store: store)
            if forgetFailed {
                try await primary.prepareMemory()
                await store.setClearFailure(true)
                do { try await primary.forgetConversation(); XCTFail("expected delete failure") }
                catch { XCTAssertEqual(error as? ConversationMemoryError, .deleteFailed) }
            }
            let usage = ClaudeConversationServiceTests.UsageSpy()
            await usage.setLimitReached(true)
            let secondary = SecondaryReply()
            let generator = sut(primary, secondary: secondary, usage: usage)
            do { _ = try await collect(generator.streamReply(to: "上限時にも記憶の復旧を優先")); XCTFail("expected memory failure") }
            catch { XCTAssertEqual(error as? ConversationMemoryError, forgetFailed ? .unavailable : .unsupportedSchema) }
            let prompts = await secondary.prompts
            let sessions = await factory.sessions
            XCTAssertTrue(prompts.isEmpty)
            XCTAssertTrue(sessions.isEmpty)
        }
    }

    func testCancellingPrimaryReplyDoesNotStartOnDevice() async throws {
        let held = ScriptedSessionClient(chunks: nil)
        let forbiddenStart = expectation(description: "cancelled primary must not start secondary")
        forbiddenStart.isInverted = true
        let secondary = SecondaryReply(onStart: { forbiddenStart.fulfill() })
        let primary = claude(StubSessionFactory(scripts: [held]))
        let generator = sut(primary, secondary: secondary)
        let stream = try await generator.streamReply(to: "途中で取り消す")
        let reader = Task { try await self.collect(stream) }
        defer { reader.cancel(); held.finish() }
        await held.waitUntilStarted()
        reader.cancel()
        held.fail(URLError(.networkConnectionLost))
        do { _ = try await reader.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? ConversationServiceError == .cancelled) }
        await fulfillment(of: [forbiddenStart], timeout: 0.25)
        let prompts = await secondary.prompts
        XCTAssertTrue(prompts.isEmpty)
    }
}
