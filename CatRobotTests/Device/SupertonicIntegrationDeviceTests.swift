import AVFAudio
import Darwin
import Foundation
import UIKit
import XCTest
@testable import CatRobot

@MainActor
final class SupertonicIntegrationDeviceTests: XCTestCase {
    private var records: [[String: Any]] = []
    private var pronunciationPreparation: [String: Any] = [:]
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
              let selectedStage = env["SUPER_STAGE"], ["voices", "fixed", "lifecycle", "pronunciation", "latency", "latency-cloud"].contains(selectedStage) else {
            throw XCTSkip("Use the dedicated device runner")
        }
        runID = id; stage = selectedStage; executionTimeAllowance = 3600
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupertonicIntegration/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try save()
        if stage == "latency" || stage == "latency-cloud" {
            try await ResponseLatencyDeviceBenchmark.waitForForeground()
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        let root = Bundle.main.resourceURL!
        let engine = SupertonicEngine(root: root.appendingPathComponent("Supertonic"), manifest: root.appendingPathComponent("supertonic-manifest.json"))
        if stage != "pronunciation" {
            let preparation = ProcessInfo.processInfo.systemUptime
            try await engine.prepare()
            print("SUPER_PREPARED \(ProcessInfo.processInfo.systemUptime - preparation)")
        }
        if stage == "latency" {
            try await ResponseLatencyDeviceBenchmark.run(engine: engine, runID: runID, revision: revision,
                coolDown: { try await self.coolDown() }, sample: { self.sample() },
                record: { row in self.records.append(row); try self.save() })
        } else if stage == "latency-cloud" {
            try await ResponseLatencyDeviceBenchmark.cloud(engine: engine, runID: runID, revision: revision,
                coolDown: { try await self.coolDown() }, sample: { self.sample() },
                record: { row in self.records.append(row); try self.save() })
        } else if stage == "voices" {
            for voice in SpeechVoicePreset.allCases {
                let fixture = SupertonicLatencyFixture(id: voice.rawValue, text: "こんにちは。今日も一緒に遊ぼうね。", prompt: "")
                try await trial(fixture, repetition: 0, voice: voice, engine: engine)
            }
        } else if stage == "fixed" {
            // Separate warmup; excluded from recorded timings.
            let warmup = SupertonicSentenceSpeaker(engine: engine, voice: { .f1 })
            let stream = try await warmup.speak("こんにちは。")
            for try await _ in stream {}
            for repetition in 0..<3 {
                for fixture in SupertonicLatencyFixture.all {
                    try await trial(fixture, repetition: repetition, voice: .f1, engine: engine)
                }
            }
        } else if stage == "pronunciation" {
            try await pronunciation(engine)
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
    private func trial(_ fixture: SupertonicLatencyFixture, repetition: Int,
                       voice: SpeechVoicePreset, engine: SupertonicEngine, reply: (any ReplyGenerating)? = nil) async throws {
        let cooldown = try await coolDown()
        let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { voice })
        try await speaker.prepare()
        var inputs: [[String: Any]] = []
        var synthesis: [[String: Any]] = []
        speaker.onInput = { original, spoken in inputs.append(["original": original, "spoken": spoken, "processedChunks": SpeechTextAudit(input: spoken).processedChunks]) }
        speaker.onSynthesis = { ordinal, point in synthesis.append(["at": ProcessInfo.processInfo.systemUptime, "point": point, "sentenceOrdinal": ordinal]) }
        let session = AVAudioSession.sharedInstance()
        print("SUPER_AUDIO beforeActivation state=\(UIApplication.shared.applicationState.rawValue) category=\(session.category.rawValue) rate=\(session.sampleRate)")
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { ProcessInfo.processInfo.systemUptime })
        let sut = ReplyPlaybackCoordinator(reply: reply ?? FixedIntegrationReply(text: fixture.text), speaker: speaker)
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
        records.append(["runID": runID, "sourceRevision": revision, "stage": stage, "mode": "sentencePrefetch",
                        "fixture": fixture.id, "repetition": repetition, "voice": voice.rawValue,
                        "applicationStateRawValue": UIApplication.shared.applicationState.rawValue,
                        "audioCategory": session.category.rawValue, "audioSampleRate": session.sampleRate,
                        "thermalBefore": before, "thermalAfter": String(describing: ProcessInfo.processInfo.thermalState),
                        "cooldownSeconds": cooldown, "footprintSamples": samples, "events": events,
                        "synthesis": synthesis, "inputs": inputs, "response": final, "outcome": outcome, "error": failure])
        try save()
        print("SUPER_TRIAL \(stage) \(fixture.id) sentencePrefetch \(repetition) \(outcome)")
        if outcome != "success" { XCTFail("\(fixture.id): \(failure)") }
    }
    /// Fixed original inputs have no old iPhone/Bluetooth substitutions, so their
    /// raw input is also the legacy normalizer output. No old converter is retained.
    private func pronunciation(_ engine: SupertonicEngine) async throws {
        let frontend = JapanesePronunciationService.shared
        let before = sample()
        let coldStart = ProcessInfo.processInfo.systemUptime
        try await frontend.prepare()
        let coldSeconds = ProcessInfo.processInfo.systemUptime - coldStart
        let after = sample()
        pronunciationPreparation = ["seconds": coldSeconds, "before": before, "after": after,
                                    "measuredBeforeModelPreparation": true]
        try save()
        let modelStart = ProcessInfo.processInfo.systemUptime
        try await engine.prepare()
        print("SUPER_PREPARED \(ProcessInfo.processInfo.systemUptime - modelStart)")
        let fixtures = [
            ("plus", "+ボタンを押してね。"),
            ("youtube", "YouTubeを見よう。"),
            ("counter", "3人で25個を分けるよ。"),
            ("greeting", "こんにちは。今日も一緒に遊ぼうね。"),
            ("service-plus", "Disney+を見よう。"),
            ("ambiguous", "辛いカレーが好きだよ。"),
            ("temperature", "今日は25℃だよ。"),
            ("clock", "7:30に起こしてね。"),
        ]
        for (id, original) in fixtures {
            let cooldown = try await coolDown()
            let conversionStart = ProcessInfo.processInfo.systemUptime
            let spoken = try await frontend.normalize(original)
            let conversionSeconds = ProcessInfo.processInfo.systemUptime - conversionStart
            var outputs: [[String: Any]] = []
            for (variant, text) in [("original", original), ("jpreprocess", spoken)] {
                let started = ProcessInfo.processInfo.systemUptime
                let pcm = try await engine.synthesize(text: text, voiceID: "F1", steps: 8)
                try pcm.validate()
                let synthesisSeconds = ProcessInfo.processInfo.systemUptime - started
                let filename = "\(id)-\(variant).wav"
                try writeWAV(pcm, to: directory.appendingPathComponent(filename))
                outputs.append(["variant": variant, "text": text, "file": filename,
                                "synthesisSeconds": synthesisSeconds,
                                "durationSeconds": Double(pcm.samples.count) / pcm.sampleRate,
                                "processedChunks": SpeechTextAudit(input: text).processedChunks])
            }
            records.append(["runID": runID, "sourceRevision": revision, "stage": stage,
                "mode": "pronunciationComparison", "fixture": id, "voice": "F1", "steps": 8,
                "original": original, "spoken": spoken, "outputs": outputs,
                "coldPreparationSeconds": coldSeconds, "conversionSeconds": conversionSeconds,
                "beforeDictionary": before, "afterDictionary": after,
                "footprintSamples": [before, after, sample()], "cooldownSeconds": cooldown,
                "thermalAfter": String(describing: ProcessInfo.processInfo.thermalState),
                "audibleAssessment": "pending", "outcome": "success"])
            try save()
            print("SUPER_PRONUNCIATION \(id) \(conversionSeconds) \(spoken)")
        }
        // Exercise the production speaker as well as the directly saved A/B PCM.
        try await trial(.init(id: "pronunciation-speaker", text: "｢+ボタン｣でYouTubeを開くよ。", prompt: ""),
                        repetition: 0, voice: .f1, engine: engine)
    }
    private func writeWAV(_ pcm: SpeechPCM, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw ConversationServiceError.speechSynthesisFailed }
        buffer.frameLength = AVAudioFrameCount(pcm.samples.count)
        pcm.samples.withUnsafeBufferPointer { values in channel.update(from: values.baseAddress!, count: values.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func lifecycle(_ engine: SupertonicEngine) async throws {
        for action in ["generating", "stop", "background", "interruption", "routeChange"] {
            _ = try await coolDown()
            let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { .f1 })
            let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker)
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
        var payload: [String: Any] = ["schemaVersion": 1, "runID": runID, "sourceRevision": revision, "stage": stage,
            "device": hardware, "OS": UIDevice.current.systemVersion,
            "route": session.currentRoute.outputs.map { $0.portType.rawValue }, "volume": session.outputVolume,
            "connection": ProcessInfo.processInfo.environment["SUPER_CONNECTION"] ?? "unknown",
            "pronunciationPreparation": pronunciationPreparation, "records": records]
        if stage == "latency" { payload["latencyConfiguration"] = ResponseLatencyDeviceBenchmark.configuration }
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
}
