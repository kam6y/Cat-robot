import AVFAudio
import XCTest
@testable import CatRobot

/// 収録と再生が共有する engine の所有権。capture / playback を止めても engine は止まらず、
/// session の deactivate だけが engine を止める。古い lease は新しい所有者に触れない。
final class ConversationAudioEngineTests: XCTestCase {
    func testActivateEnablesVoiceProcessingWhileStoppedThenStartsOnce() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)

        try engine.activate()
        try engine.activate()

        XCTAssertEqual(driver.calls, [.configure(duplex: true), .start])
        XCTAssertTrue(engine.isActive)
        XCTAssertTrue(engine.isEchoCancelled)
    }

    func testVoiceProcessingFailureKeepsEngineUsableWithoutEchoCancellation() throws {
        let driver = FakeAudioEngineDriver()
        driver.voiceProcessingFails = true
        let engine = ConversationAudioEngine(driver: driver)

        try engine.activate()

        XCTAssertEqual(driver.calls, [.configure(duplex: true), .start])
        XCTAssertTrue(engine.isActive)
        XCTAssertFalse(engine.isEchoCancelled, "raw microphone over speaker output must never count as echo-cancelled")
    }

    func testStartFailureThrowsAudioSessionFailureAndStaysInactive() {
        let driver = FakeAudioEngineDriver()
        driver.startFails = true
        let engine = ConversationAudioEngine(driver: driver)

        XCTAssertThrowsError(try engine.activate()) { error in
            XCTAssertEqual(error as? ConversationServiceError, .audioSessionFailed)
        }
        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isEchoCancelled)
    }

    func testStartFailureUnwindsDriverSoRetryStartsClean() throws {
        let driver = FakeAudioEngineDriver()
        driver.startFails = true
        let engine = ConversationAudioEngine(driver: driver)

        XCTAssertThrowsError(try engine.activate())
        XCTAssertEqual(driver.calls, [.configure(duplex: true), .start, .stop],
                       "a start that throws must not leave the driver partially started")
        XCTAssertFalse(driver.isRunning)

        driver.startFails = false
        try engine.activate()
        XCTAssertEqual(Array(driver.calls.suffix(2)), [.configure(duplex: true), .start])
        XCTAssertTrue(engine.isActive)
    }

    func testInputFormatWaitsForDriverCallInProgress() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let gate = AudioEngineCallGate { $0 == .stop }
        driver.hold(gate)
        let deactivated = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { engine.deactivate(); deactivated.signal() }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)

        // session actor の deactivate が driver を止めている最中に、recognizer actor が入力フォーマットを読む。
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = engine.inputFormat; read.signal() }

        XCTAssertEqual(read.wait(timeout: .now() + 0.2), .timedOut, "inputFormat must wait while the driver is stopping")
        gate.release.signal()
        XCTAssertEqual(read.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(deactivated.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(driver.readsDuringBlockedCall, [], "the driver must not be read while another driver call is in progress")
    }

    func testPlaybackSampleTimeWaitsForDriverCallInProgress() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let lease = try engine.beginPlayback(makeTestBuffer()) {}
        driver.setPlayerSampleTime(480)
        let gate = AudioEngineCallGate { call in
            if case .installTap = call { return true }
            return false
        }
        driver.hold(gate)
        let captured = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? engine.beginCapture(bufferSize: 1_024) { _, _ in }
            captured.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)

        // 再生の開始監視（PCMPlayer）が、収録の tap を付けている最中に再生位置を読む。
        let position = CapturedValue<AVAudioFramePosition?>(nil)
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { position.set(engine.playbackSampleTime(lease)); read.signal() }

        XCTAssertEqual(read.wait(timeout: .now() + 0.2), .timedOut, "playbackSampleTime must wait while the driver installs a tap")
        gate.release.signal()
        XCTAssertEqual(read.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(captured.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(position.value, 480)
        XCTAssertEqual(driver.readsDuringBlockedCall, [], "the driver must not be read while another driver call is in progress")
    }

    func testPlaybackOnlyActivationNeverTouchesInputOrVoiceProcessing() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)

        try engine.activate(mode: .playbackOnly)
        try engine.activate(mode: .playbackOnly)

        XCTAssertEqual(driver.calls, [.configure(duplex: false), .start])
        XCTAssertEqual(engine.mode, .playbackOnly)
        XCTAssertFalse(engine.isEchoCancelled)
        XCTAssertNil(engine.inputFormat, "a playback-only engine has no input to describe")
        XCTAssertThrowsError(try engine.beginCapture(bufferSize: 1_024) { _, _ in }) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
        }
        _ = try engine.beginPlayback(makeTestBuffer()) {}
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(driver.inputAccesses, 0, "a paused typed-only reply must never instantiate the input node")
    }

    func testSwitchingModeWhileActiveReleasesOwnersAndRestartsInTheNewMode() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate(mode: .duplex)
        let capture = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        let playback = try engine.beginPlayback(makeTestBuffer()) {}

        try engine.activate(mode: .playbackOnly)

        XCTAssertEqual(Array(driver.calls.suffix(5)), [.removeTap, .stopPlayer, .stop, .configure(duplex: false), .start])
        XCTAssertEqual(engine.mode, .playbackOnly)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isEchoCancelled)
        let callsBeforeStaleEnds = driver.calls.count
        engine.endCapture(capture)
        engine.endPlayback(playback)
        XCTAssertEqual(driver.calls.count, callsBeforeStaleEnds, "leases from the previous mode are stale")

        try engine.activate(mode: .duplex)
        XCTAssertEqual(Array(driver.calls.suffix(3)), [.stop, .configure(duplex: true), .start])
        XCTAssertEqual(engine.mode, .duplex)
        XCTAssertTrue(engine.isEchoCancelled)
        XCTAssertEqual(engine.inputFormat?.sampleRate, 48_000)
    }

    func testModeIsNilWhileInactive() throws {
        let engine = ConversationAudioEngine(driver: FakeAudioEngineDriver())

        XCTAssertNil(engine.mode)
        try engine.activate()
        XCTAssertEqual(engine.mode, .duplex)
        engine.deactivate()
        XCTAssertNil(engine.mode)
    }

    func testCaptureRequiresActiveEngineAndOneCaptureAtATime() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)

        XCTAssertThrowsError(try engine.beginCapture(bufferSize: 1_024) { _, _ in }) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
        }

        try engine.activate()
        let lease = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        XCTAssertTrue(engine.isCapturing)
        XCTAssertThrowsError(try engine.beginCapture(bufferSize: 1_024) { _, _ in }) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
        }
        XCTAssertEqual(driver.calls.filter { $0 == .installTap(bufferSize: 1_024, sampleRate: 48_000) }.count, 1)

        engine.endCapture(lease)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertFalse(driver.hasTap)
    }

    func testReactivationReconfiguresVoiceProcessingAndRereadsInputFormat() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)

        try engine.activate()
        let first = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        engine.deactivate()
        driver.setInputFormat(sampleRate: 16_000)
        try engine.activate()
        _ = try engine.beginCapture(bufferSize: 1_024) { _, _ in }

        XCTAssertEqual(driver.calls, [
            .configure(duplex: true), .start, .installTap(bufferSize: 1_024, sampleRate: 48_000),
            .removeTap, .stop,
            .configure(duplex: true), .start, .installTap(bufferSize: 1_024, sampleRate: 16_000),
        ])
        XCTAssertEqual(engine.inputFormat?.sampleRate, 16_000)
        engine.endCapture(first)
        XCTAssertTrue(engine.isCapturing, "a lease from the previous activation is stale")
    }

    func testEndingCaptureKeepsPlaybackAndEngineRunning() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let capture = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        _ = try engine.beginPlayback(makeTestBuffer()) {}

        engine.endCapture(capture)

        XCTAssertEqual(driver.calls.last, .removeTap)
        XCTAssertFalse(driver.calls.contains(.stop))
        XCTAssertFalse(driver.calls.contains(.stopPlayer))
        XCTAssertTrue(driver.isRunning)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isCapturing)
    }

    func testEndingPlaybackKeepsCaptureAndEngineRunning() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        _ = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        let playback = try engine.beginPlayback(makeTestBuffer()) {}

        engine.endPlayback(playback)

        XCTAssertEqual(driver.calls.last, .stopPlayer)
        XCTAssertFalse(driver.calls.contains(.stop))
        XCTAssertFalse(driver.calls.contains(.removeTap))
        XCTAssertTrue(driver.isRunning)
        XCTAssertTrue(driver.hasTap)
        XCTAssertTrue(engine.isCapturing)
        XCTAssertFalse(engine.isPlaying)
    }

    func testDeactivateStopsEngineRegardlessOfOwners() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let capture = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        let playback = try engine.beginPlayback(makeTestBuffer()) {}

        engine.deactivate()

        XCTAssertEqual(Array(driver.calls.suffix(3)), [.removeTap, .stopPlayer, .stop])
        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isEchoCancelled)

        let callsBeforeStaleEnds = driver.calls.count
        engine.endCapture(capture)
        engine.endPlayback(playback)
        XCTAssertEqual(driver.calls.count, callsBeforeStaleEnds, "owners released by deactivate must not touch the driver again")
    }

    func testStaleCaptureLeaseCannotEndNewerCapture() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let first = try engine.beginCapture(bufferSize: 1_024) { _, _ in }
        engine.endCapture(first)
        _ = try engine.beginCapture(bufferSize: 1_024) { _, _ in }

        engine.endCapture(first)

        XCTAssertTrue(engine.isCapturing)
        XCTAssertTrue(driver.hasTap)
        XCTAssertEqual(driver.calls.filter { $0 == .removeTap }.count, 1)
    }

    func testStalePlaybackLeaseCannotStopNewerPlayback() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let first = try engine.beginPlayback(makeTestBuffer()) {}
        engine.endPlayback(first)
        let second = try engine.beginPlayback(makeTestBuffer()) {}

        engine.endPlayback(first)

        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(driver.calls.filter { $0 == .stopPlayer }.count, 1)
        XCTAssertNotEqual(first, second)
    }

    func testPlaybackRequiresActiveEngineAndOnePlaybackAtATime() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)

        XCTAssertThrowsError(try engine.beginPlayback(makeTestBuffer()) {}) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }

        try engine.activate()
        let playback = try engine.beginPlayback(makeTestBuffer()) {}
        XCTAssertThrowsError(try engine.beginPlayback(makeTestBuffer()) {}) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }
        XCTAssertEqual(driver.calls, [
            .configure(duplex: true), .start,
            .connectPlayer(sampleRate: 24_000), .schedule(frames: 240), .startPlayer,
        ])

        engine.endPlayback(playback)
        XCTAssertFalse(engine.isPlaying)
    }

    func testPlayerConnectsOnlyWhenTheFormatChanges() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()

        let first = try engine.beginPlayback(makeTestBuffer(sampleRate: 24_000)) {}
        engine.endPlayback(first)
        let second = try engine.beginPlayback(makeTestBuffer(sampleRate: 24_000)) {}
        engine.endPlayback(second)
        _ = try engine.beginPlayback(makeTestBuffer(sampleRate: 44_100)) {}

        XCTAssertEqual(driver.calls.filter {
            if case .connectPlayer = $0 { return true }
            return false
        }, [.connectPlayer(sampleRate: 24_000), .connectPlayer(sampleRate: 44_100)])
    }

    func testPlaybackSampleTimeBelongsToTheCurrentLeaseOnly() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let first = try engine.beginPlayback(makeTestBuffer()) {}
        driver.setPlayerSampleTime(480)

        XCTAssertEqual(engine.playbackSampleTime(first), 480)

        engine.endPlayback(first)
        let second = try engine.beginPlayback(makeTestBuffer()) {}
        XCTAssertNil(engine.playbackSampleTime(first), "a stale lease must not read the new playback's position")
        XCTAssertEqual(engine.playbackSampleTime(second), 480)
    }

    func testCaptureTapReceivesInputWhileCapturing() throws {
        let driver = FakeAudioEngineDriver()
        let engine = ConversationAudioEngine(driver: driver)
        try engine.activate()
        let received = ReceivedFrames()
        let lease = try engine.beginCapture(bufferSize: 1_024) { buffer, _ in received.add(buffer.frameLength) }

        driver.deliverInput(makeTestBuffer(sampleRate: 48_000, frames: 1_024))
        engine.endCapture(lease)
        driver.deliverInput(makeTestBuffer(sampleRate: 48_000, frames: 1_024))

        XCTAssertEqual(received.frames, [1_024], "input after the capture ended must not reach the old tap")
    }
}

private final class ReceivedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AVAudioFrameCount] = []
    var frames: [AVAudioFrameCount] { lock.withLock { stored } }
    func add(_ frames: AVAudioFrameCount) { lock.withLock { stored.append(frames) } }
}

private final class CapturedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ initial: Value) { stored = initial }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
