import Foundation
import XCTest
@testable import CatRobot

/// AudioTurnEndState の決定論テスト。フレームは 512 sample / 16 kHz（32 ms）で、
/// 発話は p = 0.9、無音は p = 0.1 を既定にする。時刻は 1.0 から 0.032 ずつ進む。
/// 数値（16 frame = 0.5 s、7 frame = 0.224 s、閾値 >0.5、窓 0.3 s、窓長 128,000）はテスト側の literal で固定する。
final class AudioTurnEndStateTests: XCTestCase {
    private var sut = AudioTurnEndState()
    private var time: TimeInterval = 1.0

    override func setUp() {
        super.setUp()
        sut = AudioTurnEndState()
        time = 1.0
    }

    // MARK: - Helpers

    private func frame(_ value: Float = 0.1) -> [Float] {
        Array(repeating: value, count: 512)
    }

    /// 1 frame を流し、時刻を 32 ms 進める。
    @discardableResult
    private func consume(_ probability: Float, sample: Float = 0.1, samples: [Float]? = nil) -> AudioTurnEndRequest? {
        time += 0.032
        return sut.consume(samples: samples ?? frame(sample), speechProbability: probability, at: time)
    }

    /// 発話 frame と無音 frame を順に流し、返った要求を集める。
    @discardableResult
    private func feed(speech: Int = 0, silence: Int = 0, speechProbability: Float = 0.9, silenceProbability: Float = 0.1) -> [AudioTurnEndRequest] {
        var requests: [AudioTurnEndRequest] = []
        for _ in 0..<speech {
            if let request = consume(speechProbability) { requests.append(request) }
        }
        for _ in 0..<silence {
            if let request = consume(silenceProbability) { requests.append(request) }
        }
        return requests
    }

    private func requestAfterSpeechAndPause() throws -> AudioTurnEndRequest {
        let requests = feed(speech: 16, silence: 7)
        XCTAssertEqual(requests.count, 1)
        return try XCTUnwrap(requests.first)
    }

    func testDefaultRequestsAfterSevenFramesAndUsesStrictThreshold() throws {
        XCTAssertTrue(feed(speech: 16, silence: 6).isEmpty)
        let request = try XCTUnwrap(consume(0.1))
        XCTAssertFalse(sut.accept(probability: 0.5, for: request, at: time))
        XCTAssertTrue(sut.accept(probability: 0.5001, for: request, at: time))
    }

    func testHigherAudioOnlyThresholdRejectsIntermediateConfidence() throws {
        sut = AudioTurnEndState(configuration: .init(completeProbability: 0.85))
        let request = try XCTUnwrap(feed(speech: 16, silence: 7).first)
        XCTAssertFalse(sut.accept(probability: 0.85, for: request, at: time))
        XCTAssertTrue(sut.accept(probability: 0.8501, for: request, at: time))
    }

    // MARK: - Request generation

    func testFreshStateProducesNothingAndRejectsForeignRequests() {
        XCTAssertNil(consume(0.1))
        let foreign = AudioTurnEndRequest(revision: 0, samples: Array(repeating: 0, count: 128_000), requestedAt: time)
        XCTAssertFalse(sut.accept(probability: 0.99, for: foreign, at: time))
    }

    func testSilenceOnlyNeverRequests() {
        XCTAssertTrue(feed(silence: 70).isEmpty)
    }

    func testRequestNeedsSixteenSpeechFramesAndSevenSilentFrames() throws {
        XCTAssertTrue(feed(speech: 15, silence: 7).isEmpty)

        sut = AudioTurnEndState()
        XCTAssertTrue(feed(speech: 16, silence: 6).isEmpty)
        let request = try XCTUnwrap(consume(0.1))
        XCTAssertEqual(request.requestedAt, time)
        XCTAssertEqual(request.samples.count, 128_000)
    }

    func testSpeechAccumulatesAcrossPauses() {
        XCTAssertTrue(feed(speech: 15, silence: 7).isEmpty)
        XCTAssertEqual(feed(speech: 1, silence: 7).count, 1)
    }

    func testOnlyOneRequestPerPause() throws {
        _ = try requestAfterSpeechAndPause()
        XCTAssertTrue(feed(silence: 50).isEmpty)
    }

    func testResumedSpeechAdvancesRevisionAndAllowsANewRequest() throws {
        let first = try requestAfterSpeechAndPause()
        let second = try XCTUnwrap(feed(speech: 1, silence: 7).first)
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertFalse(sut.accept(probability: 0.9, for: first, at: second.requestedAt))
        XCTAssertTrue(sut.accept(probability: 0.9, for: second, at: second.requestedAt))
    }

    func testRevisionAdvancesOnEveryResumeAndReset() throws {
        let first = try requestAfterSpeechAndPause()
        let second = try XCTUnwrap(feed(speech: 1, silence: 7).first)
        sut.reset()
        let third = try requestAfterSpeechAndPause()
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertGreaterThan(third.revision, second.revision)
    }

    // MARK: - VAD hysteresis

    func testProbabilityBetweenThresholdsKeepsTheActiveState() {
        // active のまま: 0.35 以上 0.5 未満は無音として数えない。
        feed(speech: 16)
        XCTAssertTrue(feed(silence: 7, silenceProbability: 0.4).isEmpty)
        XCTAssertTrue(feed(silence: 7, silenceProbability: 0.35).isEmpty)
        XCTAssertEqual(feed(silence: 7, silenceProbability: 0.1).count, 1)
    }

    func testProbabilityBetweenThresholdsKeepsTheInactiveState() {
        // inactive のまま: 0.5 未満では発話が始まらない。
        XCTAssertTrue(feed(speech: 16, silence: 7, speechProbability: 0.49).isEmpty)
        XCTAssertEqual(feed(speech: 16, silence: 7, speechProbability: 0.5).count, 1)
    }

    func testOffsetThresholdIsStrictlyBelowPointThreeFive() {
        feed(speech: 16)
        XCTAssertEqual(feed(silence: 7, silenceProbability: 0.349).count, 1)
    }

    // MARK: - Audio window

    func testWindowIsZeroPaddedInFrontWhenShorterThanEightSeconds() throws {
        var fed: [Float] = []
        for index in 0..<16 {
            let value = Float(index + 1) / 100
            fed += frame(value)
            XCTAssertNil(consume(0.9, sample: value))
        }
        var request: AudioTurnEndRequest?
        for _ in 0..<7 {
            fed += frame(0)
            request = consume(0.1, sample: 0) ?? request
        }
        let samples = try XCTUnwrap(request?.samples)
        XCTAssertEqual(samples.count, 128_000)
        let padding = 128_000 - 23 * 512
        XCTAssertEqual(Array(samples.prefix(padding)), Array(repeating: 0, count: padding))
        XCTAssertEqual(Array(samples.suffix(23 * 512)), fed)
    }

    func testWindowKeepsOnlyTheLatestEightSeconds() throws {
        // 260 発話 frame + 7 無音 frame = 267 frame > 250 frame（128,000 sample）。
        for index in 0..<260 {
            XCTAssertNil(consume(0.9, sample: Float(index)))
        }
        var request: AudioTurnEndRequest?
        for _ in 0..<7 {
            request = consume(0.1, sample: -1) ?? request
        }
        let samples = try XCTUnwrap(request?.samples)
        XCTAssertEqual(samples.count, 128_000)
        XCTAssertEqual(samples.first, 17)
        XCTAssertEqual(samples[511], 17)
        XCTAssertEqual(samples[512], 18)
        XCTAssertEqual(Array(samples.suffix(7 * 512)), Array(repeating: -1, count: 7 * 512))
    }

    func testRequestSamplesAreASnapshot() throws {
        let request = try requestAfterSpeechAndPause()
        let before = request.samples
        feed(speech: 5, silence: 5)
        XCTAssertEqual(request.samples, before)
    }

    // MARK: - accept

    func testAcceptRequiresProbabilityGreaterThanPointFive() throws {
        let request = try requestAfterSpeechAndPause()
        XCTAssertFalse(sut.accept(probability: 0.5, for: request, at: request.requestedAt))
        // 却下は要求を消費しない。
        XCTAssertTrue(sut.accept(probability: 0.5001, for: request, at: request.requestedAt))
    }

    func testAcceptIsConsumedOnce() throws {
        let request = try requestAfterSpeechAndPause()
        XCTAssertTrue(sut.accept(probability: 0.9, for: request, at: request.requestedAt))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))
    }

    func testAcceptRejectsNonFiniteOrOutOfRangeProbabilities() throws {
        let request = try requestAfterSpeechAndPause()
        for probability: Float in [.nan, .infinity, -.infinity, 1.0001, -0.1] {
            XCTAssertFalse(sut.accept(probability: probability, for: request, at: request.requestedAt), "\(probability)")
        }
        XCTAssertTrue(sut.accept(probability: 1.0, for: request, at: request.requestedAt))
    }

    func testAcceptWindowIsThreeHundredMilliseconds() throws {
        let late = try requestAfterSpeechAndPause()
        XCTAssertFalse(sut.accept(probability: 0.9, for: late, at: late.requestedAt + 0.31))
        XCTAssertFalse(sut.accept(probability: 0.9, for: late, at: late.requestedAt - 0.01))
        XCTAssertFalse(sut.accept(probability: 0.9, for: late, at: .nan))
        XCTAssertTrue(sut.accept(probability: 0.9, for: late, at: late.requestedAt + 0.3))
    }

    func testAcceptWindowBoundaryIsComputedAdditively() throws {
        for _ in 0..<16 {
            XCTAssertNil(sut.consume(samples: frame(), speechProbability: 0.9, at: 0.5))
        }
        for _ in 0..<6 {
            XCTAssertNil(sut.consume(samples: frame(), speechProbability: 0.1, at: 0.5))
        }
        let request = try XCTUnwrap(sut.consume(samples: frame(), speechProbability: 0.1, at: 1.0))
        XCTAssertEqual(request.requestedAt, 1.0)
        // 期限は now <= requestedAt + 0.3 の加算式で比較する（1.3 - 1.0 の端数で落とさず、1.3004 は通さない）。
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: 1.3004))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: 0.9999))
        XCTAssertTrue(sut.accept(probability: 0.9, for: request, at: 1.3))
    }

    func testAcceptRejectsARequestWithADifferentRevisionOrTime() throws {
        let request = try requestAfterSpeechAndPause()
        let otherRevision = AudioTurnEndRequest(revision: request.revision &+ 1, samples: request.samples, requestedAt: request.requestedAt)
        let otherTime = AudioTurnEndRequest(revision: request.revision, samples: request.samples, requestedAt: request.requestedAt + 0.001)
        XCTAssertFalse(sut.accept(probability: 0.9, for: otherRevision, at: request.requestedAt))
        XCTAssertFalse(sut.accept(probability: 0.9, for: otherTime, at: request.requestedAt))
        XCTAssertTrue(sut.accept(probability: 0.9, for: request, at: request.requestedAt))
    }

    // MARK: - reset and invalid input

    func testResetDiscardsAudioAndInvalidatesThePendingRequest() throws {
        feed(speech: 240)
        let request = try XCTUnwrap(feed(silence: 7).first)
        sut.reset()
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))

        // reset 後は発話累積もやり直し。
        XCTAssertTrue(feed(speech: 15, silence: 7).isEmpty)
        let fresh = try XCTUnwrap(feed(speech: 1, silence: 7).first)
        XCTAssertGreaterThan(fresh.revision, request.revision)
        let padding = 128_000 - 30 * 512
        XCTAssertEqual(Array(fresh.samples.prefix(padding)), Array(repeating: 0, count: padding))
    }

    func testWrongFrameLengthResetsState() throws {
        let request = try requestAfterSpeechAndPause()
        XCTAssertNil(consume(0.9, samples: Array(repeating: 0.1, count: 511)))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))

        feed(speech: 16)
        XCTAssertNil(consume(0.9, samples: Array(repeating: 0.1, count: 513)))
        XCTAssertTrue(feed(silence: 7).isEmpty)
        XCTAssertEqual(feed(speech: 16, silence: 7).count, 1)
    }

    func testNonFiniteSampleResetsState() throws {
        let request = try requestAfterSpeechAndPause()
        var samples = frame(0.1)
        samples[100] = .nan
        XCTAssertNil(consume(0.9, samples: samples))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))

        feed(speech: 16)
        samples[100] = .infinity
        XCTAssertNil(consume(0.9, samples: samples))
        XCTAssertTrue(feed(silence: 7).isEmpty)
    }

    func testNonFiniteSpeechProbabilityResetsState() throws {
        let request = try requestAfterSpeechAndPause()
        XCTAssertNil(consume(.nan))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))

        feed(speech: 16)
        XCTAssertNil(consume(.infinity))
        XCTAssertTrue(feed(silence: 7).isEmpty)
    }

    func testTimeGoingBackwardsResetsStateButEqualTimeIsAllowed() throws {
        let request = try requestAfterSpeechAndPause()
        XCTAssertNil(sut.consume(samples: frame(), speechProbability: 0.9, at: time - 0.001))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))

        // 同じ時刻の frame は逆行ではない。
        feed(speech: 16)
        for _ in 0..<6 {
            XCTAssertNil(sut.consume(samples: frame(), speechProbability: 0.1, at: time))
        }
        XCTAssertNotNil(sut.consume(samples: frame(), speechProbability: 0.1, at: time))
    }

    func testNonFiniteTimestampResetsState() throws {
        let request = try requestAfterSpeechAndPause()
        XCTAssertNil(sut.consume(samples: frame(), speechProbability: 0.9, at: .nan))
        XCTAssertFalse(sut.accept(probability: 0.9, for: request, at: request.requestedAt))
    }
}
