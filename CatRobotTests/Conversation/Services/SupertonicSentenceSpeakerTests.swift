import XCTest
@testable import CatRobot

@MainActor
final class SupertonicSentenceSpeakerTests: XCTestCase {
    func testPreprocessingAuditKeepsJapaneseAndReportsRemovedSymbols() {
        let input = "「がき\u{3099}12/3」😀 @iPhone。"
        let audit = SpeechTextAudit(input: input)
        XCTAssertEqual(audit.original, input)
        XCTAssertTrue(audit.processedChunks.joined().precomposedStringWithCanonicalMapping.contains("がぎ12 3"))
        XCTAssertTrue(audit.removedOrReplaced.contains("😀"))
        XCTAssertTrue(audit.removedOrReplaced.contains("/"))
        XCTAssertTrue(audit.removedOrReplaced.contains("@"))
        XCTAssertFalse(audit.removedOrReplaced.contains("\u{3099}"))
        XCTAssertTrue(audit.processedChunks.joined().contains("「"))
    }
    func testSynthesisFailureDoesNotStartPlayback() async throws {
        let player = TestPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in throw SupertonicError.inferenceFailed })
        let stream = try await speaker.speak("fail")
        do { for try await _ in stream {}; XCTFail("Expected failure") } catch {}
        XCTAssertEqual(player.playCount, 0)
    }
    func testInvalidPCMNeverReachesPlayer() async throws {
        let player = TestPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in
            SpeechPCM(samples: [.nan], sampleRate: 24000)
        })
        let stream = try await speaker.speak("invalid")
        do { for try await _ in stream {}; XCTFail("Expected invalid PCM") } catch {}
        XCTAssertEqual(player.playCount, 0)
    }

    func testSingleInputUsesRealPronunciation() async throws {
        let speaker = SupertonicSentenceSpeaker(player: TestPCMPlayer(), prepare: {}, normalize: { try await JapanesePronunciationService.shared.normalize($0) }, voice: { .f1 }, synthesize: { text, voice in
            XCTAssertEqual(text, "アイフォーンヲツカウ。")
            XCTAssertEqual(voice, .f1)
            return SpeechPCM(samples: [0, 0.1], sampleRate: 24_000)
        })
        let events = try await speaker.speak("iPhoneを使う。")
        var finished = false
        for try await event in events { if event == .finished { finished = true } }
        XCTAssertTrue(finished)
    }
    func testUsesInjectedPronunciationAndAuditsOriginal() async throws {
        var audit: [(String, String)] = []
        let speaker = SupertonicSentenceSpeaker(player: TestPCMPlayer(), prepare: {},
            normalize: { original in
                XCTAssertEqual(original, "YouTube + iPhone")
                return "ユーチューブ プラス アイフォーン"
            }, voice: { .f1 }, synthesize: { text, _ in
                XCTAssertEqual(text, "ユーチューブ プラス アイフォーン")
                return SpeechPCM(samples: [1], sampleRate: 24_000)
            })
        speaker.onInput = { audit.append(($0, $1)) }
        let stream = try await speaker.speak("YouTube + iPhone")
        for try await _ in stream {}
        XCTAssertEqual(audit.map(\.0), ["YouTube + iPhone"])
        XCTAssertEqual(audit.map(\.1), ["ユーチューブ プラス アイフォーン"])
    }

    func testPronunciationFailureNeverSynthesizesOriginalOrStartsPlayer() async throws {
        let player = TestPCMPlayer()
        let calls = SynthesisInputs()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {},
            normalize: { _ in throw ConversationServiceError.speechSynthesisFailed },
            voice: { .f1 }, synthesize: { text, _ in
                await calls.record(text)
                return SpeechPCM(samples: [1], sampleRate: 24_000)
            })
        let stream = try await speaker.speak("iPhone")
        do { for try await _ in stream {}; XCTFail("conversion failure became successful speech") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed) }
        let inputs = await calls.inputs
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(player.playCount, 0)
    }

    func testStopDuringPronunciationNeverStartsSynthesis() async throws {
        let converter = ControlledPronunciation()
        let inputs = SynthesisInputs()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {},
            normalize: { try await converter.normalize($0) }, voice: { .f1 },
            synthesize: { text, _ in
                await inputs.record(text)
                return SpeechPCM(samples: [1], sampleRate: 24_000)
            })
        var audited = false
        speaker.onInput = { _, _ in audited = true }
        let stream = try await speaker.speak("YouTube")
        let consume = Task { for try await _ in stream {} }
        await converter.waitUntilStarted()
        let stopping = Task { await speaker.stop() }
        await player.waitForStop()
        await converter.release()
        await stopping.value
        do { try await consume.value; XCTFail("cancelled conversion succeeded") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .cancelled) }
        let synthesized = await inputs.inputs
        XCTAssertTrue(synthesized.isEmpty)
        XCTAssertTrue(player.played.isEmpty)
        XCTAssertFalse(audited)
    }

    func testExpandedPronunciationNeverSynthesizesPrefix() async throws {
        let inputs = SynthesisInputs()
        let player = TestPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {},
            normalize: { try await JapanesePronunciationService.shared.normalize($0) },
            voice: { .f1 }, synthesize: { text, _ in
                await inputs.record(text)
                return SpeechPCM(samples: [1], sampleRate: 24_000)
            })
        let stream = try await speaker.speak(String(repeating: "猫", count: 1001))
        do { for try await _ in stream {}; XCTFail("overlong speech succeeded") }
        catch { XCTAssertEqual(error as? JapanesePronunciationError, .outputTooLong) }
        let synthesized = await inputs.inputs
        XCTAssertTrue(synthesized.isEmpty)
        XCTAssertEqual(player.playCount, 0)
    }

    func testPrefetchIsOneAheadAndVoiceIsFixedForWholeReply() async throws {
        let synth = ControlledPCMSynthesizer()
        let player = ControlledPCMPlayer()
        var voice: SpeechVoicePreset = .f1
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { voice }, synthesize: { try await synth.make($0, voice: $1) })
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
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { try await synth.make($0, voice: $1) })
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
        do {
            try await consume.value
            XCTFail("stopped speech completed successfully")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .cancelled)
        }
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
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { try await synth.make($0, voice: $1) })
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
    func emit(_ event: SpeechEvent, index: Int) { continuations[index].yield(event) }
    func fail(_ index: Int) { continuations[index].finish(throwing: ConversationServiceError.speechSynthesisFailed) }
    func stop() async {
        stops += 1
        continuations.forEach { $0.yield(.cancelled); $0.finish() }
        let ready = stopWaiters; stopWaiters = []; ready.forEach { $0.resume() }
    }
    func waitForStop() async { if stops == 0 { await withCheckedContinuation { stopWaiters.append($0) } } }
}

@MainActor
final class TestPCMPlayer: PCMPlaying {
    var playCount = 0
    func play(_ pcm: SpeechPCM) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        playCount += 1
        return AsyncThrowingStream { $0.yield(.started); $0.yield(.finished); $0.finish() }
    }
    func stop() async {}
}

actor SynthesisInputs {
    private(set) var inputs: [String] = []
    func record(_ text: String) { inputs.append(text) }
}

actor ControlledPronunciation {
    private var pending: CheckedContinuation<String, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func normalize(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if pending == nil { await withCheckedContinuation { started = $0 } }
    }
    func release() { pending?.resume(returning: "ユーチューブ"); pending = nil }
}
