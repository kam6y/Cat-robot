import AVFAudio
import XCTest
@testable import CatRobot

final class SmartTurnModelsTests: XCTestCase {
    private var assets: URL { Bundle.main.bundleURL.appendingPathComponent("SmartTurn") }

    func testCoreMLLoadsBundledModelAndRejectsInvalidInput() throws {
        let scorer = try CoreMLTurnScorer(modelURL: assets.appendingPathComponent("smart_turn.mlmodelc"))
        let result = try scorer.completionProbability(samples: [Float](repeating: 0, count: 128000))
        // Runtime smoke test: Core ML kernels differ across macOS/iOS simulator.
        // Numerical parity is measured separately with the pinned ONNX reference corpus.
        XCTAssertTrue(result.isFinite)
        XCTAssertGreaterThanOrEqual(result, 0)
        XCTAssertLessThan(result, 0.5, "Silence control must remain below the completion threshold")
        XCTAssertThrowsError(try scorer.completionProbability(samples: [0]))
        var invalid = [Float](repeating: 0, count: 128000); invalid[11000] = .nan
        XCTAssertThrowsError(try scorer.completionProbability(samples: invalid))
    }

    func testSileroKeepsRecurrentStateAndResetRestoresFirstFrame() throws {
        let scorer = try SileroVADScorer(modelURL: assets.appendingPathComponent("silero_vad.onnx"))
        let frame = [Float](repeating: 0, count: 512)
        let first = try scorer.speechProbability(samples: frame)
        var last = first
        for _ in 0..<20 { last = try scorer.speechProbability(samples: frame) }
        XCTAssertEqual(first, 0.0016698241, accuracy: 0.00001)
        XCTAssertEqual(last, 0.0039582849, accuracy: 0.00001)
        scorer.reset()
        XCTAssertEqual(try scorer.speechProbability(samples: frame), first, accuracy: 0.000001)
        XCTAssertThrowsError(try scorer.speechProbability(samples: [0]))
        XCTAssertThrowsError(try scorer.speechProbability(samples: [Float](repeating: .nan, count: 512)))
    }

    func testMissingModelsThrowInsteadOfInventingACompleteResult() {
        let missing = URL(fileURLWithPath: "/nonexistent-endpoint-model")
        XCTAssertThrowsError(try CoreMLTurnScorer(modelURL: missing))
        XCTAssertThrowsError(try SileroVADScorer(modelURL: missing))
    }

    func testTailProbePreservesStreamingStateAndContext() throws {
        let scorer = try SileroVADScorer(modelURL: assets.appendingPathComponent("silero_vad.onnx"))
        let control = try SileroVADScorer(modelURL: assets.appendingPathComponent("silero_vad.onnx"))
        let frame = (0..<512).map { Float(sin(Double($0) * 0.13) * 0.1) }
        _ = try scorer.speechProbability(samples: frame)
        _ = try control.speechProbability(samples: frame)
        for count in [1, 127, 256, 511] {
            let tail = Array(frame.prefix(count))
            do {
                let first = try scorer.speechProbabilityOfTail(samples: tail)
                let repeated = try scorer.speechProbabilityOfTail(samples: tail)
                XCTAssertTrue(first.isFinite && (0...1).contains(first))
                XCTAssertEqual(first, repeated, accuracy: 0.000001)
                XCTAssertEqual(try scorer.speechProbability(samples: frame),
                               try control.speechProbability(samples: frame), accuracy: 0.000001,
                               "A tail probe must not advance recurrent state or context")
            } catch {
                XCTFail("A valid partial tail must be scored without committing state: \(error)")
            }
        }
        XCTAssertThrowsError(try scorer.speechProbabilityOfTail(samples: []))
        XCTAssertThrowsError(try scorer.speechProbabilityOfTail(samples: frame))
        XCTAssertThrowsError(try scorer.speechProbabilityOfTail(samples: [.nan]))
    }

    func testQuietPartialTailsStayBelowTheExistingSpeechOnset() throws {
        let scorer = try SileroVADScorer(modelURL: assets.appendingPathComponent("silero_vad.onnx"))
        _ = try scorer.speechProbability(samples: [Float](repeating: 0, count: 512))
        for count in [1, 127, 256, 511] {
            do {
                let probability = try scorer.speechProbabilityOfTail(samples: [Float](repeating: 0, count: count))
                print("Silero quiet-tail samples=\(count) probability=\(probability)")
                XCTAssertTrue(probability.isFinite)
                XCTAssertGreaterThanOrEqual(probability, 0)
                XCTAssertLessThan(probability, 0.5)
            } catch {
                XCTFail("A quiet partial tail must produce a probability: \(error)")
            }
        }
    }
}


final class SmartTurnServiceTests: XCTestCase {
    func testPreparationWaitsForTheModelInsteadOfAbandoningIt() async throws {
        let gate = EndpointInitializationGate(), returned = EndpointReturnFlag()
        let service = SmartTurnService(
            makeScorer: { gate.wait(); return EndpointPreparationScorer() },
            makeVAD: { EndpointPreparationVAD() })
        let task = Task { let value = try await service.makeCapture(sourceFormat: endpointTestFormat(), onEndpoint: { _ in }, onFailure: { _ in }); returned.mark(); return value }
        let started = await endpointWait { gate.entered }; XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(returned.value, "Slow initialization must not turn into an ASR-only capture")
        gate.release()
        let capture = try await task.value
        XCTAssertNotNil(capture)
        capture.cancel()
    }

    func testInitializerAndWarmupFailuresThrowInsteadOfReturningNoCapture() async {
        for failsWarmup in [false, true] {
            let service = SmartTurnService(makeScorer: {
                if !failsWarmup { throw AudioTurnModelError.unavailable }
                return EndpointFailingScorer()
            }, makeVAD: { EndpointPreparationVAD() })
            do {
                let capture = try await service.makeCapture(sourceFormat: endpointTestFormat(), onEndpoint: { _ in }, onFailure: { _ in })
                capture.cancel()
                XCTFail("Initialization failure must be thrown")
            } catch { XCTAssertTrue(error is AudioTurnModelError) }
        }
    }

    func testCancellationDoesNotJoinBlockedWarmupOrVADAndThrowsCancellation() async {
        for blocksVAD in [false, true] {
            let gate = EndpointInitializationGate()
            let service = SmartTurnService(
                makeScorer: { EndpointPreparationScorer(gate: blocksVAD ? nil : gate) },
                makeVAD: { if blocksVAD { gate.wait() }; return EndpointPreparationVAD() })
            let returned = expectation(description: "cancellation returns before blocked work")
            let task = Task {
                defer { returned.fulfill() }
                do {
                    let capture = try await service.makeCapture(sourceFormat: endpointTestFormat(), onEndpoint: { _ in }, onFailure: { _ in })
                    capture.cancel(); return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            let started = await endpointWait { gate.entered }; XCTAssertTrue(started)
            task.cancel()
            await fulfillment(of: [returned], timeout: 0.3)
            gate.release()
            let cancelled = await task.value
            XCTAssertTrue(cancelled)
        }
    }

    func testCancelledPreparationDoesNotStartLaterStagesAndAllowsRetry() async throws {
        for blocksWarmup in [false, true] {
            let gate = EndpointInitializationGate()
            let counts = EndpointPreparationCounts()
            let service = SmartTurnService(makeScorer: {
                let first = counts.initialize() == 1
                if first && !blocksWarmup { gate.wait() }
                return EndpointCountingScorer(counts: counts, gate: first && blocksWarmup ? gate : nil)
            }, makeVAD: {
                counts.makeVAD()
                return EndpointPreparationVAD()
            })
            let returned = expectation(description: "cancelled preparation returns without joining")
            let task = Task {
                defer { returned.fulfill() }
                do {
                    let capture = try await service.makeCapture(sourceFormat: endpointTestFormat(), onEndpoint: { _ in }, onFailure: { _ in })
                    capture.cancel()
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            defer { task.cancel(); gate.release() }
            let entered = await endpointWait { gate.entered }
            XCTAssertTrue(entered)
            task.cancel()
            await fulfillment(of: [returned], timeout: 0.3)
            gate.release()
            let cancelled = await task.value
            XCTAssertTrue(cancelled)

            var next: AudioTurnEndCapture?
            for _ in 0..<100 {
                do {
                    next = try await service.makeCapture(sourceFormat: endpointTestFormat(), onEndpoint: { _ in }, onFailure: { _ in })
                    break
                } catch AudioTurnModelError.busy {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            let capture = try XCTUnwrap(next, "Retired preparation must release its ownership")
            defer { capture.cancel() }
            XCTAssertEqual(counts.initializations, 2)
            XCTAssertEqual(counts.warmups, blocksWarmup ? 2 : 1, "Cancellation must skip warmup unless it was already running")
            XCTAssertEqual(counts.vads, 1, "Only the retry may begin VAD construction")
        }
    }
}

private final class EndpointPreparationCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var initializationCount = 0
    private var warmupCount = 0
    private var vadCount = 0
    var initializations: Int { lock.withLock { initializationCount } }
    var warmups: Int { lock.withLock { warmupCount } }
    var vads: Int { lock.withLock { vadCount } }
    func initialize() -> Int { lock.withLock { initializationCount += 1; return initializationCount } }
    func warmup() { lock.withLock { warmupCount += 1 } }
    func makeVAD() { lock.withLock { vadCount += 1 } }
}

private struct EndpointCountingScorer: AudioTurnScoring {
    let counts: EndpointPreparationCounts
    let gate: EndpointInitializationGate?
    func completionProbability(samples: [Float]) throws -> Float {
        counts.warmup()
        gate?.wait()
        return 0.1
    }
}

private final class EndpointReturnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false
    var value: Bool { lock.withLock { returned } }
    func mark() { lock.withLock { returned = true } }
}
private struct EndpointFailingScorer: AudioTurnScoring {
    func completionProbability(samples: [Float]) throws -> Float { throw AudioTurnModelError.unavailable }
}

final class EndpointInitializationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var hasEntered = false
    private var released = false
    var entered: Bool { condition.withLock { hasEntered } }
    func wait() {
        condition.lock(); hasEntered = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}
struct EndpointPreparationScorer: AudioTurnScoring {
    var gate: EndpointInitializationGate? = nil
    func completionProbability(samples: [Float]) throws -> Float { gate?.wait(); return 0.1 }
}
struct EndpointPreparationVAD: VoiceActivityScoring {
    func speechProbability(samples: [Float]) throws -> Float { 0 }
    func speechProbabilityOfTail(samples: [Float]) throws -> Float { 0 }
}
func endpointTestFormat() -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)! }
func endpointWait(_ predicate: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}
