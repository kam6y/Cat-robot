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

    func testRetiringCaptureDuringLastSilentVADFrameDoesNotStartInference() async throws {
        for cancels in [true, false] {
            let h = try AudioCaptureHarness()
            defer { h.capture.cancel(); h.vad.release() }
            await h.feed(1, frames: 16)
            await h.feed(0, frames: 6)
            h.vad.block()
            h.submit(0)
            let entered = await eventually { h.vad.entered }
            XCTAssertTrue(entered)
            if cancels {
                h.capture.cancel()
            } else {
                for _ in 0..<20 { h.submit(0) }
                XCTAssertEqual(h.failures, 1)
            }
            h.vad.release()
            let finishedVAD = await eventually { h.vad.count == 23 }
            XCTAssertTrue(finishedVAD)
            let started = await eventually { h.scorer.started }
            XCTAssertFalse(started, "Retired VAD work must not acquire the shared completion scorer")
            XCTAssertTrue(h.signals.isEmpty)

            let next = try AudioCaptureHarness(scorerOverride: h.scorer)
            defer { next.capture.cancel() }
            await next.feed(1, frames: 16)
            await next.feed(0, frames: 7)
            let delivered = await eventually { next.signals.count == 1 }
            XCTAssertTrue(delivered)
            XCTAssertEqual(next.failures, 0)
            XCTAssertEqual(h.scorer.calls, 1, "Only the next active capture may start inference")
        }
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
        XCTAssertFalse(becameValidAgain, "Invalid input must disable this capture permanently")
        h.capture.cancel()
    }

    func testQuietResidualIsProbedBeforeAnAcceptedResultIsDelivered() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        defer { h.capture.cancel(); h.scorer.release(); h.vad.releaseProbe() }
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        h.vad.blockProbe()
        h.submit(0, sampleCount: 256)
        h.scorer.release()
        let probing = await eventually { h.vad.probeEntered }
        XCTAssertTrue(probing)
        XCTAssertTrue(h.signals.isEmpty, "The partial tail must be checked before publication")
        h.vad.releaseProbe()
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered, "Probed residual silence must preserve early endpointing")
        XCTAssertEqual(h.vad.count, 23, "Preview padding must not become a streaming VAD frame")
        XCTAssertEqual(h.vad.probes, 1)
    }

    func testNewResidualSpeechCannotRenewAnOlderDecision() async throws {
        for residualCount in [1, 127, 256, 511] {
            let h = try AudioCaptureHarness(blockModel: true)
            defer { h.capture.cancel(); h.scorer.release(); h.vad.releaseProbe() }
            await h.feed(1, frames: 16)
            await h.feed(0, frames: 7)
            let started = await eventually { h.scorer.started }
            XCTAssertTrue(started)
            h.vad.blockProbe()
            h.submit(0, sampleCount: residualCount)
            h.scorer.release()
            let probing = await eventually { h.vad.probeEntered }
            XCTAssertTrue(probing)
            // This finishes the old silent frontier but leaves newly admitted voice unscored.
            h.submit([Float](repeating: 0, count: 512 - residualCount)
                     + [Float](repeating: 1, count: residualCount))
            h.vad.releaseProbe()
            let scored = await eventually { h.vad.count == 24 }
            XCTAssertTrue(scored)
            let probedNewTail = await eventually { h.vad.probes == 2 }
            XCTAssertTrue(probedNewTail)
            let delivered = await eventually(attempts: 20) { !h.signals.isEmpty }
            XCTAssertFalse(delivered, "A fresh residual must not inherit the old decision's authorization")
            h.submit(0, sampleCount: 512 - residualCount)
            let resumed = await eventually { h.vad.count == 25 }
            XCTAssertTrue(resumed)
            XCTAssertTrue(h.signals.isEmpty)
            XCTAssertEqual(h.failures, 0)
        }
    }

    func testWaitingForResidualProbeDoesNotExtendDecisionDeadline() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        defer { h.capture.cancel(); h.scorer.release(); h.vad.releaseProbe() }
        await h.feed(1, frames: 16)
        await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        h.vad.blockProbe()
        h.submit(0, sampleCount: 256)
        h.scorer.release()
        let probing = await eventually { h.vad.probeEntered }
        XCTAssertTrue(probing)
        h.clock.set(h.clock.value + 0.301)
        h.vad.releaseProbe()
        let probed = await eventually { h.vad.probes == 1 }
        XCTAssertTrue(probed)
        let delivered = await eventually(attempts: 20) { !h.signals.isEmpty }
        XCTAssertFalse(delivered)
        XCTAssertEqual(h.failures, 0)
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

    func test48kStereoConversionCanDeliverWithAQuietPartialFrame() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let h = try AudioCaptureHarness(format: format)
        h.submit(1, sampleCount: 48000)
        let voiced = await eventually { h.vad.count >= 16 }
        XCTAssertTrue(voiced, "The resampler must supply enough full frames for the speech guard; got \(h.vad.count)")
        h.submit(0, sampleCount: 24000)
        let inferred = await eventually { h.observations.count == 1 }
        XCTAssertTrue(inferred)
        let delivered = await eventually { h.signals.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertTrue(h.signals.first?.isValid(at: h.clock.value) ?? false)
        XCTAssertEqual(h.scorer.inputCount, 128000)
        h.capture.cancel()
    }

    func test48kProductionTapChunksCanCloseDuringAnOrdinaryPause() async throws {
        for channels: AVAudioChannelCount in [1, 2] {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels)!
            let h = try AudioCaptureHarness(format: format)
            defer { h.capture.cancel() }
            for _ in 0..<48 {
                h.submit(1, sampleCount: 1024)
                try await Task.sleep(for: .milliseconds(3))
            }
            for _ in 0..<24 {
                h.submit(0, sampleCount: 1024)
                try await Task.sleep(for: .milliseconds(3))
                if !h.signals.isEmpty { break }
            }
            let inferred = await eventually { !h.observations.isEmpty }
            XCTAssertTrue(inferred)
            let delivered = await eventually(attempts: 20) { h.signals.count == 1 }
            XCTAssertTrue(delivered, "Normal 1024-frame taps must not disable Smart Turn early endpointing")
            XCTAssertTrue(h.signals.first?.isValid(at: h.clock.value) ?? false)
            XCTAssertEqual(h.failures, 0)
        }
    }

    func testCancellationDuringTailProbeDoesNotDeliverItsLateAnswer() async throws {
        let h = try AudioCaptureHarness(blockModel: true)
        defer { h.capture.cancel(); h.scorer.release(); h.vad.releaseProbe() }
        await h.feed(1, frames: 16); await h.feed(0, frames: 7)
        let started = await eventually { h.scorer.started }
        XCTAssertTrue(started)
        h.vad.blockProbe()
        h.submit(0, sampleCount: 256)
        h.scorer.release()
        let probing = await eventually { h.vad.probeEntered }
        XCTAssertTrue(probing)
        h.capture.cancel()
        h.vad.releaseProbe()
        let probed = await eventually { h.vad.probes == 1 }
        XCTAssertTrue(probed)
        let delivered = await eventually(attempts: 20) { !h.signals.isEmpty }
        XCTAssertFalse(delivered)
        XCTAssertEqual(h.failures, 0)
    }

    func testTailProbabilityAndErrorsControlEndpointPublication() async throws {
        let cases: [(result: Result<Float, AudioTurnModelError>, delivered: Bool, failures: Int)] = [
            (.success(0.49), true, 0), (.success(0.5), false, 0),
            (.failure(.unavailable), false, 1), (.success(.nan), false, 1), (.success(1.1), false, 1)
        ]
        for testCase in cases {
            let h = try AudioCaptureHarness(blockModel: true)
            defer { h.capture.cancel(); h.scorer.release() }
            await h.feed(1, frames: 16); await h.feed(0, frames: 7)
            let started = await eventually { h.scorer.started }
            XCTAssertTrue(started)
            h.vad.setProbeResult(testCase.result)
            h.submit(0, sampleCount: 256)
            h.scorer.release()
            let probed = await eventually { h.vad.probes == 1 }
            XCTAssertTrue(probed)
            if testCase.delivered {
                let delivered = await eventually { h.signals.count == 1 }
                XCTAssertTrue(delivered)
            } else {
                let delivered = await eventually(attempts: 20) { !h.signals.isEmpty }
                XCTAssertFalse(delivered)
            }
            XCTAssertEqual(h.failures, testCase.failures)
            XCTAssertEqual(h.vad.count, 23)
            if testCase.failures > 0 {
                h.submit(0)
                XCTAssertEqual(h.failures, 1, "A failed tail probe must report only once")
            }
        }
    }

    private func eventually(attempts: Int = 200, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<attempts {
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
         scorerOverride: TestCompletionScorer? = nil,
         configuration: AudioTurnEndConfiguration = .init(),
         format: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!) throws {
        self.format = format
        vad = TestFrameVAD(block: blockVAD, fail: failVAD)
        scorer = scorerOverride ?? TestCompletionScorer(block: blockModel, fail: failModel)
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
        consume(buffer, timestamp: timestamp)
    }

    func submit(_ samples: [Float]) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: source.count)
            }
        }
        consume(buffer)
    }

    private func consume(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval? = nil) {
        submitted += 1
        clock.set(clock.value + Double(buffer.frameLength) / format.sampleRate)
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
    private var probeBlocked = false
    private var didEnterProbe = false
    private var probeTotal = 0
    private var probeResult: Result<Float, AudioTurnModelError>?
    init(block: Bool, fail: Bool = false) { blocked = block; self.fail = fail }
    var count: Int { condition.withLock { total } }
    var entered: Bool { condition.withLock { didEnter } }
    var probeEntered: Bool { condition.withLock { didEnterProbe } }
    var probes: Int { condition.withLock { probeTotal } }
    func block() { condition.withLock { blocked = true; didEnter = false } }
    func release() { condition.withLock { blocked = false; condition.broadcast() } }
    func blockProbe() { condition.withLock { probeBlocked = true; didEnterProbe = false } }
    func releaseProbe() { condition.withLock { probeBlocked = false; condition.broadcast() } }
    func setProbeResult(_ result: Result<Float, AudioTurnModelError>) { condition.withLock { probeResult = result } }
    func speechProbability(samples: [Float]) throws -> Float {
        condition.lock(); defer { condition.unlock() }
        didEnter = true
        while blocked { condition.wait() }
        total += 1
        if fail { throw AudioTurnModelError.unavailable }
        return samples.contains(where: { $0 > 0.5 }) ? 0.9 : 0.1
    }
    func speechProbabilityOfTail(samples: [Float]) throws -> Float {
        condition.lock(); defer { condition.unlock() }
        didEnterProbe = true
        while probeBlocked { condition.wait() }
        probeTotal += 1
        if let probeResult { return try probeResult.get() }
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
    private var callCount = 0
    init(block: Bool, fail: Bool) { blocked = block; self.fail = fail }
    var started: Bool { condition.withLock { didStart } }
    var finished: Bool { condition.withLock { didFinish } }
    var inputCount: Int { condition.withLock { receivedCount } }
    var calls: Int { condition.withLock { callCount } }
    func release() { condition.withLock { blocked = false; condition.broadcast() } }
    func completionProbability(samples: [Float]) throws -> Float {
        condition.lock(); defer { condition.unlock() }
        didStart = true; receivedCount = samples.count; callCount += 1
        while blocked { condition.wait() }
        didFinish = true
        if fail { throw AudioTurnModelError.unavailable }
        return 0.9
    }
}
