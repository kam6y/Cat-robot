import AVFAudio
import Foundation
import UIKit
import XCTest
@testable import CatRobot

@MainActor
struct ResponseLatencyDeviceBenchmark {
    struct Change: Sendable { let milliseconds: Int; let text: String }
    struct Fixture: Sendable {
        let id: String
        let changes: [Change]
        let finishMilliseconds: Int
        let requiresHit: Bool
        var final: String { changes.last!.text }
    }
    static let fixtures: [Fixture] = [
        .init(id: "immediate", changes: [.init(milliseconds: 0, text: "こんにちは。")], finishMilliseconds: 0, requiresHit: false),
        .init(id: "delayed", changes: [.init(milliseconds: 0, text: "こんにちは。")], finishMilliseconds: 700, requiresHit: true),
        .init(id: "two-sentence", changes: [.init(milliseconds: 0, text: "こんにちは。"), .init(milliseconds: 300, text: "こんにちは。今日も遊ぼうね。")], finishMilliseconds: 700, requiresHit: true),
        .init(id: "quoted", changes: [.init(milliseconds: 0, text: "「3人で遊ぼうね。」")], finishMilliseconds: 900, requiresHit: true),
        .init(id: "whitespace", changes: [.init(milliseconds: 0, text: "こんにちは。"), .init(milliseconds: 200, text: "こんにちは。 \n")], finishMilliseconds: 700, requiresHit: true),
        .init(id: "changed", changes: [.init(milliseconds: 0, text: "仮の返答。"), .init(milliseconds: 200, text: "本当の返答。")], finishMilliseconds: 200, requiresHit: false),
        .init(id: "punctuation", changes: [.init(milliseconds: 0, text: "えっ！"), .init(milliseconds: 200, text: "えっ！？")], finishMilliseconds: 200, requiresHit: false),
        .init(id: "changed-long", changes: [.init(milliseconds: 0, text: "今日は窓のそばで日なたぼっこをしながら、ゆっくりお話ししようね。"), .init(milliseconds: 200, text: "うん、遊ぼうね。")], finishMilliseconds: 200, requiresHit: false)
    ]
    static var configuration: [String: Any] {
        ["repetitions": 3, "fixtures": fixtures.map { ["id": $0.id, "requiresHit": $0.requiresHit] as [String: Any] },
         "clock": "monotonic request to PCM playback callback; not acoustic measurement"]
    }

    static func run(engine: SupertonicEngine, runID: String, revision: String,
                    coolDown: @MainActor () async throws -> Double,
                    sample: @escaping @MainActor () -> [String: Any],
                    record: @MainActor ([String: Any]) throws -> Void) async throws {
        let voice = SpeechVoiceSettings().selected
        let warmup = SupertonicSentenceSpeaker(engine: engine, voice: { voice })
        try await warmup.prepare()
        for try await _ in try await warmup.speak("こんにちは。") {}
        for repetition in 0..<3 {
            for (index, fixture) in fixtures.enumerated() {
                let order = (repetition + index).isMultiple(of: 2) ? [false, true] : [true, false]
                for enabled in order {
                    let cooldown = try await coolDown()
                    let row = try await trial(engine: engine, reply: Replay(fixture: fixture), prompt: "固定snapshotの比較", expected: fixture.final,
                                              fixture: fixture.id, repetition: repetition, enabled: enabled, voice: voice,
                                              runID: runID, revision: revision, stage: "latency", requiresHit: fixture.requiresHit,
                                              cooldown: cooldown, sample: sample)
                    try record(row)
                }
            }
        }
    }

    static func cloud(engine: SupertonicEngine, runID: String, revision: String,
                      coolDown: @MainActor () async throws -> Double,
                      sample: @escaping @MainActor () -> [String: Any],
                      record: @MainActor ([String: Any]) throws -> Void) async throws {
        let settings = ConversationModelSettings().configuration
        let voice = SpeechVoiceSettings().selected
        let auth = ClaudeAuthConfiguration.live()
        guard auth != .missing else { throw XCTSkip("Current app has no Claude credential") }
        let service = ClaudeConversationService(factory: ClaudeSessionFactory(auth: auth),
            memoryStore: InMemoryConversationMemoryStore(), longTermMemory: LongTermMemoryManager(store: InMemoryLongTermMemoryStore()),
            tools: RobotConversationToolProvider(motion: NoopRobotMotionController()), configuration: { settings }, usage: ConversationUsageSpy())
        let availability = await service.availability()
        guard availability == .available else { throw ConversationServiceError.modelUnavailable(availability) }
        await service.prewarm()
        let prompts = ["猫ちゃん、こんにちは。短く返事して。", "猫ちゃん、家で何をして遊ぼうか。", "猫ちゃん、うれしい気分を短く教えて。"]
        for (index, prompt) in prompts.enumerated() {
            let cooldown = try await coolDown()
            var row = try await trial(engine: engine, reply: service, prompt: prompt, expected: nil,
                                      fixture: "cloud-\(index)", repetition: 0, enabled: true, voice: voice,
                                      runID: runID, revision: revision, stage: "latency-cloud", requiresHit: false,
                                      cooldown: cooldown, sample: sample)
            row["model"] = settings.model.rawValue
            row["effort"] = settings.effort.rawValue
            row["memoryScope"] = "isolated test-only memory and usage; robot/camera controllers are noops"
            try record(row)
        }
    }

    private static func trial(engine: SupertonicEngine, reply: any ReplyGenerating, prompt: String, expected: String?,
                              fixture: String, repetition: Int, enabled: Bool, voice: SpeechVoicePreset,
                              runID: String, revision: String, stage: String, requiresHit: Bool, cooldown: Double,
                              sample: @escaping @MainActor () -> [String: Any]) async throws -> [String: Any] {
        let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { voice })
        try await speaker.prepare()
        var inputs: [[String: Any]] = []
        var synthesis: [[String: Any]] = []
        speaker.onInput = { original, spoken in inputs.append(["original": original, "spoken": spoken]) }
        speaker.onSynthesis = { ordinal, point in synthesis.append(["sentenceOrdinal": ordinal, "point": point, "at": ProcessInfo.processInfo.systemUptime]) }
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { ProcessInfo.processInfo.systemUptime })
        let coordinator = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, prepareFirstSentence: enabled)
        let before = String(describing: ProcessInfo.processInfo.thermalState)
        var samples = [sample()]
        let sampler = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                samples.append(sample())
            }
        }
        var timedOut = false
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(90)); timedOut = true; await coordinator.cancelAndWait() } catch {}
        }
        var response = "", outcome = "success", failure = ""
        do { response = try await coordinator.run(prompt: prompt, trace: trace, onUpdate: { _ in }) }
        catch {
            outcome = timedOut ? "timeout" : "failed"
            failure = (error as? ConversationServiceError).map { String(describing: $0) } ?? String(describing: type(of: error))
        }
        deadline.cancel(); await deadline.value
        sampler.cancel(); await sampler.value; samples.append(sample())
        await speaker.stop()
        if let expected, response != expected { outcome = "failed"; failure = "responseMismatch" }
        if outcome != "success" { XCTFail("Latency \(fixture): \(failure)") }
        let events = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sink.events))
        let mode = enabled ? "prepared" : "baseline"
        print("LATENCY_TRIAL \(fixture) \(mode) \(repetition) \(outcome)")
        return ["runID": runID, "sourceRevision": revision, "stage": stage, "fixture": fixture, "repetition": repetition,
                "mode": mode, "requiresPreparationHit": requiresHit, "voice": voice.rawValue, "steps": 8, "threads": 2, "speed": 1.05,
                "applicationStateRawValue": UIApplication.shared.applicationState.rawValue,
                "thermalBefore": before, "thermalAfter": String(describing: ProcessInfo.processInfo.thermalState),
                "cooldownSeconds": cooldown, "footprintSamples": samples,
                "events": events, "synthesis": synthesis, "inputs": inputs, "response": response, "outcome": outcome, "error": failure]
    }

    private struct Replay: ReplyGenerating {
        let fixture: Fixture
        var supportsStableReplyPrefix: Bool { true }
        func prewarm() async {}
        func reset() async {}
        func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    for change in fixture.changes {
                        try await clock.sleep(until: start.advanced(by: .milliseconds(change.milliseconds)))
                        try Task.checkCancellation()
                        pair.continuation.yield(change.text)
                    }
                    try await clock.sleep(until: start.advanced(by: .milliseconds(fixture.finishMilliseconds)))
                    try Task.checkCancellation()
                    pair.continuation.finish()
                } catch { pair.continuation.finish(throwing: error) }
            }
            pair.continuation.onTermination = { _ in task.cancel() }
            return pair.stream
        }
    }
}
