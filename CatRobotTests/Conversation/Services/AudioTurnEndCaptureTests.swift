import AVFAudio
import XCTest
@testable import CatRobot

@MainActor
final class AudioTurnEndCaptureTests: XCTestCase {
    func testANewPauseIsInferredAfterAnOlderBlockedDecisionFinishes() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let began = await eventually { h.scorer.started }
        XCTAssertTrue(began)
        await h.feed(1, frames: 1); await h.feed(0, frames: 7)
        h.scorer.release()
        let closed = await eventually { h.signals.count == 1 }
        XCTAssertTrue(closed, "The new pause must not be lost while an obsolete inference finishes")
        XCTAssertEqual(h.observations.map(\.accepted), [false, true])
        XCTAssertEqual(h.failures, 0)
        h.capture.cancel()
    }

    func testSilenceNeverClosesWhileTheModelHasNotDecided() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 100)
        XCTAssertTrue(h.scorer.started)
        XCTAssertTrue(h.signals.isEmpty, "Elapsed silence must not substitute for a model decision")
        h.capture.cancel(); h.scorer.release()
    }

    func testInferenceFailureIsReportedExactlyOnceAndStopsTheAudioPipeline() async throws {
        let h = try AudioCaptureHarness(failModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let failed = await eventually { h.failures == 1 }
        XCTAssertTrue(failed)
        await h.feed(1, frames: 1)
        XCTAssertEqual(h.failures, 1)
        XCTAssertTrue(h.signals.isEmpty)
        h.capture.cancel()
    }

    func testVADFailureStopsProcessingAndReportsOneError() async throws {
        let h = try AudioCaptureHarness(failVAD: true)
        h.submit(1)
        let failed = await eventually { h.failures == 1 }
        XCTAssertTrue(failed)
        h.submit(1)
        XCTAssertEqual(h.failures, 1)
        XCTAssertTrue(h.signals.isEmpty)
        h.capture.cancel()
    }

    func testInvalidAudioReportsFailureWhileCancellationIsQuiet() async throws {
        let h = try AudioCaptureHarness()
        h.submit(1, timestamp: .nan)
        XCTAssertEqual(h.failures, 1)
        h.submit(1, timestamp: .nan)
        XCTAssertEqual(h.failures, 1)
        h.capture.cancel()
        let cancelled = try AudioCaptureHarness()
        cancelled.capture.cancel()
        cancelled.submit(1, timestamp: .nan)
        XCTAssertEqual(cancelled.failures, 0)
    }

    func testAudioOnlyConfigurationReachesThePipelineModelAndSignal() async throws {
        let h = try AudioCaptureHarness(configuration: .init(completeProbability: 0.85))
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered)
        h.capture.cancel()
    }

    func testValidQuietWindowDeliversAnEndpointWithoutWaitingForASRFinal() async throws {
        let h = try AudioCaptureHarness()
        await h.feed(1, frames: 16)
        await h.feed(0, frames: 7)
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(h.scorer.inputCount, 128000)
        XCTAssertTrue(h.signals.first?.isValid(at: h.clock.value) ?? false)
        h.capture.cancel()
        XCTAssertFalse(h.signals.first?.isValid(at: h.clock.value) ?? true)
    }

    func testVoiceResumptionIsScoredWhileCompletionModelIsBlocked() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        await h.feed(1, frames: 1)
        XCTAssertEqual(h.vad.count, 24, "VAD must keep consuming while Smart Turn runs")
        h.scorer.release()
        let finished = await eventually { h.observations.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(h.signals.count, 0)
        XCTAssertEqual(h.observations.first?.accepted, false)
        h.capture.cancel()
    }

    func testCancelDoesNotJoinBlockedInferenceOrDeliverItsLateAnswer() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        h.capture.cancel()
        h.scorer.release()
        let finished = await eventually { h.scorer.finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(h.signals.count, 0)
    }

    func testDeadlineIncludesQueuedWorkAndInference() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        h.clock.set(h.clock.value + 0.301)
        h.scorer.release()
        let finished = await eventually { h.observations.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(h.signals.count, 0)
        h.capture.cancel()
    }

    func testQueueOverflowInvalidatesCaptureInsteadOfTreatingLostSpeechAsSilence() async throws {
        let h = try AudioCaptureHarness()
        await h.feed(1, frames: 16)
        h.vad.block()
        h.submit(0)
        let started = await eventually { h.vad.entered }
        XCTAssertTrue(started)
        for _ in 0..<20 { h.submit(0) }
        h.vad.release()
        let scored = await eventually { h.vad.count >= 17 }
        XCTAssertTrue(scored)
        // If overflow were ignored, the in-flight + eight queued quiet frames
        // would reach 25, and this extra quiet frame would falsely close.
        _ = await eventually { h.vad.count >= 25 }
        h.submit(0)
        let inferred = await eventually { h.scorer.started }
        XCTAssertFalse(inferred)
        XCTAssertEqual(h.failures, 1, "Queue overflow must emit one error")
        XCTAssertEqual(h.signals.count, 0)
        h.capture.cancel()
    }

    func testModelFailureDoesNotEmitACompleteDecision() async throws {
        let h = try AudioCaptureHarness(failModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let finished = await eventually { h.observations.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(h.signals.count, 0)
        XCTAssertNil(h.observations.first?.probability)
        h.capture.cancel()
    }

    func testUnscoredSubframeAfterRequestCannotDeliverEndpoint() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        // Half a VAD frame of resumed voice is admitted before the old result returns.
        h.submit(1, sampleCount: 256)
        h.scorer.release()
        let completed = await eventually { h.observations.count == 1 }
        XCTAssertTrue(completed)
        let deliveredOldResult = await eventually { !h.signals.isEmpty }
        XCTAssertFalse(deliveredOldResult, "Unscored speech cannot be treated as a drained silence queue")
        h.capture.cancel()
    }

    func testInvalidTimestampPermanentlyInvalidatesAlreadyDeliveredSignal() async throws {
        let h = try AudioCaptureHarness()
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered)
        h.submit(0, timestamp: .nan)
        // A rejected chunk may never reach VAD; admission must invalidate synchronously.
        XCTAssertFalse(h.signals.first?.isValid(at: h.clock.value) ?? true)
        let becameValidAgain = await eventually { h.signals.first?.isValid(at: h.clock.value) == true }
        XCTAssertFalse(becameValidAgain, "Invalid input must disable this optional capture permanently")
        h.capture.cancel()
    }

    func testResidualSilenceIsScoredBeforeAnAcceptedResultIsDelivered() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        _ = await eventually { h.scorer.started }
        h.submit(0, sampleCount: 256)
        h.scorer.release()
        _ = await eventually { h.observations.count == 1 }
        let premature = await eventually { !h.signals.isEmpty }
        XCTAssertFalse(premature)
        h.submit(0, sampleCount: 256)
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered, "Confirmed residual silence should not disable early endpointing")
        h.capture.cancel()
    }

    func testBackwardTimestampDisablesTheCapture() async throws {
        let h = try AudioCaptureHarness()
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        _ = await eventually { h.signals.count == 1 }
        h.submit(0, timestamp: 0.1)
        let becameValidAgain = await eventually { h.signals.first?.isValid(at: h.clock.value) == true }
        XCTAssertFalse(becameValidAgain)
        h.capture.cancel()
    }

    func test48kStereoConversionStillDeliversAfterResidualSilenceIsChecked() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let h = try AudioCaptureHarness(format: format)
        h.submit(1, sampleCount: 48000)
        let voiced = await eventually { h.vad.count >= 16 }
        XCTAssertTrue(voiced, "The resampler must supply enough full frames for the speech guard; got \(h.vad.count)")
        h.submit(0, sampleCount: 24000)
        let inferred = await eventually { h.observations.count == 1 }
        XCTAssertTrue(inferred)
        h.submit(0, sampleCount: 3072)
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(h.scorer.inputCount, 128000)
        h.capture.cancel()
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

@MainActor
private final class AudioCaptureHarness {
    let clock = ConversationTestNow()
    let vad: TestFrameVAD
    let scorer: TestCompletionScorer
    let capture: AudioTurnEndCapture
    let storage = EndpointStorage()
    let format: AVAudioFormat
    var submitted = 0
    var signals: [AudioTurnEndSignal] { storage.signals }
    var observations: [AudioTurnEndObservation] { storage.observations }
    var failures: Int { storage.failures }

    init(blockModel: Bool = false, blockVAD: Bool = false, failModel: Bool = false, failVAD: Bool = false,
         configuration: AudioTurnEndConfiguration = .init(),
         format: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!) throws {
        self.format = format
        vad = TestFrameVAD(block: blockVAD, fail: failVAD)
        scorer = TestCompletionScorer(block: blockModel, fail: failModel)
        let storage = self.storage, clock = self.clock
        capture = try AudioTurnEndCapture(sourceFormat: format, vad: vad, scorer: scorer, configuration: configuration,
            now: { clock.value }, onEndpoint: { storage.add($0) }, onFailure: { _ in storage.fail() }, onObservation: { storage.add($0) })
    }

    func submit(_ value: Float, sampleCount: Int = 512, timestamp: TimeInterval? = nil) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))!
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        for channel in 0..<Int(format.channelCount) {
            buffer.floatChannelData![channel].update(repeating: value, count: sampleCount)
        }
        submitted += 1
        clock.set(clock.value + Double(sampleCount) / format.sampleRate)
        capture.consume(buffer, at: timestamp ?? clock.value)
    }

    func feed(_ value: Float, frames: Int) async {
        for _ in 0..<frames {
            submit(value)
            for _ in 0..<100 {
                if vad.count >= submitted { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

private final class EndpointStorage: @unchecked Sendable {
    let lock = NSLock()
    private var values: [AudioTurnEndSignal] = []
    private var records: [AudioTurnEndObservation] = []
    private var failureCount = 0
    var failures: Int { lock.withLock { failureCount } }
    func fail() { lock.withLock { failureCount += 1 } }
    var signals: [AudioTurnEndSignal] { lock.withLock { values } }
    var observations: [AudioTurnEndObservation] { lock.withLock { records } }
    func add(_ value: AudioTurnEndSignal) { lock.withLock { values.append(value) } }
    func add(_ value: AudioTurnEndObservation) { lock.withLock { records.append(value) } }
}

private final class TestFrameVAD: VoiceActivityScoring, @unchecked Sendable {
    let condition = NSCondition()
    private var blocked: Bool
    private let fail: Bool
    private var total = 0
    private var didEnter = false
    init(block: Bool, fail: Bool = false) { blocked = block; self.fail = fail }
    var count: Int { condition.withLock { total } }
    var entered: Bool { condition.withLock { didEnter } }
    func block() { condition.withLock { blocked = true; didEnter = false } }
    func release() { condition.withLock { blocked = false; condition.broadcast() } }
    func speechProbability(samples: [Float]) throws -> Float {
        condition.lock(); defer { condition.unlock() }
        didEnter = true
        while blocked { condition.wait() }
        total += 1
        if fail { throw AudioTurnModelError.unavailable }
        return samples.contains(where: { $0 > 0.5 }) ? 0.9 : 0.1
    }
}

private final class TestCompletionScorer: AudioTurnScoring, @unchecked Sendable {
    let condition = NSCondition()
    private var blocked: Bool
    private let fail: Bool
    private var didStart = false
    private var didFinish = false
    private var receivedCount = 0
    init(block: Bool, fail: Bool) { blocked = block; self.fail = fail }
    var started: Bool { condition.withLock { didStart } }
    var finished: Bool { condition.withLock { didFinish } }
    var inputCount: Int { condition.withLock { receivedCount } }
    func release() { condition.withLock { blocked = false; condition.broadcast() } }
    func completionProbability(samples: [Float]) throws -> Float {
        condition.lock(); defer { condition.unlock() }
        didStart = true; receivedCount = samples.count
        while blocked { condition.wait() }
        didFinish = true
        if fail { throw AudioTurnModelError.unavailable }
        return 0.9
    }
}
