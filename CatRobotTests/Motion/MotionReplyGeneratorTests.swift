import XCTest
@testable import CatRobot

func collectMotionSnapshots(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    try Task.checkCancellation()
    return values
}

struct FailingMotionReply: ReplyGenerating {
    func prewarm() async {}
    func reset() async {}
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        throw ConversationServiceError.modelGenerationFailed
    }
}

@MainActor
final class MotionReplyGeneratorTests: XCTestCase {
    func testSuccessUsesScopeCapturedAtStreamCreation() async throws {
        let base = ControlledReply()
        let spy = MotionControllerSpy()
        let generator = MotionReplyGenerator(base: base, motion: spy)
        let old = MotionTurnID(), next = MotionTurnID()
        let stream = try await MotionTurnContext.$current.withValue(old) { try await generator.streamReply(to: "質問") }
        let reader = Task { try await MotionTurnContext.$current.withValue(next) { try await collectMotionSnapshots(stream) } }
        await base.yield("返事。")
        await base.finish()
        let values = try await reader.value
        XCTAssertEqual(values, ["返事。"])
        XCTAssertTrue(generator.supportsStableReplyPrefix)
        XCTAssertEqual(spy.generations.map(\.turn), [old])
        XCTAssertEqual(spy.generations.map(\.succeeded), [true])
        XCTAssertTrue(spy.begins.isEmpty)
    }

    func testSynchronousFailureReportsCapturedTurnButUnscopedFailureDoesNotGuess() async {
        let spy = MotionControllerSpy()
        let generator = MotionReplyGenerator(base: FailingMotionReply(), motion: spy)
        let turn = MotionTurnID()
        do { _ = try await MotionTurnContext.$current.withValue(turn) { try await generator.streamReply(to: "失敗") }; XCTFail() }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        do { _ = try await generator.streamReply(to: "スコープなし"); XCTFail() } catch { }
        XCTAssertEqual(spy.generations.map(\.turn), [turn])
        XCTAssertEqual(spy.generations.map(\.succeeded), [false])
    }

    func testConsumerCancellationCancelsRelayAndReportsOnlyItsOwnTurn() async throws {
        let base = ControlledReply()
        let spy = MotionControllerSpy()
        let finished = expectation(description: "Relay observes cancellation")
        spy.onGeneration = { finished.fulfill() }
        let generator = MotionReplyGenerator(base: base, motion: spy)
        let old = MotionTurnID()
        let stream = try await MotionTurnContext.$current.withValue(old) { try await generator.streamReply(to: "途中") }
        let reader = Task { try await collectMotionSnapshots(stream) }
        reader.cancel()
        _ = await reader.result
        await fulfillment(of: [finished], timeout: 1)
        await base.cancellation.wait()
        XCTAssertEqual(spy.generations.map(\.turn), [old])
        XCTAssertEqual(spy.generations.map(\.succeeded), [false])
    }

    func testUnscopedSuccessOnlyGeneratesAndResetDelegates() async throws {
        let base = ControlledReply(stablePrefix: false)
        let spy = MotionControllerSpy()
        let generator = MotionReplyGenerator(base: base, motion: spy)
        let stream = try await generator.streamReply(to: "普通の返答")
        let reader = Task { try await collectMotionSnapshots(stream) }
        await base.yield("返答")
        await base.finish()
        _ = try await reader.value
        await generator.reset()
        let resets = await base.resetCount
        XCTAssertEqual(resets, 1)
        XCTAssertFalse(generator.supportsStableReplyPrefix)
        XCTAssertTrue(spy.generations.isEmpty)
    }
}
