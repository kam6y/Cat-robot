import XCTest
@testable import CatRobot

/// 設定で呼びかけの言葉を声で入力する一回だけの聞き取り。会話と同じ認識器を使うので、
/// 使える間だけ動き、止めるときは認識器と音声の session を手放し終わってから返ることを確かめる。
@MainActor
final class WakePhraseRecorderTests: XCTestCase {
    private struct Rig {
        let log: ConversationTestCallLog
        let recognizer: FakeSpeechRecognizer
        let audio: FakeConversationAudioSession
        let recorder: WakePhraseRecorder
    }

    private func makeRig(
        allowed: Bool = true,
        permissionGate: ConversationTestGate? = nil,
        deactivateGate: ConversationTestGate? = nil,
        tailOnStop: SpeechRecognitionEvent? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(60)) }
    ) -> Rig {
        let log = ConversationTestCallLog()
        let recognizer = FakeSpeechRecognizer(log: log, tailOnFirstStop: tailOnStop)
        let audio = FakeConversationAudioSession(log: log, deactivateGate: deactivateGate)
        let recorder = WakePhraseRecorder(recognizer: recognizer, audioSession: audio,
                                          permission: FakeMicrophonePermission(allowed: allowed, gate: permissionGate, log: log),
                                          sleep: sleep)
        return Rig(log: log, recognizer: recognizer, audio: audio, recorder: recorder)
    }

    private static let fullCapture: [ConversationTestCall] = [
        .requestMicrophone, .activateAudio, .prepareRecognizer, .startRecognizer, .stopRecognizer, .deactivateAudio,
    ]

    func testFinalizedPhraseIsReturnedAfterTheMicrophoneIsReleased() async {
        let rig = makeRig()
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.emit(.provisional("ミ"))
        await rig.recognizer.emit(.finalized("ミケ。"))

        let heard = await recording.value
        XCTAssertEqual(heard, "ミケ", "句読点と空白は入力欄に入れない")
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertFalse(rig.recorder.isRecording)
        XCTAssertEqual(rig.log.values, Self.fullCapture)
        let running = await rig.recognizer.isRunning
        let active = await rig.audio.isActive
        XCTAssertFalse(running)
        XCTAssertFalse(active)
    }

    func testTwoFinalizedSegmentsAreCapturedAsOnePhrase() async {
        let rig = makeRig()
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.emit(.finalized("ねえ"))
        try? await Task.sleep(for: .milliseconds(80))
        await rig.recognizer.emit(.finalized("ミケ"))
        await rig.recognizer.emit(.audioEnded(.init(probability: 0.95, requestedAt: ProcessInfo.processInfo.systemUptime)))
        let heard = await recording.value
        XCTAssertEqual(heard, "ねえミケ")
    }

    func testPunctuationAndStaleEndpointDoNotCutOffVoiceEntry() async {
        let rig = makeRig()
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.emit(.provisional("。"))
        await rig.recognizer.emit(.audioEnded(.init(probability: 0.95, requestedAt: ProcessInfo.processInfo.systemUptime)))
        await rig.recognizer.emit(.provisional("ミケ"))
        await rig.recognizer.emit(.audioEnded(.init(probability: 0.95, requestedAt: ProcessInfo.processInfo.systemUptime - 5)))
        try? await Task.sleep(for: .milliseconds(50))
        await rig.recognizer.emit(.finalized("ミケちゃん"))
        await rig.recognizer.emit(.audioEnded(.init(probability: 0.95, requestedAt: ProcessInfo.processInfo.systemUptime)))
        let heard = await recording.value
        XCTAssertEqual(heard, "ミケちゃん")
    }

    func testThrownRecognitionErrorIsReportedAsUnavailable() async {
        let rig = makeRig()
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.fail(.speechCaptureFailed)
        let heard = await recording.value
        XCTAssertNil(heard)
        XCTAssertEqual(rig.recorder.state, .failed(.unavailable))
    }

    func testEndOfSpeechStopsAndKeepsTheTranscriptFinalizedOnStop() async {
        let rig = makeRig(tailOnStop: .finalized("ミケ"))
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.emit(.provisional("ミケ"))
        await rig.recognizer.emit(.audioEnded(AudioTurnEndSignal(probability: 0.9, requestedAt: ProcessInfo.processInfo.systemUptime)))

        let heard = await recording.value
        XCTAssertEqual(heard, "ミケ", "言い終わりで止め、stop で確定した書き起こしを使う")
        XCTAssertEqual(rig.log.values, Self.fullCapture)
    }

    func testTimeLimitStopsListeningAndKeepsTheTranscriptFinalizedOnStop() async {
        let limit = ConversationTestGate()
        let rig = makeRig(tailOnStop: .finalized("ミケ"), sleep: { _ in await limit.wait() })
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.emit(.provisional("ミ"))
        await limit.open()

        let heard = await recording.value
        XCTAssertEqual(heard, "ミケ")
        XCTAssertEqual(rig.log.values, Self.fullCapture)
    }

    func testNothingHeardBeforeTheTimeLimitIsReportedWithoutAResult() async {
        let rig = makeRig(sleep: { _ in })
        rig.recorder.setAvailable(true)

        let heard = await rig.recorder.record()
        XCTAssertNil(heard)
        XCTAssertEqual(rig.recorder.state, .failed(.notHeard))
        XCTAssertEqual(rig.log.values, Self.fullCapture)
    }

    func testDeniedMicrophoneNeverOpensTheAudioSession() async {
        let rig = makeRig(allowed: false)
        rig.recorder.setAvailable(true)

        let heard = await rig.recorder.record()
        XCTAssertNil(heard)
        XCTAssertEqual(rig.recorder.state, .failed(.microphoneDenied))
        XCTAssertEqual(rig.log.values, [.requestMicrophone])
    }

    func testUnavailableRecorderDoesNotTouchTheMicrophone() async {
        let rig = makeRig()

        let heard = await rig.recorder.record()
        XCTAssertNil(heard)
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertEqual(rig.log.values, [])
    }

    func testCancelReturnsOnlyAfterTheMicrophoneIsReleased() async {
        let released = ConversationTestGate()
        let rig = makeRig(deactivateGate: released)
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await rig.recognizer.waitUntilStarted(1)

        let cancelling = Task { await rig.recorder.cancel() }
        await released.waitUntilEntered()
        XCTAssertTrue(rig.recorder.isRecording, "音声の session を手放し終わるまでは録音中として扱う")
        let running = await rig.recognizer.isRunning
        XCTAssertFalse(running, "取り消すときも認識器を止める")

        await released.open()
        await cancelling.value
        XCTAssertFalse(rig.recorder.isRecording)
        XCTAssertEqual(rig.recorder.state, .idle, "取り消しは失敗として出さない")
        let heard = await recording.value
        XCTAssertNil(heard)
        XCTAssertEqual(rig.log.values, Self.fullCapture)
    }

    func testLeavingTheForegroundDuringThePermissionPromptWaitsForTheAnswer() async {
        let answer = ConversationTestGate()
        let rig = makeRig(permissionGate: answer)
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await answer.waitUntilEntered()
        // 権限の確認を出している間、場面は inactive になり、答えた後で前面に戻る。
        rig.recorder.setAvailable(false)
        rig.recorder.setAvailable(true)
        await answer.open()
        await rig.recognizer.waitUntilStarted(1)
        await rig.recognizer.emit(.finalized("ミケ"))

        let heard = await recording.value
        XCTAssertEqual(heard, "ミケ")
    }

    func testStillUnavailableAfterThePermissionPromptDoesNotListen() async {
        let answer = ConversationTestGate()
        let rig = makeRig(permissionGate: answer)
        rig.recorder.setAvailable(true)
        let recording = Task { await rig.recorder.record() }
        await answer.waitUntilEntered()
        rig.recorder.setAvailable(false)
        await answer.open()

        let heard = await recording.value
        XCTAssertNil(heard)
        XCTAssertEqual(rig.recorder.state, .idle)
        XCTAssertEqual(rig.log.values, [.requestMicrophone])
    }

    /// 設定を閉じたときは、声で入力していた聞き取りがマイクを手放し終わってから、会話の聞き取りに戻る。
    func testClosingSettingsResumesListeningOnlyAfterTheRecorderReleasesTheMicrophone() async {
        let harness = ConversationHarness()
        let released = ConversationTestGate()
        let recorderAudio = FakeConversationAudioSession(log: harness.calls, deactivateGate: released)
        let recorder = WakePhraseRecorder(recognizer: harness.recognizer, audioSession: recorderAudio,
                                          permission: harness.microphone)
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }),
            wakePhraseRecorder: recorder)
        coordinator.beginConversation()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        XCTAssertFalse(recorder.isAvailable, "会話の聞き取り中は声で入力できない")

        coordinator.openVoiceSettings()
        await coordinator.waitForOperations()
        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertTrue(recorder.isAvailable, "会話を止めて設定を出し切った後は使える")
        let recording = Task { await recorder.record() }
        await harness.recognizer.waitUntilStarted(2)

        coordinator.closeVoiceSettings()
        XCTAssertFalse(coordinator.showsVoiceSettings)
        XCTAssertFalse(recorder.isAvailable)
        await released.waitUntilEntered()
        for _ in 0..<50 { await Task.yield() }
        let startsWhileReleasing = await harness.recognizer.startCount
        XCTAssertEqual(startsWhileReleasing, 2, "マイクを手放し終わるまで会話の聞き取りを始めない")

        await released.open()
        await coordinator.waitForOperations()
        let heard = await recording.value
        XCTAssertNil(heard)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        let calls = harness.calls.values
        XCTAssertLessThan(calls.lastIndex(of: .deactivateAudio) ?? .max, calls.lastIndex(of: .startRecognizer) ?? -1)
        await harness.sut.shutdown()
    }
}
