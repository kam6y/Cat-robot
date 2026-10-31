import AVFAudio
import Foundation
@testable import CatRobot

/// 共有 engine（ConversationAudioEngine）の fake driver が記録する呼び出し。
enum AudioEngineCall: Equatable, Sendable {
    case configure(duplex: Bool)
    case start
    case stop
    case installTap(bufferSize: AVAudioFrameCount, sampleRate: Double)
    case removeTap
    case connectPlayer(sampleRate: Double)
    case schedule(frames: AVAudioFrameCount)
    case startPlayer
    case stopPlayer
}

enum FakeAudioEngineError: Error {
    case voiceProcessingUnavailable
    case startFailed
}

/// driver の呼び出し 1 つを、テストが `release` するまでその呼び出しの中で止める。
/// 止まっている間に届いた読み取りは driver が記録するので、engine が driver アクセスを直列化しているかを観測できる。
final class AudioEngineCallGate: Sendable {
    /// 対象の呼び出しが driver に入った時点で signal される。
    let entered = DispatchSemaphore(value: 0)
    /// テストが signal すると、止めていた呼び出しが進む。
    let release = DispatchSemaphore(value: 0)
    let matches: @Sendable (AudioEngineCall) -> Bool

    init(_ matches: @escaping @Sendable (AudioEngineCall) -> Bool) {
        self.matches = matches
    }
}

/// AVAudioEngine の代わりに呼び出し順と状態を記録する。
final class FakeAudioEngineDriver: AudioEngineDriving, @unchecked Sendable {
    private struct State {
        var calls: [AudioEngineCall] = []
        var isRunning = false
        var isVoiceProcessingEnabled = false
        var inputFormat: AVAudioFormat
        var playerSampleTime: AVAudioFramePosition?
        var tapBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void)?
        var completions: [@Sendable () -> Void] = []
        var voiceProcessingFails = false
        var startFails = false
        var gate: AudioEngineCallGate?
        var blockedCall: AudioEngineCall?
        var readsDuringBlockedCall: [String] = []
        var inputAccesses = 0
    }

    private let lock = NSLock()
    private var state: State

    init() {
        state = State(inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
    }

    var calls: [AudioEngineCall] { lock.withLock { state.calls } }
    var isRunning: Bool { lock.withLock { state.isRunning } }
    var isVoiceProcessingEnabled: Bool {
        lock.withLock { state.inputAccesses += 1; return state.isVoiceProcessingEnabled }
    }
    var inputFormat: AVAudioFormat {
        lock.withLock { noteRead("inputFormat"); state.inputAccesses += 1; return state.inputFormat }
    }
    /// 実機の AVAudioEngine で入力ノードを生成してしまう呼び出しの回数（inputFormat / voice processing / tap）。
    /// playback-only ではマイクを起動しないので 0 でなければならない。
    var inputAccesses: Int { lock.withLock { state.inputAccesses } }
    var playerSampleTime: AVAudioFramePosition? {
        lock.withLock { noteRead("playerSampleTime"); return state.playerSampleTime }
    }
    var hasTap: Bool { lock.withLock { state.tapBlock != nil } }
    /// 止めている呼び出しの最中に driver へ届いた読み取り（"inputFormat" / "playerSampleTime"）。
    var readsDuringBlockedCall: [String] { lock.withLock { state.readsDuringBlockedCall } }

    /// 次に `gate.matches` する呼び出しを `gate.release` まで止める（1 回限り）。
    func hold(_ gate: AudioEngineCallGate) {
        lock.withLock { state.gate = gate }
    }

    /// 呼び出しを記録し、gate の対象ならテストが release するまでその場で止める（自分の lock は持たない）。
    private func record(_ call: AudioEngineCall) {
        let gate: AudioEngineCallGate? = lock.withLock {
            state.calls.append(call)
            guard let gate = state.gate, gate.matches(call) else { return nil }
            state.gate = nil
            state.blockedCall = call
            return gate
        }
        guard let gate else { return }
        gate.entered.signal()
        gate.release.wait()
        lock.withLock { state.blockedCall = nil }
    }

    /// lock を持った状態で呼ぶ。
    private func noteRead(_ name: String) {
        if state.blockedCall != nil { state.readsDuringBlockedCall.append(name) }
    }

    var voiceProcessingFails: Bool {
        get { lock.withLock { state.voiceProcessingFails } }
        set { lock.withLock { state.voiceProcessingFails = newValue } }
    }

    var startFails: Bool {
        get { lock.withLock { state.startFails } }
        set { lock.withLock { state.startFails = newValue } }
    }

    /// route 変更などで入力フォーマットが変わったことを模す。
    func setInputFormat(sampleRate: Double) {
        lock.withLock { state.inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)! }
    }

    func setPlayerSampleTime(_ sampleTime: AVAudioFramePosition?) {
        lock.withLock { state.playerSampleTime = sampleTime }
    }

    func configure(duplex: Bool) throws {
        record(.configure(duplex: duplex))
        guard duplex else {
            lock.withLock { state.isVoiceProcessingEnabled = false }
            return
        }
        lock.withLock { state.inputAccesses += 1 }
        if voiceProcessingFails { throw FakeAudioEngineError.voiceProcessingUnavailable }
        lock.withLock { state.isVoiceProcessingEnabled = true }
    }

    func start() throws {
        record(.start)
        if startFails { throw FakeAudioEngineError.startFailed }
        lock.withLock { state.isRunning = true }
    }

    func stop() {
        record(.stop)
        lock.withLock { state.isRunning = false }
    }

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                         block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) {
        record(.installTap(bufferSize: bufferSize, sampleRate: format.sampleRate))
        lock.withLock { state.tapBlock = block; state.inputAccesses += 1 }
    }

    func removeInputTap() {
        record(.removeTap)
        lock.withLock { state.tapBlock = nil }
    }

    func connectPlayer(format: AVAudioFormat) {
        record(.connectPlayer(sampleRate: format.sampleRate))
    }

    func schedulePlayer(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        record(.schedule(frames: buffer.frameLength))
        lock.withLock { state.completions.append(completion) }
    }

    func startPlayer() {
        record(.startPlayer)
    }

    func stopPlayer() {
        record(.stopPlayer)
    }

    /// 最も古い再生完了コールバックを 1 つ発火する（AVAudioPlayerNode の dataPlayedBack 相当）。
    func completePlayback() {
        let completion: (@Sendable () -> Void)? = lock.withLock {
            state.completions.isEmpty ? nil : state.completions.removeFirst()
        }
        completion?()
    }

    /// tap に入力バッファを届ける。
    func deliverInput(_ buffer: AVAudioPCMBuffer) {
        let block = lock.withLock { state.tapBlock }
        block?(buffer, nil)
    }
}

func makeTestPCM(sampleRate: Double = 24_000, frames: Int = 240) -> SpeechPCM {
    SpeechPCM(samples: [Float](repeating: 0.1, count: frames), sampleRate: sampleRate)
}

func makeTestBuffer(sampleRate: Double = 24_000, frames: AVAudioFrameCount = 240) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    return buffer
}
