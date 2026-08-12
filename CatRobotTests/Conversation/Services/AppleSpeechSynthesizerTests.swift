import AVFAudio
import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class AppleSpeechSynthesizerTests: XCTestCase {
    func testBoundedCollectorTimesOutAndCancelsItsIterator() async {
        let didCancelIterator = expectation(description: "collector cancelled its iterator")
        let stream = AsyncThrowingStream<SpeechEvent, Error> { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    didCancelIterator.fulfill()
                }
            }
        }

        do {
            _ = try await collect(stream, timeout: 0.01)
            XCTFail("Expected collection to time out")
        } catch BoundedCollectionError.timedOut {
            // Expected: a missing terminal event fails promptly.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [didCancelIterator], timeout: 0.1)
    }

    func testPreparePrefersCanonicalExactJapaneseVoiceAndIsIdempotent() async throws {
        let driver = FakeSpeechSynthesizerDriver(voices: [
            .init(identifier: "fallback-ja", language: "ja"),
            .init(identifier: "exact-ja-jp", language: "ja-jp"),
        ])
        let service = AppleSpeechSynthesizer(driver: driver, language: "ja-JP")

        try await service.prepare()
        try await service.prepare()
        let stream = try await service.speak("おはよう")
        let runID = try XCTUnwrap(driver.lastRunID)
        driver.emit(.didFinish(runID: runID))
        _ = try await collect(stream)

        XCTAssertEqual(driver.availableVoicesCallCount, 1)
        XCTAssertEqual(driver.spokenVoiceIdentifiers, ["exact-ja-jp"])
    }

    func testPrepareFallsBackToCanonicalJapaneseLanguageCode() async throws {
        let driver = FakeSpeechSynthesizerDriver(voices: [
            .init(identifier: "english", language: "en-US"),
            .init(identifier: "fallback-ja", language: "ja"),
        ])
        let service = AppleSpeechSynthesizer(driver: driver, language: "ja-JP")

        try await service.prepare()
        let stream = try await service.speak("こんにちは")
        let runID = try XCTUnwrap(driver.lastRunID)
        driver.emit(.didFinish(runID: runID))
        _ = try await collect(stream)

        XCTAssertEqual(driver.spokenVoiceIdentifiers, ["fallback-ja"])
    }

    func testPrepareFailsWhenNoJapaneseVoiceIsInstalled() async {
        let driver = FakeSpeechSynthesizerDriver(voices: [
            .init(identifier: "english", language: "en-US"),
        ])
        let service = AppleSpeechSynthesizer(driver: driver, language: "ja-JP")

        do {
            try await service.prepare()
            XCTFail("Expected a missing voice error")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechVoiceUnavailable)
        }
    }

    func testDirectSpeakFailsBeforeEnqueueWhenNoJapaneseVoiceIsInstalled() async {
        let driver = FakeSpeechSynthesizerDriver(voices: [])
        let service = AppleSpeechSynthesizer(driver: driver, language: "ja-JP")

        do {
            _ = try await service.speak("テスト")
            XCTFail("Expected a missing voice error")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechVoiceUnavailable)
        }

        XCTAssertTrue(driver.spokenTexts.isEmpty)
    }

    func testSpeakForwardsLifecycleInOrderAndPassesSelectedVoiceAndText() async throws {
        let driver = FakeSpeechSynthesizerDriver()
        let service = AppleSpeechSynthesizer(driver: driver, language: "ja-JP")

        let stream = try await service.speak("おはよう")
        let runID = try XCTUnwrap(driver.lastRunID)
        driver.emit(.didStart(runID: runID))
        driver.emit(.willSpeak(
            runID: runID,
            range: NSRange(location: 0, length: 2)
        ))
        driver.emit(.didFinish(runID: runID))

        let events = try await collect(stream)
        XCTAssertEqual(events, [
            .started,
            .willSpeak(range: 0..<2),
            .finished,
        ])
        XCTAssertEqual(driver.spokenTexts, ["おはよう"])
        XCTAssertEqual(driver.spokenVoiceIdentifiers, ["ja-jp"])
    }

    func testWillSpeakPreservesEmojiAdjacentUTF16Offsets() async throws {
        let driver = FakeSpeechSynthesizerDriver()
        let service = AppleSpeechSynthesizer(driver: driver)
        let stream = try await service.speak("猫🐈です")
        let runID = try XCTUnwrap(driver.lastRunID)

        driver.emit(.willSpeak(
            runID: runID,
            range: NSRange(location: 1, length: 2)
        ))
        driver.emit(.didFinish(runID: runID))

        let events = try await collect(stream)
        XCTAssertEqual(events, [
            .willSpeak(range: 1..<3),
            .finished,
        ])
    }

    func testDriverSpeakFailureMapsToSynthesisFailureAndClearsRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(
            speakOutcomes: [.failure, .success]
        )
        let service = AppleSpeechSynthesizer(driver: driver)

        do {
            _ = try await service.speak("失敗する発話")
            XCTFail("Expected the driver failure to throw")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }

        let stream = try await service.speak("次は話せる")
        let runID = try XCTUnwrap(driver.lastRunID)
        driver.emit(.didFinish(runID: runID))
        let events = try await collect(stream)
        XCTAssertEqual(events, [.finished])
        XCTAssertEqual(driver.spokenTexts, ["失敗する発話", "次は話せる"])
    }

    func testOverlappingSpeakIsRejectedInsteadOfQueued() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false])
        let service = AppleSpeechSynthesizer(driver: driver)
        let firstStream = try await service.speak("最初の発話")

        do {
            _ = try await service.speak("重なる発話")
            XCTFail("Expected overlapping speech to be rejected")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }

        XCTAssertEqual(driver.spokenTexts, ["最初の発話"])
        await service.stop()
        _ = try await collect(firstStream)
    }

    func testStopTrueWaitsForMatchingCancelAndConcurrentCallersJoinOneStop() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [true])
        let service = AppleSpeechSynthesizer(driver: driver)
        let stream = try await service.speak("長い文")
        let runID = try XCTUnwrap(driver.lastRunID)
        let completions = MainActorCounter()

        let first = Task { @MainActor in
            await service.stop()
            completions.increment()
        }
        let second = Task { @MainActor in
            await service.stop()
            completions.increment()
        }
        let third = Task { @MainActor in
            await service.stop()
            completions.increment()
        }

        let didRequestStop = await eventually { driver.stopCallCount == 1 }
        XCTAssertTrue(didRequestStop)
        XCTAssertEqual(completions.value, 0)
        driver.emit(.didCancel(runID: runID))
        await first.value
        await second.value
        await third.value
        await service.stop()

        let events = try await collect(stream)
        XCTAssertEqual(events, [.cancelled])
        XCTAssertEqual(completions.value, 3)
        XCTAssertEqual(driver.stopCallCount, 1)
        XCTAssertEqual(driver.stopBoundaries, [.immediate])
    }

    func testStopFalseImmediatelyCancelsAndFinishesStream() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false])
        let service = AppleSpeechSynthesizer(driver: driver)
        let stream = try await service.speak("長い文")

        await service.stop()

        let events = try await collect(stream)
        XCTAssertEqual(events, [.cancelled])
        XCTAssertEqual(driver.stopCallCount, 1)
    }

    func testCancellingConsumerStopsItsMatchingRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false])
        let service = AppleSpeechSynthesizer(driver: driver)
        let stream = try await service.speak("キャンセルする")
        let consumer = Task { @MainActor in
            do {
                for try await _ in stream {}
            } catch {
                // Consumer cancellation only needs to release the active utterance.
            }
        }
        await Task.yield()

        consumer.cancel()
        await consumer.value

        let didStop = await eventually { driver.stopCallCount == 1 }
        XCTAssertTrue(didStop)
    }

    func testDroppingUnconsumedStreamStopsItsMatchingRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false])
        let service = AppleSpeechSynthesizer(driver: driver)
        var stream: AsyncThrowingStream<SpeechEvent, Error>? = try await service.speak("破棄する")
        XCTAssertNotNil(stream)

        stream = nil

        let didStop = await eventually { driver.stopCallCount == 1 }
        XCTAssertTrue(didStop)
    }

    func testLateCallbackFromStoppedRunDoesNotAffectNewRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false])
        let service = AppleSpeechSynthesizer(driver: driver)
        let firstStream = try await service.speak("最初")
        let firstRunID = try XCTUnwrap(driver.lastRunID)
        await service.stop()
        _ = try await collect(firstStream)

        let secondStream = try await service.speak("次")
        let secondRunID = try XCTUnwrap(driver.lastRunID)
        XCTAssertNotEqual(firstRunID, secondRunID)

        driver.emit(.didCancel(runID: firstRunID))
        driver.emit(.didFinish(runID: firstRunID))
        await Task.yield()
        XCTAssertEqual(driver.stopCallCount, 1)

        driver.emit(.didStart(runID: secondRunID))
        driver.emit(.didFinish(runID: secondRunID))
        let secondEvents = try await collect(secondStream)
        XCTAssertEqual(secondEvents, [.started, .finished])
    }

    func testLateConsumerTerminationFromOldRunDoesNotStopNewRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false, false])
        let service = AppleSpeechSynthesizer(driver: driver)
        let firstStream = try await service.speak("最初")
        let firstRunID = try XCTUnwrap(driver.lastRunID)
        let consumerStarted = MainActorFlag()
        let consumer = Task { @MainActor in
            consumerStarted.set()
            do {
                for try await _ in firstStream {}
            } catch {
                // Cancellation is the behavior under test.
            }
        }
        let didStartConsumer = await eventually { consumerStarted.value }
        XCTAssertTrue(didStartConsumer)

        consumer.cancel()
        driver.emit(.didCancel(runID: firstRunID))
        let secondStream = try await service.speak("次")
        let secondRunID = try XCTUnwrap(driver.lastRunID)
        await consumer.value
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertFalse(driver.stoppedRunIDs.contains(secondRunID))
        driver.emit(.didFinish(runID: secondRunID))
        let secondEvents = try await collect(secondStream)
        XCTAssertEqual(secondEvents, [.finished])
    }

    func testLateNormalFinishTerminationFromOldRunDoesNotStopNewRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(stopResults: [false])
        let service = AppleSpeechSynthesizer(driver: driver)
        let firstStream = try await service.speak("最初")
        let firstRunID = try XCTUnwrap(driver.lastRunID)
        driver.emit(.didFinish(runID: firstRunID))

        let secondStream = try await service.speak("次")
        let secondRunID = try XCTUnwrap(driver.lastRunID)
        _ = try await collect(firstStream)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertFalse(driver.stoppedRunIDs.contains(secondRunID))
        driver.emit(.didFinish(runID: secondRunID))
        _ = try await collect(secondStream)
    }

    func testLiveDriverRejectsUnknownVoiceInsteadOfUsingDefaultVoice() {
        let driver = LiveSpeechSynthesizerDriver()

        XCTAssertThrowsError(
            try driver.speak(
                "テスト",
                voiceIdentifier: "missing-voice",
                runID: 1
            )
        )
    }
}

@MainActor
private final class FakeSpeechSynthesizerDriver: SpeechSynthesizerDriving {
    var onEvent: (@MainActor @Sendable (SpeechSynthesizerDriverEvent) -> Void)?

    private let voices: [SpeechVoiceDescriptor]
    private var speakOutcomes: [FakeSpeechSpeakOutcome]
    private var stopResults: [Bool]
    private(set) var availableVoicesCallCount = 0
    private(set) var spokenTexts: [String] = []
    private(set) var spokenVoiceIdentifiers: [String] = []
    private(set) var spokenRunIDs: [UInt64] = []
    private(set) var stopCallCount = 0
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private(set) var stoppedRunIDs: [UInt64] = []

    var lastRunID: UInt64? {
        spokenRunIDs.last
    }

    init(
        voices: [SpeechVoiceDescriptor] = [
            .init(identifier: "ja-jp", language: "ja-JP"),
        ],
        speakOutcomes: [FakeSpeechSpeakOutcome] = [],
        stopResults: [Bool] = []
    ) {
        self.voices = voices
        self.speakOutcomes = speakOutcomes
        self.stopResults = stopResults
    }

    func availableVoices() -> [SpeechVoiceDescriptor] {
        availableVoicesCallCount += 1
        return voices
    }

    func speak(
        _ text: String,
        voiceIdentifier: String,
        runID: UInt64
    ) throws {
        spokenTexts.append(text)
        spokenVoiceIdentifiers.append(voiceIdentifier)
        spokenRunIDs.append(runID)
        let outcome = speakOutcomes.isEmpty ? .success : speakOutcomes.removeFirst()
        if outcome == .failure {
            throw FakeSpeechSynthesizerError.enqueueFailed
        }
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCallCount += 1
        stopBoundaries.append(boundary)
        if let lastRunID {
            stoppedRunIDs.append(lastRunID)
        }
        return stopResults.isEmpty ? false : stopResults.removeFirst()
    }

    func emit(_ event: SpeechSynthesizerDriverEvent) {
        onEvent?(event)
    }
}

private enum FakeSpeechSpeakOutcome: Equatable {
    case success
    case failure
}

private enum FakeSpeechSynthesizerError: Error {
    case enqueueFailed
}

@MainActor
private final class MainActorCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@MainActor
private final class MainActorFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

@MainActor
private func collect(
    _ stream: AsyncThrowingStream<SpeechEvent, Error>,
    timeout: TimeInterval = 1
) async throws -> [SpeechEvent] {
    let didFinish = XCTestExpectation(description: "speech event stream terminated")
    let collector = Task { @MainActor in
        defer { didFinish.fulfill() }
        var events: [SpeechEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    let result = await XCTWaiter.fulfillment(of: [didFinish], timeout: timeout)
    guard result == .completed else {
        collector.cancel()
        _ = await collector.result
        throw BoundedCollectionError.timedOut
    }
    return try await collector.value
}

private enum BoundedCollectionError: Error {
    case timedOut
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
