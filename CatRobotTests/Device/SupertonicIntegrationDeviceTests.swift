import AVFAudio
import Darwin
import Foundation
import UIKit
import XCTest
@testable import CatRobot

@MainActor
final class SupertonicIntegrationDeviceTests: XCTestCase {
    private var records: [[String: Any]] = []
    private var runID = ""
    private var stage = ""
    private var directory: URL!
    private var revision: String { Bundle.main.object(forInfoDictionaryKey: "CatRobotSourceRevision") as? String ?? "unknown" }

    func testSelectedStage() async throws {
#if targetEnvironment(simulator) || !DEBUG
        throw XCTSkip("Explicit iPhone integration test required")
#else
        let env = ProcessInfo.processInfo.environment
        guard env["SUPER_INTEGRATION_TESTS"] == "1", let id = env["SUPER_RUN_ID"], UUID(uuidString: id) != nil,
              let selectedStage = env["SUPER_STAGE"], ["voices", "fixed", "gemma", "lifecycle", "offline"].contains(selectedStage) else {
            throw XCTSkip("Use the dedicated device runner")
        }
        runID = id; stage = selectedStage; executionTimeAllowance = 3600
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupertonicIntegration/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try save()
        if stage == "offline" {
            print("SUPER_OFFLINE_WAITING \(id)")
            let gate = directory.appendingPathComponent("offline-confirmed.txt")
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                if (try? String(contentsOf: gate, encoding: .utf8)) == "offline-user-confirmed\n" { break }
                try await Task.sleep(for: .seconds(1))
            }
            guard (try? String(contentsOf: gate, encoding: .utf8)) == "offline-user-confirmed\n" else { throw XCTSkip("Offline state not confirmed") }
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        let root = Bundle.main.resourceURL!
        let engine = SupertonicEngine(root: root.appendingPathComponent("Supertonic"), manifest: root.appendingPathComponent("supertonic-manifest.json"))
        let preparation = ProcessInfo.processInfo.systemUptime
        try await engine.prepare()
        print("SUPER_PREPARED \(ProcessInfo.processInfo.systemUptime - preparation)")
        if stage == "voices" {
            for voice in SpeechVoicePreset.allCases {
                let fixture = SupertonicLatencyFixture(id: voice.rawValue, text: "こんにちは。今日も一緒に遊ぼうね。", prompt: "")
                try await trial(fixture, mode: .firstSentence, repetition: 0, voice: voice, engine: engine)
            }
        } else if stage == "fixed" {
            // Separate warmup; excluded from recorded timings.
            let warmup = SupertonicSentenceSpeaker(engine: engine, voice: { .f1 })
            let stream = try await warmup.speak("こんにちは。")
            for try await _ in stream {}
            let modes: [ReplyPlaybackMode] = [.firstSentence, .sentenceSerial, .sentencePrefetch]
            for repetition in 0..<3 {
                let rotated = Array(modes[repetition...] + modes[..<repetition])
                for fixture in SupertonicLatencyFixture.all {
                    for mode in rotated { try await trial(fixture, mode: mode, repetition: repetition, voice: .f1, engine: engine) }
                }
            }
        } else if stage == "gemma" || stage == "offline" {
            let runtime = LiteRTGemmaRuntime()
            let warmup = GemmaConversationService(runtime: runtime, memoryStore: InMemoryConversationMemoryStore())
            await warmup.prewarm()
            let modes: [ReplyPlaybackMode] = [.firstSentence, .sentencePrefetch]
            for repetition in 0..<(stage == "offline" ? 1 : 3) {
                for fixture in (stage == "offline" ? [SupertonicLatencyFixture.all[4]] : SupertonicLatencyFixture.all) {
                    for mode in (repetition.isMultiple(of: 2) ? modes : modes.reversed()) {
                        let service = GemmaConversationService(runtime: runtime, memoryStore: InMemoryConversationMemoryStore())
                        try await trial(fixture, mode: mode, repetition: repetition, voice: .f1, engine: engine, reply: service)
                    }
                }
            }
        } else if stage == "lifecycle" {
            try await lifecycle(engine)
        }
        try save()
        XCTAssertTrue(records.allSatisfy { $0["outcome"] as? String == "success" })
#endif
    }
    private func coolDown() async throws -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            guard ProcessInfo.processInfo.systemUptime - start < 600 else { throw ConversationServiceError.modelBusy }
            print("SUPER_COOLDOWN \(stage)")
            try await Task.sleep(for: .seconds(10))
        }
        return ProcessInfo.processInfo.systemUptime - start
    }
    private func trial(_ fixture: SupertonicLatencyFixture, mode: ReplyPlaybackMode, repetition: Int,
                       voice: SpeechVoicePreset, engine: SupertonicEngine, reply: (any ReplyGenerating)? = nil) async throws {
        let cooldown = try await coolDown()
        let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { voice })
        try await speaker.prepare()
        var inputs: [[String: Any]] = []
        var synthesis: [[String: Any]] = []
        speaker.onInput = { original, spoken in inputs.append(["original": original, "spoken": spoken, "processedChunks": SpeechTextAudit(input: spoken).processedChunks]) }
        speaker.onSynthesis = { ordinal, point in synthesis.append(["at": ProcessInfo.processInfo.systemUptime, "point": point, "sentenceOrdinal": ordinal]) }
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { ProcessInfo.processInfo.systemUptime })
        let sut = ReplyPlaybackCoordinator(reply: reply ?? FixedIntegrationReply(text: fixture.text), speaker: speaker, mode: mode)
        let before = String(describing: ProcessInfo.processInfo.thermalState)
        var samples: [[String: Any]] = [sample()]
        let sampler = Task { while !Task.isCancelled { do { try await Task.sleep(for: .milliseconds(100)) } catch { break }; samples.append(sample()) } }
        var timeout = false
        let deadline = Task { do { try await Task.sleep(for: .seconds(90)); timeout = true; await sut.cancelAndWait() } catch {} }
        var final = ""
        var outcome = "success"
        var failure = ""
        do { final = try await sut.run(prompt: fixture.prompt, trace: trace, onUpdate: { _ in }) }
        catch { outcome = timeout ? "timeout" : "failed"; failure = String(describing: error) }
        deadline.cancel(); await deadline.value
        sampler.cancel(); await sampler.value; samples.append(sample())
        await speaker.stop()
        let events = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sink.events))
        records.append(["runID": runID, "sourceRevision": revision, "stage": stage, "mode": mode.rawValue,
                        "fixture": fixture.id, "repetition": repetition, "voice": voice.rawValue,
                        "thermalBefore": before, "thermalAfter": String(describing: ProcessInfo.processInfo.thermalState),
                        "cooldownSeconds": cooldown, "footprintSamples": samples, "events": events,
                        "synthesis": synthesis, "inputs": inputs, "response": final, "outcome": outcome, "error": failure])
        try save()
        print("SUPER_TRIAL \(stage) \(fixture.id) \(mode.rawValue) \(repetition) \(outcome)")
        if outcome != "success" { XCTFail("\(fixture.id): \(failure)") }
    }
    private func lifecycle(_ engine: SupertonicEngine) async throws {
        for action in ["generating", "stop", "background", "interruption", "routeChange"] {
            _ = try await coolDown()
            let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { .f1 })
            let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker, mode: .sentencePrefetch)
            let run = Task { await harness.viewModel.submitTypedText("試験用") }
            await harness.reply.waitUntilRequested()
            if action != "generating" {
                await harness.reply.yield(SupertonicLatencyFixture.all[2].text)
                let deadline = Date().addingTimeInterval(30)
                while !harness.traces.events.contains(where: { $0.point == .speechStarted }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(harness.traces.events.contains { $0.point == .speechStarted })
            }
            if action == "interruption" { await harness.viewModel.handleAudioSessionEvent(.interruptionBegan) }
            else if action == "routeChange" { await harness.viewModel.handleAudioSessionEvent(.routeChanged) }
            else { await harness.viewModel.sceneBecameInactive() }
            await run.value
            let paused = harness.viewModel.viewState.phase == .paused
            XCTAssertTrue(paused)
            let events = try JSONSerialization.jsonObject(with: JSONEncoder().encode(harness.traces.events))
            records.append(["runID": runID, "stage": stage, "sourceRevision": revision, "mode": "sentencePrefetch", "fixture": action,
                            "outcome": paused ? "success" : "failed", "events": events, "controlSource": "injected lifecycle event on physical device"])
            try save()
            await harness.viewModel.shutdown()
            // A stopped operation must not poison the next real synthesis.
            let replay = try await speaker.speak("再開できたよ。")
            for try await _ in replay {}
        }
    }
    private func sample() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ["at": ProcessInfo.processInfo.systemUptime, "bytes": result == KERN_SUCCESS ? NSNumber(value: info.phys_footprint) : NSNull()]
    }
    private func save() throws {
        let session = AVAudioSession.sharedInstance()
        var uts = utsname(); uname(&uts)
        let hardware = withUnsafePointer(to: &uts.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let payload: [String: Any] = ["schemaVersion": 1, "runID": runID, "sourceRevision": revision, "stage": stage,
            "device": hardware, "OS": UIDevice.current.systemVersion,
            "route": session.currentRoute.outputs.map { $0.portType.rawValue }, "volume": session.outputVolume,
            "connection": ProcessInfo.processInfo.environment["SUPER_CONNECTION"] ?? "unknown", "records": records]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
}
