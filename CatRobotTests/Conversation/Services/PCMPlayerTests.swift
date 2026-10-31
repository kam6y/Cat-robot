import AVFAudio
import XCTest
@testable import CatRobot

/// 共有 engine での PCM 再生。engine の起動・停止は行わず、player node の予約と停止だけを行う。
@MainActor
final class PCMPlayerTests: XCTestCase {
    func testPlaySchedulesOnSharedEngineWithoutRestartingIt() async throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let player = PCMPlayer(engine: engine)

        let stream = try await player.play(makeTestPCM(sampleRate: 24_000, frames: 240))

        XCTAssertEqual(driver.calls, [
            .configure(duplex: true), .start,
            .connectPlayer(sampleRate: 24_000), .schedule(frames: 240), .startPlayer,
        ])
        var iterator = stream.makeAsyncIterator()
        driver.setPlayerSampleTime(120)
        let started = try await iterator.next()
        XCTAssertEqual(started, .started)
        driver.completePlayback()
        let finished = try await iterator.next()
        XCTAssertEqual(finished, .finished)
        let end = try await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(driver.calls.last, .stopPlayer)
        XCTAssertFalse(driver.calls.contains(.stop), "finishing a sentence must not stop the shared engine")
        XCTAssertTrue(driver.isRunning)
    }

    func testStopStopsOnlyThePlayerNodeAndEmitsCancelled() async throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let player = PCMPlayer(engine: engine)
        let stream = try await player.play(makeTestPCM())

        await player.stop()

        var iterator = stream.makeAsyncIterator()
        let cancelled = try await iterator.next()
        XCTAssertEqual(cancelled, .cancelled)
        let end = try await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(driver.calls.last, .stopPlayer)
        XCTAssertFalse(driver.calls.contains(.stop))
        XCTAssertTrue(driver.isRunning)
        driver.completePlayback()
        XCTAssertEqual(driver.calls.filter { $0 == .stopPlayer }.count, 1, "a late completion must not stop the node again")
    }

    func testStreamCancellationDuringInterruptionRecordsPlaybackStoppedBeforeExplicitStop() async throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let player = PCMPlayer(engine: engine)
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let stream = try await ReplyTraceContext.$current.withValue(trace) { try await player.play(makeTestPCM()) }
        trace.mark(.interruptionDetected)

        // 割り込みでは、再生イベントの購読が task の取り消しで終わる経路が、speaker の遅れた stop() より先に node を止める。
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<400 where !driver.calls.contains(.stopPlayer) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(driver.calls.filter { $0 == .stopPlayer }.count, 1, "stream termination must stop the node")

        await player.stop()

        XCTAssertEqual(sink.events.map(\.point), [.interruptionDetected, .interruptionPlaybackStopped],
                       "the node stop reached through stream termination must close the interruption interval")
        XCTAssertEqual(driver.calls.filter { $0 == .stopPlayer }.count, 1, "the late explicit stop must not stop the node again")
    }

    func testPlayFailsWhileSharedEngineIsInactive() async {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        let player = PCMPlayer(engine: engine)

        do {
            _ = try await player.play(makeTestPCM())
            XCTFail("playback without an active engine must fail")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }
        XCTAssertFalse(driver.calls.contains(.startPlayer))
    }

    func testSecondPlayWhileActiveFailsWithoutTouchingTheEngine() async throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let player = PCMPlayer(engine: engine)
        _ = try await player.play(makeTestPCM())
        let callsAfterFirstPlay = driver.calls.count

        do {
            _ = try await player.play(makeTestPCM())
            XCTFail("a second playback must be rejected while one is active")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }
        XCTAssertEqual(driver.calls.count, callsAfterFirstPlay)
        await player.stop()
    }
}
