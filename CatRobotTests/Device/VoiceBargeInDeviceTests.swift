import AVFAudio
import Darwin
import Foundation
import UIKit
import XCTest
@testable import CatRobot

/// 実機だけで動く opt-in の、声での割り込みハーネス（scripts/run_voice_barge_in_device_test.py から起動する）。
/// audio 層を本番と同じ組み立て（共有 engine + voice processing、AppleSpeechRecognizer、PCMPlayer、Supertonic）で動かし、
/// 猫の既知発話だけ（self-only: 誤割り込みの有無）と、Mac から流す既知の外部発話（external: 検出→停止の時間と収録の継続）を記録する。
/// 音響指標は閾値判定せずデータとして残す。テストの成否はハーネスの整合性（結果の書き出し、trial 数、echo cancellation の有効化）だけ。
/// 認識した生のテキストは保存しない（bool / count / timing のみ）。VM との統合は simulator の fake で検証する。
@MainActor
final class VoiceBargeInDeviceTests: XCTestCase {
    private enum Stage: String { case selfOnly = "self-only", external }

    /// 猫の既知発話。external では Mac 側の poll（1s）+ devicectl copy + say の起動を待てる長さにする。
    private static let catSentences = [
        "こんにちは。今日もいい天気だね。", "公園に行って、一緒に遊ぼうか。", "お昼ごはんは何にしようかな。",
        "午後はひなたでお昼寝がしたいな。", "夕方には星を見に行こうよ。", "それから一緒に歌を歌おうね。",
        "明日はどんな一日になるかな。", "楽しみなことがたくさんあるね。",
    ]
    /// Mac が `say -v Kyoko` で流す既知の外部発話（runner と同じ文）。
    private static let externalFixture = "待って、明日の話をして"
    private static let trialsPerStage = 3

    private var runID = ""
    private var stage = Stage.selfOnly
    private var directory: URL!
    private var echoCancelled = false
    private var records: [[String: Any]] = []
    private var revision: String { Bundle.main.object(forInfoDictionaryKey: "CatRobotSourceRevision") as? String ?? "unknown" }

    /// Uses the real input engine and recognizer with local fakes for replies: no cloud request or saved transcript.
    func testVoiceSessionStartsAndResumesAfterThreeTapPauses() async throws {
#if targetEnvironment(simulator) || !DEBUG
        throw XCTSkip("Opt-in iPhone audio lifecycle test required")
#else
        let env = ProcessInfo.processInfo.environment
        guard env["TAP_RESUME_DEVICE_TESTS"] == "1", env["SUPER_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set TAP_RESUME_DEVICE_TESTS and SUPER_INTEGRATION_TESTS for the device lifecycle check")
        }
        let engine = ConversationAudioEngine(driver: LiveAudioEngineDriver())
        let session = AppleAudioSessionController(engine: engine)
        let recognizer = AppleSpeechRecognizer(engine: engine)
        let base = ConversationHarness(classification: .notAddressed)
        let viewModel = ConversationViewModel(dependencies: ConversationDependencies(
            microphonePermission: base.microphone, modelAvailability: base.modelAvailability,
            recognizer: recognizer, classifier: base.classifier, reply: base.reply,
            speaker: base.speaker, audioSession: session, latency: base.latency
        ))
        await viewModel.startConversation()
        for cycle in 0...3 {
            // Give asynchronous AVAudioSession notifications time to reach the VM after activation.
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(viewModel.viewState.phase, .listening, "startup/resume cycle \(cycle)")
            XCTAssertTrue(engine.isCapturing, "capture must remain active after startup notifications")
            if viewModel.viewState.phase != .listening { break }
            if cycle < 3 {
                await viewModel.toggleListening()
                XCTAssertEqual(viewModel.viewState.phase, .paused)
                XCTAssertFalse(engine.isActive)
                await viewModel.toggleListening()
            }
        }
        await viewModel.sceneBecameInactive()
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(viewModel.viewState.isAwaitingTapToResume, "Teardown configuration must preserve automatic resume intent")
        await viewModel.startConversation()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(viewModel.viewState.phase, .listening)
        await viewModel.shutdown()
        await recognizer.shutdown()
#endif
    }

    func testSelectedStage() async throws {
#if targetEnvironment(simulator) || !DEBUG
        throw XCTSkip("Attended iPhone voice barge-in test required")
#else
        let env = ProcessInfo.processInfo.environment
        guard env["VOICE_BARGE_TESTS"] == "1", env["SUPER_INTEGRATION_TESTS"] == "1",
              let id = env["VOICE_BARGE_RUN_ID"], UUID(uuidString: id) != nil,
              let selected = env["VOICE_BARGE_STAGE"], let stage = Stage(rawValue: selected) else {
            throw XCTSkip("Use scripts/run_voice_barge_in_device_test.py")
        }
        runID = id; self.stage = stage; executionTimeAllowance = 900
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceBargeIn/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try save()

        // 本番の ConversationComposition と同じ配線。
        let audioEngine = ConversationAudioEngine(driver: LiveAudioEngineDriver())
        let session = AppleAudioSessionController(engine: audioEngine)
        let recognizer = AppleSpeechRecognizer(engine: audioEngine)
        let resources = Bundle.main.resourceURL!
        let supertonic = SupertonicEngine(root: resources.appendingPathComponent("Supertonic"),
                                          manifest: resources.appendingPathComponent("supertonic-manifest.json"))
        let speaker = SupertonicSentenceSpeaker(engine: supertonic, voice: { .f1 }, player: PCMPlayer(engine: audioEngine))

        try await session.activate()
        do {
            echoCancelled = await recognizer.supportsConcurrentPlayback
            try save()
            try await speaker.prepare()
            try await recognizer.prepare()
            for trial in 1...Self.trialsPerStage {
                let record = try await runTrial(trial, recognizer: recognizer, speaker: speaker)
                records.append(record)
                try save()
                print("VOICE_BARGE_TRIAL \(stage.rawValue) \(trial) \(record["outcome"] ?? "")")
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            await speaker.stop()
            await recognizer.stop()
            await session.deactivate()
            await recognizer.shutdown()
            throw error
        }
        await session.deactivate()
        await recognizer.shutdown()
        try save()

        XCTAssertEqual(records.count, Self.trialsPerStage)
        XCTAssertTrue(echoCancelled, "the device path must run with voice processing (echo cancellation) enabled")
        XCTAssertTrue(records.allSatisfy { ($0["recognitionErrorType"] as? String) == nil && ($0["speechOutcome"] as? String) != "failed" })
#endif
    }

    /// 1 回の試行: 収録を先に始め（VM と同じ順序）、猫の発話を鳴らし、最初の語彙を含む認識結果で止める。
    private func runTrial(_ trial: Int, recognizer: AppleSpeechRecognizer, speaker: SupertonicSentenceSpeaker) async throws -> [String: Any] {
        let clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: clock)
        let observation = TrialObservation()
        let stage = self.stage
        let thermalBefore = String(describing: ProcessInfo.processInfo.thermalState)

        let recognition = try await recognizer.start()
        let trialStart = clock()
        let channel = SpeechSentenceChannel()
        let events = try await ReplyTraceContext.$current.withValue(trace) {
            try await speaker.speakSentences(from: channel, prefetch: true)
        }
        let feeder = Task {
            for (ordinal, text) in Self.catSentences.enumerated() {
                try await channel.send(SpeechSentence(ordinal: ordinal, original: text))
            }
            await channel.finish()
        }
        let speech = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    switch event.event {
                    case .started where event.ordinal == 0:
                        observation.speechStartedAt = clock()
                        if stage == .external, let self {
                            try self.writeReady(trial: trial)
                            observation.readyWrittenAt = clock()
                        }
                    case .finished:
                        observation.finishedSentences += 1
                    default:
                        break
                    }
                }
                observation.speechOutcome = "finished"
            } catch {
                observation.speechOutcome = (error as? ConversationServiceError) == .cancelled ? "stopped" : "failed"
                observation.speechErrorType = String(describing: type(of: error))
            }
            observation.speechEndedAt = clock()
        }
        let listening = Task { @MainActor in
            do {
                for try await event in recognition {
                    observation.recognitionEvents += 1
                    let lexical = event.text.contains(where: \.isLexical)
                    if observation.detectedAt != nil {
                        observation.eventsAfterDetection += 1
                        if sink.events.contains(where: { $0.point == .interruptionPlaybackStopped }) {
                            observation.eventsReceivedAfterNodeStop += 1
                        }
                    }
                    if lexical {
                        observation.lastTranscriptCharacters = Self.lexical(event.text).count
                        observation.lastTranscriptMatchesExternalFixture = Self.lexical(event.text) == Self.lexical(Self.externalFixture)
                        observation.lastTranscriptIsExternalFixturePrefix = Self.isPrefix(event.text, of: Self.externalFixture)
                    }
                    if observation.detectedAt == nil {
                        guard lexical else { continue }
                        observation.detectedAt = clock()
                        observation.detectedWhileSpeaking = observation.speechStartedAt != nil && observation.speechEndedAt == nil
                        observation.firstPartialCharacters = Self.lexical(event.text).count
                        observation.firstPartialIsExternalFixturePrefix = Self.isPrefix(event.text, of: Self.externalFixture)
                        observation.firstPartialIsCatSpeechFragment = Self.isFragmentOfCatSpeech(event.text)
                        trace.mark(.interruptionDetected)
                        // PCM の停止・合成終了待ちと並行して ASR を消費し続ける（VM と同じ）。
                        observation.stopTask = Task { @MainActor in
                            await speaker.stop()
                            observation.stopReturnedAt = clock()
                        }
                    }
                }
            } catch {
                observation.recognitionErrorType = String(describing: type(of: error))
            }
        }

        // 終了条件: 検出後は 3 秒だけ収録の継続を見る。external は ready から 25 秒まで外部発話を待つ。
        let deadline = trialStart + (stage == .external ? 60 : 45)
        while clock() < deadline {
            if let detectedAt = observation.detectedAt {
                if clock() - detectedAt >= 3 { break }
            } else if observation.speechEndedAt != nil {
                if stage == .selfOnly { break }
                if let ready = observation.readyWrittenAt, clock() - ready >= 25 { break }
                if observation.readyWrittenAt == nil { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let timedOut = clock() >= deadline && observation.detectedAt == nil && observation.speechEndedAt == nil
        feeder.cancel()
        await speaker.stop()
        await recognizer.stop()
        await listening.value
        await speech.value
        await observation.stopTask?.value
        _ = await feeder.result
        let trialEnd = clock()

        let session = AVAudioSession.sharedInstance()
        let detected = sink.events.first { $0.point == .interruptionDetected }
        let stopped = sink.events.first { $0.point == .interruptionPlaybackStopped }
        func ms(_ from: TimeInterval?, _ to: TimeInterval?) -> Any {
            guard let from, let to else { return NSNull() }
            return Int(((to - from) * 1_000).rounded())
        }
        let interrupted = observation.detectedAt != nil && observation.detectedWhileSpeaking
        return [
            "trial": trial, "stage": stage.rawValue, "echoCancelled": echoCancelled,
            "outcome": interrupted ? "interrupted" : "notInterrupted",
            "recognitionDetected": observation.detectedAt != nil, "timedOut": timedOut,
            "speechOutcome": observation.speechOutcome,
            "speechErrorType": (observation.speechErrorType as Any?) ?? NSNull(),
            "recognitionErrorType": (observation.recognitionErrorType as Any?) ?? NSNull(),
            "totalSentences": Self.catSentences.count,
            "finishedSentencesBeforeStop": observation.finishedSentences,
            "speechStartedAfterTrialStartMs": ms(trialStart, observation.speechStartedAt),
            "readyAfterSpeechStartMs": ms(observation.speechStartedAt, observation.readyWrittenAt),
            "detectionAfterSpeechStartMs": ms(observation.speechStartedAt, observation.detectedAt),
            "detectionAfterReadyMs": ms(observation.readyWrittenAt, observation.detectedAt),
            "detectionToNodeStopMs": ms(detected?.at, stopped?.at),
            "detectionToStopReturnMs": ms(observation.detectedAt, observation.stopReturnedAt),
            "detectedWhileSpeaking": observation.detectedWhileSpeaking,
            "firstPartialCharacters": observation.firstPartialCharacters,
            "firstPartialIsExternalFixturePrefix": observation.firstPartialIsExternalFixturePrefix,
            "firstPartialIsCatSpeechFragment": observation.firstPartialIsCatSpeechFragment,
            "recognitionEvents": observation.recognitionEvents,
            "recognitionEventsAfterDetection": observation.eventsAfterDetection,
            // ASR event に録音時刻は無いので、停止後の「受信」であり、その後に録音されたという保証ではない。
            "recognitionEventsReceivedAfterNodeStop": observation.eventsReceivedAfterNodeStop,
            "receivedRecognitionAfterNodeStop": observation.eventsReceivedAfterNodeStop > 0,
            "lastTranscriptCharacters": observation.lastTranscriptCharacters,
            "lastTranscriptMatchesExternalFixture": observation.lastTranscriptMatchesExternalFixture,
            "lastTranscriptIsExternalFixturePrefix": observation.lastTranscriptIsExternalFixturePrefix,
            "trialDurationMs": ms(trialStart, trialEnd),
            "traceEvents": sink.events.map { ["point": $0.point.rawValue, "atMs": ms(trialStart, $0.at)] },
            "routeInputs": session.currentRoute.inputs.map { $0.portType.rawValue },
            "routeOutputs": session.currentRoute.outputs.map { $0.portType.rawValue },
            "outputVolume": session.outputVolume, "audioMode": session.mode.rawValue,
            "thermalBefore": thermalBefore, "thermalAfter": String(describing: ProcessInfo.processInfo.thermalState),
        ]
    }

    /// 外部発話の合図。runner はこの trial 番号（1 始まり）ごとに 1 回だけ既知の文を流す。
    private func writeReady(trial: Int) throws {
        try JSONSerialization.data(withJSONObject: ["runID": runID, "trial": trial], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
    }

    private static func lexical(_ text: String) -> String { text.filter(\.isLexical) }
    private static func isPrefix(_ text: String, of fixture: String) -> Bool {
        let partial = lexical(text)
        return !partial.isEmpty && lexical(fixture).hasPrefix(partial)
    }
    private static func isFragmentOfCatSpeech(_ text: String) -> Bool {
        let partial = lexical(text)
        return !partial.isEmpty && lexical(catSentences.joined()).contains(partial)
    }

    private func save() throws {
        let session = AVAudioSession.sharedInstance()
        var uts = utsname(); uname(&uts)
        let hardware = withUnsafePointer(to: &uts.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let interrupted = records.filter { $0["outcome"] as? String == "interrupted" }.count
        let recognized = records.filter { $0["recognitionDetected"] as? Bool == true }.count
        let payload: [String: Any] = [
            "schemaVersion": 1, "runID": runID, "sourceRevision": revision, "stage": stage.rawValue,
            "device": hardware, "OS": UIDevice.current.systemVersion,
            "route": session.currentRoute.outputs.map { $0.portType.rawValue }, "volume": session.outputVolume,
            "echoCancelled": echoCancelled, "plannedTrials": Self.trialsPerStage, "completedTrials": records.count,
            "interruptedTrials": interrupted, "recognizedTrials": recognized,
            "falseInterruptions": stage == .selfOnly ? (recognized as Any) : (NSNull() as Any),
            "acousticAssessment": "pending", "trials": records,
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
}

/// 1 試行の観測値。すべて MainActor の task から書く。
@MainActor
private final class TrialObservation {
    var speechStartedAt: TimeInterval?
    var speechEndedAt: TimeInterval?
    var readyWrittenAt: TimeInterval?
    var detectedAt: TimeInterval?
    var stopReturnedAt: TimeInterval?
    var detectedWhileSpeaking = false
    var finishedSentences = 0
    var speechOutcome = "pending"
    var speechErrorType: String?
    var recognitionErrorType: String?
    var recognitionEvents = 0
    var eventsAfterDetection = 0
    var eventsReceivedAfterNodeStop = 0
    var stopTask: Task<Void, Never>?
    var firstPartialCharacters = 0
    var firstPartialIsExternalFixturePrefix = false
    var firstPartialIsCatSpeechFragment = false
    var lastTranscriptCharacters = 0
    var lastTranscriptMatchesExternalFixture = false
    var lastTranscriptIsExternalFixturePrefix = false
}
