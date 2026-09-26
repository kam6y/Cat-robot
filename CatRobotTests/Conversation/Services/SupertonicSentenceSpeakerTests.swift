import XCTest
@testable import CatRobot

@MainActor
final class SupertonicSentenceSpeakerTests: XCTestCase {
    func testSingleInputUsesCorrection() async throws {
        let speaker = SupertonicSentenceSpeaker(player: TestPCMPlayer(), prepare: {}, voice: { .f1 }, synthesize: { text, voice in
            XCTAssertEqual(text, "アイフォーンを使う。")
            XCTAssertEqual(voice, .f1)
            return SpeechPCM(samples: [0, 0.1], sampleRate: 24_000)
        })
        let events = try await speaker.speak("iPhoneを使う。")
        var finished = false
        for try await event in events { if event == .finished { finished = true } }
        XCTAssertTrue(finished)
    }
    func testPrefetchIsOneAheadAndVoiceIsFixedForWholeReply() async throws {
        let synth = ControlledPCMSynthesizer()
        let player = ControlledPCMPlayer()
        var voice: SpeechVoicePreset = .f1
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { voice }, synthesize: { try await synth.make($0, voice: $1) })
        let channel = SpeechSentenceChannel()
        let producer = Task {
            for i in 0..<3 { try await channel.send(.init(ordinal: i, original: "文\(i)。")) }
            await channel.finish()
        }
        let events = try await speaker.speakSentences(from: channel, prefetch: true)
        let consume = Task { var starts: [Int] = []; for try await event in events { if event.event == .started { starts.append(event.ordinal) } }; return starts }
        await synth.waitForCalls(1); await synth.release(0)
        await player.waitForCalls(1)
        voice = .m5
        await synth.waitForCalls(2); await synth.release(1)
        let count = await synth.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(player.played, [1])
        player.complete(0)
        await player.waitForCalls(2)
        await synth.waitForCalls(3); await synth.release(2)
        player.complete(1)
        await player.waitForCalls(3); player.complete(2)
        let starts = try await consume.value
        try await producer.value
        XCTAssertEqual(starts, [0, 1, 2])
        XCTAssertEqual(player.played, [1, 2, 3])
        let voices = await synth.voices
        XCTAssertEqual(voices, [.f1, .f1, .f1])
        let maximum = await synth.maxConcurrent
        XCTAssertEqual(maximum, 1)
    }
    func testStopDrainsNextInferenceAndNeverPlaysLatePCM() async throws {
        let synth = ControlledPCMSynthesizer()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { try await synth.make($0, voice: $1) })
        let channel = SpeechSentenceChannel()
        try await channel.send(.init(ordinal: 0, original: "一。"))
        try await channel.send(.init(ordinal: 1, original: "二。")); await channel.finish()
        let events = try await speaker.speakSentences(from: channel, prefetch: true)
        let consume = Task { for try await _ in events {} }
        await synth.waitForCalls(1); await synth.release(0)
        await synth.waitForCalls(2)
        let stopping = Task { await speaker.stop() }
        await player.waitForStop()
        do { _ = try await speaker.speak("too early"); XCTFail("accepted before inference drained") } catch {}
        await synth.release(1)
        await stopping.value
        _ = await consume.result
        XCTAssertEqual(player.played, [1])
        let next = try await speaker.speak("新しい返答。")
        let drain = Task { for try await _ in next {} }
        await synth.waitForCalls(3); await synth.release(2)
        await player.waitForCalls(2)
        player.complete(0) // stale callback must not stop the new operation
        player.complete(1)
        try await drain.value
        XCTAssertEqual(player.played, [1, 3])
    }
    func testPrefetchFailureStopsCurrentPlayback() async throws {
        let synth = ControlledPCMSynthesizer()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { try await synth.make($0, voice: $1) })
        let channel = SpeechSentenceChannel()
        try await channel.send(.init(ordinal: 0, original: "一。"))
        try await channel.send(.init(ordinal: 1, original: "二。")); await channel.finish()
        let events = try await speaker.speakSentences(from: channel, prefetch: true)
        let consume = Task { for try await _ in events {} }
        await synth.waitForCalls(1); await synth.release(0)
        await synth.waitForCalls(2); await synth.fail(1)
        do { try await consume.value; XCTFail("failed inference succeeded") } catch {}
        XCTAssertGreaterThan(player.stops, 0)
        XCTAssertEqual(player.played, [1])
    }
}

actor ControlledPCMSynthesizer {
    private var pending: [Int: CheckedContinuation<SpeechPCM, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var voices: [SpeechVoicePreset] = []
    private(set) var maxConcurrent = 0
    var count: Int { voices.count }
    func make(_ text: String, voice: SpeechVoicePreset) async throws -> SpeechPCM {
        let index = voices.count; voices.append(voice)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            maxConcurrent = max(maxConcurrent, pending.count)
            let ready = waiters.filter { $0.0 <= voices.count }; waiters.removeAll { $0.0 <= voices.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if voices.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume(returning: SpeechPCM(samples: [Float(index + 1)], sampleRate: 24_000)) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: SupertonicError.inferenceFailed) }
}

@MainActor
final class ControlledPCMPlayer: PCMPlaying {
    private var continuations: [AsyncThrowingStream<SpeechEvent, Error>.Continuation] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var played: [Float] = []
    private(set) var stops = 0
    func play(_ pcm: SpeechPCM) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        continuations.append(pair.continuation); played.append(pcm.samples[0])
        pair.continuation.yield(.started)
        let ready = waiters.filter { $0.0 <= played.count }; waiters.removeAll { $0.0 <= played.count }
        ready.forEach { $0.1.resume() }
        return pair.stream
    }
    func waitForCalls(_ count: Int) async { if played.count < count { await withCheckedContinuation { waiters.append((count, $0)) } } }
    func complete(_ index: Int) { continuations[index].yield(.finished); continuations[index].finish() }
    func stop() async {
        stops += 1
        continuations.forEach { $0.yield(.cancelled); $0.finish() }
        let ready = stopWaiters; stopWaiters = []; ready.forEach { $0.resume() }
    }
    func waitForStop() async { if stops == 0 { await withCheckedContinuation { stopWaiters.append($0) } } }
}
