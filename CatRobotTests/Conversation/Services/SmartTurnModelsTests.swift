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
}
func endpointTestFormat() -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)! }
func endpointWait(_ predicate: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}
