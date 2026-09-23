import AVFAudio
import Foundation
import Observation
import UIKit
import XCTest
@testable import CatRobot

@MainActor
final class ReplyLatencyDeviceTests: XCTestCase {
    private var records: [[String: Any]] = []
    private var runID = UUID()

    func testAudioSessionPreflight() async throws {
        try requireOptIn()
        try checkAudioSession()
    }

    private func checkAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        print("AUDIO_PREFLIGHT appState=\(UIApplication.shared.applicationState.rawValue) permission=\(AVAudioApplication.shared.recordPermission.rawValue) inputAvailable=\(session.isInputAvailable) route=\(session.currentRoute)")
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            print("AUDIO_PREFLIGHT active=true")
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            let value = error as NSError
            print("AUDIO_PREFLIGHT failure domain=\(value.domain) code=\(value.code) info=\(value.userInfo)")
            throw error
        }
    }

    func testPairedWarmResponseLatency() async throws {
        try requireOptIn()
        executionTimeAllowance = 3600
        try checkAudioSession()
        for repetition in 0..<3 {
            let modes: [ReplyPlaybackMode] = repetition.isMultiple(of: 2)
                ? [.completeResponse, .firstSentence] : [.firstSentence, .completeResponse]
            for fixture in ReplyLatencyFixture.normal {
                for path in ["fast", "classified"] {
                    for mode in modes {
                        try await recordTrial(fixture, mode: mode, path: path, repetition: repetition, temperature: "warm")
                    }
                }
            }
            for fixture in ReplyLatencyFixture.controls {
                for mode in modes {
                    try await recordTrial(fixture, mode: mode, path: "typed", repetition: repetition, temperature: "warm")
                }
            }
        }
        try attachResults()
    }

    /// Launch a fresh test-host process for every mode/repetition. Never run this
    /// together with the warm matrix and label the same process "cold".
    func testColdResponseLatency() async throws {
        try requireOptIn()
        let environment = ProcessInfo.processInfo.environment
        guard let rawMode = environment["CATROBOT_LATENCY_COLD_MODE"], let mode = ReplyPlaybackMode(rawValue: rawMode),
              let rawRepetition = environment["CATROBOT_LATENCY_REPETITION"], let repetition = Int(rawRepetition), repetition >= 0 else {
            throw XCTSkip("Cold comparison requires one explicitly selected fresh-process trial")
        }
        executionTimeAllowance = 180
        try await recordTrial(ReplyLatencyFixture.normal[0], mode: mode, path: "fast", repetition: repetition, temperature: "cold")
        try attachResults()
    }

    private func requireOptIn() throws {
#if targetEnvironment(simulator) || !DEBUG
        throw XCTSkip("Response latency comparison requires an opted-in DEBUG iPhone build")
#else
        guard ProcessInfo.processInfo.environment["CATROBOT_REPLY_LATENCY_TESTS"] == "1" else {
            throw XCTSkip("Run the dedicated ReplyLatencyDeviceTests scheme explicitly")
        }
#endif
    }

    private func recordTrial(_ fixture: ReplyLatencyFixture, mode: ReplyPlaybackMode, path: String,
                             repetition: Int, temperature: String) async throws {
        // Independent UUID store per trial, checked before the first write.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let id = UUID()
        let directory = try ConversationMemoryLocation.directory(applicationSupport: support,
                                                                  environment: ["CATROBOT_MEMORY_TEST_ID": id.uuidString])
        let expected = support.appendingPathComponent("CatRobot/DeviceMemoryTests/\(id.uuidString)", isDirectory: true)
        guard directory.standardizedFileURL == expected.standardizedFileURL else {
            throw ConversationMemoryError.invalidData
        }
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: GemmaMemoryCompatibility.current)
        try await store.save(ReplyLatencyFixture.initialMemory)
        let service = GemmaConversationService(memoryStore: store)
        let driver = ReplyLatencySpeechDriver()
        let speaker = AppleSpeechSynthesizer(driver: driver)
        let recognizer = FakeSpeechRecognizer(log: ConversationTestCallLog())
        let sink = RecordingReplyTraceSink()
        let audio = AppleAudioSessionController()
        let viewModel = ConversationViewModel(dependencies: ConversationDependencies(
            microphonePermission: FakeMicrophonePermission(allowed: true, gate: nil, log: ConversationTestCallLog()),
            modelAvailability: service, recognizer: recognizer, classifier: service, reply: service,
            speaker: speaker, audioSession: audio, latency: ConversationLatencyTracker.live(),
            replyTraceSink: sink, replyPlaybackMode: mode, memory: service))
        if temperature == "warm" {
            try await service.prepareMemory()
            await service.prewarm()
            try await speaker.prepare()
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let thermal = String(describing: ProcessInfo.processInfo.thermalState)
        let power: String
        switch UIDevice.current.batteryState {
        case .unplugged: power = "unplugged"
        case .charging: power = "charging"
        case .full: power = "full"
        case .unknown: power = "unknown"
        @unknown default: power = "unknown"
        }
        let overallStart = ProcessInfo.processInfo.systemUptime
        var lastRecognitionUpdate: TimeInterval?
        if path == "typed" {
            await viewModel.submitTypedText(fixture.prompt)
        } else {
            await viewModel.startConversation()
            if viewModel.viewState.phase == .listening {
                let prompt = path == "fast" ? "猫ちゃん、" + fixture.prompt : fixture.prompt
                lastRecognitionUpdate = ProcessInfo.processInfo.systemUptime
                await recognizer.emit(.finalized(prompt))
                await waitForState(viewModel) { $0.provisionalTranscript == prompt }
                // Synthetic boundary, not measured acoustic silence or user speech.
                await viewModel.flushSegmentation(at: ProcessInfo.processInfo.systemUptime + 1.2)
            }
        }
        let overallEnd = ProcessInfo.processInfo.systemUptime
        let events = sink.events
        let terminal = events.last { $0.point == .finished }?.outcome
        let outcome = terminal?.rawValue ?? (viewModel.viewState.errorMessage == nil ? "noResponse" : "preparationFailure")
        let firstSentence = events.first { $0.point == .firstSentence }?.at
        let generated = events.first { $0.point == .generationFinished }?.at
        let encodedEvents = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))
        let restored = try await store.load()
        var record: [String: Any] = [
            "schemaVersion": 1, "trialID": "\(fixture.id)/\(mode.rawValue)/\(path)/\(repetition)/\(temperature)",
            "fixture": fixture.id, "cohort": fixture.cohort, "mode": mode.rawValue, "path": path,
            "inputKind": path == "typed" ? "typed" : "syntheticRecognition", "repetition": repetition,
            "temperature": temperature, "processID": ProcessInfo.processInfo.processIdentifier,
            "outcome": outcome, "thermalState": thermal, "powerState": power,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "osVersion": UIDevice.current.systemVersion, "voiceIdentifier": driver.voiceIdentifier ?? "unselected",
            "initialRevision": 1, "events": encodedEvents,
            "earlySentenceUsed": firstSentence != nil && generated != nil && firstSentence! < generated!,
            "listeningResumed": viewModel.viewState.phase == .listening,
            "overallCompletionSeconds": overallEnd - overallStart,
            "answer": viewModel.viewState.caption, // Only fixed synthetic fixtures enter these artifacts.
            "spokenParts": driver.texts, "memoryState": String(describing: viewModel.viewState.memoryState),
            "restoredRevision": restored?.revision ?? 0,
            "volume": AVAudioSession.sharedInstance().outputVolume
        ]
        if let lastRecognitionUpdate { record["lastRecognitionUpdate"] = lastRecognitionUpdate }
        if let error = viewModel.viewState.errorMessage { record["error"] = error }
        records.append(record)
        await viewModel.shutdown()
        try writeResults() // Preserve completed trials even if a later trial fails.
        print("REPLY_LATENCY_TRIAL \(records.count) \(record["trialID"]!) outcome=\(outcome)")
    }

    private func waitForState(_ viewModel: ConversationViewModel,
                              _ predicate: @escaping @MainActor (ConversationViewState) -> Bool) async {
        await withCheckedContinuation { continuation in Self.observe(viewModel, predicate, continuation) }
    }
    private static func observe(_ viewModel: ConversationViewModel,
                         _ predicate: @escaping @MainActor (ConversationViewState) -> Bool,
                         _ continuation: CheckedContinuation<Void, Never>) {
        if predicate(viewModel.viewState) { continuation.resume(); return }
        withObservationTracking { _ = viewModel.viewState } onChange: {
            Task { @MainActor in Self.observe(viewModel, predicate, continuation) }
        }
    }

    private func resultData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "runID": runID.uuidString,
                                                     "trials": records, "validation": [:]],
                                   options: [.prettyPrinted, .sortedKeys])
    }
    private func writeResults() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("CatRobot/ReplyLatencyTests/\(runID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try resultData().write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
    private func attachResults() throws {
        let attachment = XCTAttachment(data: try resultData(), uniformTypeIdentifier: "public.json")
        attachment.name = "Reply latency \(runID.uuidString)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Observes the actual selected voice and submitted text without changing the
/// production synthesizer's voice-selection, queueing or callback behavior.
@MainActor
private final class ReplyLatencySpeechDriver: SpeechSynthesizerDriving {
    private let live = LiveSpeechSynthesizerDriver()
    var onEvent: (@MainActor @Sendable (SpeechSynthesizerDriverEvent) -> Void)?
    private(set) var voiceIdentifier: String?
    private(set) var texts: [String] = []
    init() { live.onEvent = { [weak self] event in self?.onEvent?(event) } }
    func availableVoices() -> [SpeechVoiceDescriptor] { live.availableVoices() }
    func speak(_ text: String, voiceIdentifier: String, runID: UInt64) throws {
        self.voiceIdentifier = voiceIdentifier
        texts.append(text)
        try live.speak(text, voiceIdentifier: voiceIdentifier, runID: runID)
    }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { live.stopSpeaking(at: boundary) }
}
