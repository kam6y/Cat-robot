import XCTest
@testable import CatRobot

@MainActor
final class SupertonicSpeakerTests: XCTestCase {
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
    func testStopDrainsInferenceAndDiscardsLatePCM() async throws {
        let gate = ConversationTestGate()
        let player = TestPCMPlayer()
        let speaker = SupertonicSpeaker(player: player, prepare: {}, synthesize: { _ in
            await gate.wait()
            return SpeechPCM(samples: [0, 0.1, 0], sampleRate: 24000)
        })
        let events = try await speaker.speak("first")
        await gate.waitUntilEntered()
        let stop = Task { await speaker.stop() }
        await Task.yield()
        do { _ = try await speaker.speak("second"); XCTFail("Must reject concurrent synthesis") } catch {}
        await gate.open()
        await stop.value
        var collected: [SpeechEvent] = []
        for try await event in events { collected.append(event) }
        XCTAssertEqual(collected, [.cancelled])
        XCTAssertEqual(player.playCount, 0)
        let next = try await speaker.speak("third")
        for try await event in next { if event == .finished { break } }
        XCTAssertEqual(player.playCount, 1)
    }
    func testSynthesisFailureDoesNotStartPlayback() async throws {
        let player = TestPCMPlayer()
        let speaker = SupertonicSpeaker(player: player, prepare: {}, synthesize: { _ in throw SupertonicError.inferenceFailed })
        let stream = try await speaker.speak("fail")
        do { for try await _ in stream {}; XCTFail("Expected failure") } catch {}
        XCTAssertEqual(player.playCount, 0)
    }
    func testInvalidPCMNeverReachesPlayer() async throws {
        let player = TestPCMPlayer()
        let speaker = SupertonicSpeaker(player: player, prepare: {}, synthesize: { _ in
            SpeechPCM(samples: [.nan], sampleRate: 24000)
        })
        let stream = try await speaker.speak("invalid")
        do { for try await _ in stream {}; XCTFail("Expected invalid PCM") } catch {}
        XCTAssertEqual(player.playCount, 0)
    }
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
