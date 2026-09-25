import Foundation
import Observation
import XCTest
@testable import CatRobot

@MainActor
final class PlaybackIntegrationHarness {
    let infrastructure = ConversationHarness()
    let reply = ControlledReply()
    let speaker: ControlledSpeaker
    let viewModel: ConversationViewModel
    let traces = RecordingReplyTraceSink()
    var recognizer: FakeSpeechRecognizer { infrastructure.recognizer }
    init(service: (any ReplyGenerating)? = nil,
         memory: (any ConversationMemoryManaging)? = nil,
         speaker: ControlledSpeaker = ControlledSpeaker(), sentenceSpeaker: (any SpeechSpeaking)? = nil, mode: ReplyPlaybackMode = .firstSentence) {
        self.speaker = speaker
        let base = infrastructure
        viewModel = ConversationViewModel(dependencies: ConversationDependencies(
            microphonePermission: base.microphone, modelAvailability: base.modelAvailability,
            recognizer: base.recognizer, classifier: base.classifier,
            reply: service ?? reply, speaker: sentenceSpeaker ?? speaker, audioSession: base.audio,
            latency: base.latency, replyTraceSink: traces, replyPlaybackMode: mode,
            memory: memory ?? UnsupportedConversationMemoryManager(), now: { base.now.value }))
    }
    func waitForPhase(_ phase: ConversationPhase) async { await waitForState { $0.phase == phase } }
    func waitForState(_ predicate: @escaping @MainActor (ConversationViewState) -> Bool) async {
        await withCheckedContinuation { continuation in observe(predicate, continuation) }
    }
    private func observe(_ predicate: @escaping @MainActor (ConversationViewState) -> Bool,
                         _ continuation: CheckedContinuation<Void, Never>) {
        if predicate(viewModel.viewState) { continuation.resume(); return }
        withObservationTracking { _ = viewModel.viewState } onChange: {
            Task { @MainActor in self.observe(predicate, continuation) }
        }
    }
    func beginVoiceTurn(_ text: String = "猫ちゃん、二文で答えて") async -> Task<Void, Never> {
        await viewModel.startConversation()
        infrastructure.now.set(10)
        await recognizer.emit(.finalized(text))
        await waitForState { $0.provisionalTranscript == text }
        infrastructure.now.set(11.2)
        return Task { await self.viewModel.flushSegmentation(at: 11.2) }
    }
}

@MainActor
final class ReplyPlaybackIntegrationTests: XCTestCase {
    func testTypedAndVoiceWaitForGenerationAndBothSpeechParts() async {
        for voice in [false, true] {
            let harness = PlaybackIntegrationHarness()
            let run: Task<Void, Never>
            if voice { run = await harness.beginVoiceTurn() }
            else { run = Task { await harness.viewModel.submitTypedText("二文で答えて") } }
            await harness.reply.waitUntilRequested()
            await harness.reply.yield("こんにちは。元")
            await harness.speaker.waitUntilCallCount(1)
            XCTAssertEqual(harness.viewModel.viewState.phase, .thinking, "Enqueued speech has not started")
            await harness.speaker.emit(.started)
            await harness.waitForPhase(.speaking)
            let startsDuringFirst = await harness.recognizer.startCount
            XCTAssertEqual(startsDuringFirst, voice ? 1 : 0)
            await harness.reply.yield("こんにちは。元気です。")
            await harness.waitForState { $0.caption == "こんにちは。元気です。" }
            await harness.speaker.complete()
            await harness.waitForPhase(.thinking)
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
            let startsDuringGeneration = await harness.recognizer.startCount
            XCTAssertEqual(startsDuringGeneration, startsDuringFirst)
            await harness.reply.finish()
            await harness.speaker.waitUntilCallCount(2)
            await harness.speaker.emit(.started)
            await harness.waitForPhase(.speaking)
            await harness.speaker.complete()
            await run.value
            let startsAfter = await harness.recognizer.startCount
            XCTAssertEqual(startsAfter, voice ? 2 : 0)
            XCTAssertEqual(harness.viewModel.viewState.phase, voice ? .listening : .paused)
            let texts = await harness.speaker.texts
            XCTAssertEqual(texts, ["こんにちは。", "元気です。"])
            XCTAssertEqual(harness.traces.events.last?.outcome, .success)
            await harness.viewModel.shutdown()
        }
    }

    func testBackgroundAndRouteChangeCancelEarlySpeechAndRejectLateEvents() async {
        for routeChange in [false, true] {
            let harness = PlaybackIntegrationHarness()
            let run = await harness.beginVoiceTurn()
            await harness.reply.waitUntilRequested()
            await harness.reply.yield("最初。続き")
            await harness.speaker.waitUntilCallCount(1)
            await harness.speaker.emit(.started)
            await harness.waitForPhase(.speaking)
            if routeChange { await harness.viewModel.handleAudioSessionEvent(.routeChanged) }
            else { await harness.viewModel.sceneBecameInactive() }
            await run.value
            let pausedCaption = harness.viewModel.viewState.caption
            await harness.reply.yield("古い字幕。続き")
            await harness.reply.finish()
            await harness.speaker.emit(.willSpeak(range: 0..<1), run: 0)
            await harness.speaker.complete(run: 0)
            XCTAssertEqual(harness.viewModel.viewState.phase, .paused)
            XCTAssertEqual(harness.viewModel.viewState.caption, pausedCaption)
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
            let starts = await harness.recognizer.startCount
            XCTAssertEqual(starts, 1)
            let texts = await harness.speaker.texts
            XCTAssertEqual(texts, ["最初。"])
            await harness.viewModel.shutdown()
        }
    }

    func testSpeechFailureKeepsSpeechErrorAndClosesMouth() async {
        let harness = PlaybackIntegrationHarness()
        let run = Task { await harness.viewModel.submitTypedText("質問") }
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("最初。続き")
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        await harness.waitForPhase(.speaking)
        await harness.speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
        await run.value
        XCTAssertEqual(harness.viewModel.viewState.errorMessage,
                       ConversationErrorPresentation(.speechSynthesisFailed).message)
        XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 0)
        await harness.viewModel.shutdown()
    }
}
