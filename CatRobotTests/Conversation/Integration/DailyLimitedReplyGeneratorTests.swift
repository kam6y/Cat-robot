import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class DailyLimitedReplyGeneratorTests: XCTestCase {
    func testLimitReachedThrowsBeforeCallingBaseAndSkipsPrewarm() async {
        let base = LimitProbeReply(), usage = ConversationUsageSpy()
        await usage.setLimitReached(true)
        let sut = DailyLimitedReplyGenerator(base: base, usage: usage, configuration: { .init() })

        await sut.prewarm()
        do {
            _ = try await sut.streamReply(to: "こんにちは")
            XCTFail("The daily limit must refuse before invoking the reply service")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .dailyLimitReached)
        }

        let prewarms = await base.prewarms, prompts = await base.prompts
        let charged = await usage.turns.count
        XCTAssertEqual(prewarms, 0)
        XCTAssertEqual(prompts, [])
        XCTAssertEqual(charged, 0)
    }

    func testBelowLimitForwardsPrewarmStreamAndReset() async throws {
        let base = LimitProbeReply(), usage = ConversationUsageSpy()
        let sut = DailyLimitedReplyGenerator(base: base, usage: usage, configuration: { .init() })

        await sut.prewarm()
        var snapshots: [String] = []
        for try await text in try await sut.streamReply(to: "こんにちは") { snapshots.append(text) }
        await sut.reset()

        let prewarms = await base.prewarms, prompts = await base.prompts, resets = await base.resets
        XCTAssertEqual(snapshots, ["にゃ", "にゃん。"])
        XCTAssertEqual(prewarms, 1)
        XCTAssertEqual(prompts, ["こんにちは"])
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(sut.supportsStableReplyPrefix)
    }

    func testLimitIsEvaluatedPerCallWithCurrentConfiguration() async throws {
        let base = LimitProbeReply(), usage = ConversationUsageSpy(), settings = LimitConfigurationBox()
        let sut = DailyLimitedReplyGenerator(base: base, usage: usage, configuration: { await settings.configuration })
        await usage.setLimitReached(true)
        do {
            _ = try await sut.streamReply(to: "一回目")
            XCTFail("The first request is above the current limit")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .dailyLimitReached) }

        await usage.setLimitReached(false)
        await settings.set(dailyTurnLimit: 500)
        var result = ""
        for try await text in try await sut.streamReply(to: "二回目") { result = text }

        let limits = await usage.limits, prompts = await base.prompts
        XCTAssertEqual(limits, [300, 500])
        XCTAssertEqual(prompts, ["二回目"])
        XCTAssertEqual(result, "にゃん。")
    }

    func testViewModelAtDailyLimitCreatesNoSessionAndKeepsAvailabilityAndClassification() async {
        let factory = StubSessionFactory(), usage = ConversationUsageSpy()
        await usage.setLimitReached(true)
        let primary = makeClaudeService(factory, usage: usage)
        let reply = DailyLimitedReplyGenerator(base: primary, usage: usage, configuration: { .init() })
        let harness = ConversationHarness(replyOverride: reply, memory: primary, classification: .addressed)

        await harness.sut.startConversation()
        await harness.completeUnengagedTurn("ねこ、おはよう", at: 0)

        let sessions = await factory.sessions.count, charged = await usage.turns.count
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.dailyLimitReached))
        XCTAssertEqual(sessions, 0, "Neither prewarm nor the rejected turn may create a session")
        XCTAssertEqual(charged, 0)
        XCTAssertEqual(harness.calls.values.filter { $0 == .checkAvailability }.count, 1)
        XCTAssertEqual(harness.calls.values.filter { $0 == .classify("ねこ、おはよう") }.count, 1)
        await harness.sut.shutdown()
    }
}

private actor LimitProbeReply: ReplyGenerating {
    nonisolated let supportsStableReplyPrefix = true
    private(set) var prewarms = 0
    private(set) var prompts: [String] = []
    private(set) var resets = 0
    func prewarm() { prewarms += 1 }
    func reset() { resets += 1 }
    func streamReply(to utterance: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(utterance)
        return AsyncThrowingStream { continuation in
            continuation.yield("にゃ"); continuation.yield("にゃん。"); continuation.finish()
        }
    }
}

private actor LimitConfigurationBox {
    private(set) var configuration = ConversationModelConfiguration()
    func set(dailyTurnLimit: Int) { configuration.dailyTurnLimit = dailyTurnLimit }
}
