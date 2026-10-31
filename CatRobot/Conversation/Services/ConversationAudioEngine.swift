import AVFAudio
import Foundation

/// 収録（音声認識の tap）と再生（Supertonic の PCM）が共有する 1 つの AVAudioEngine の薄い抽象。
/// 実機では AVAudioEngine を包み、テストでは呼び出しを記録する fake を使う。
protocol AudioEngineDriving: AnyObject, Sendable {
    var isVoiceProcessingEnabled: Bool { get }
    /// 入力ノードの現在の出力フォーマット（voice processing の有無と route で変わるので、engine 停止中に読み直す）。
    var inputFormat: AVAudioFormat { get }
    /// 再生ノードの再生位置。まだ鳴っていなければ nil または 0。
    var playerSampleTime: AVAudioFramePosition? { get }
    /// engine 停止中にだけ呼ぶ。duplex は入力ノードの voice processing を有効化する（SDK の制約: 同じ engine の
    /// 入力・出力ノードの両方に効く）。playback-only は入力ノードに触れない engine を保証する（入力 I/O を起動しない）。
    func configure(duplex: Bool) throws
    func start() throws
    func stop()
    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                         block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void)
    func removeInputTap()
    func connectPlayer(format: AVAudioFormat)
    func schedulePlayer(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void)
    func startPlayer()
    func stopPlayer()
}

/// 共有 engine の動作モード。duplex は収録と再生（voice processing）、playback-only は再生だけで入力 I/O を起動しない
/// （一時停止中の文字入力の返答では、マイクを有効化しない）。
enum ConversationAudioMode: Equatable, Sendable {
    case duplex
    case playbackOnly
}

/// 収録・再生の所有権。古い lease の終了は新しい所有者に触れない。
struct AudioCaptureLease: Equatable, Sendable {
    let id: UUID
}

struct AudioPlaybackLease: Equatable, Sendable {
    let id: UUID
}

/// 会話の AudioSession が active な間だけ動く共有 engine。収録と再生は tap / player node の付け外しだけで、
/// engine 自体は deactivate まで止めない（voice processing は停止中にしか切り替えられず、ターンごとの再適応も避ける）。
/// voice processing を有効化できない経路では echo cancellation なしで動き、`isEchoCancelled` が false になる
/// （上位は再生中の収録を許可せず、従来の半二重のままにする）。
///
/// 駆動の呼び出しは `driverLock` で直列にし、状態は `stateLock` で守る。tap のブロックは状態だけを見るので、
/// tap を外す側が音声スレッドの完了を待っても互いに待ち合わない。
final class ConversationAudioEngine: @unchecked Sendable {
    private struct State {
        /// 動いている間のモード。止まっていれば nil。
        var mode: ConversationAudioMode?
        var isEchoCancelled = false
        var capture: AudioCaptureLease?
        var playback: AudioPlaybackLease?
        var connectedPlayerFormat: AVAudioFormat?
    }

    private let driver: any AudioEngineDriving
    private let driverLock = NSLock()
    private let stateLock = NSLock()
    private var state = State()

    init(driver: any AudioEngineDriving) {
        self.driver = driver
    }

    var isActive: Bool { stateLock.withLock { state.mode != nil } }
    /// 動いている間のモード。止まっていれば nil。
    var mode: ConversationAudioMode? { stateLock.withLock { state.mode } }
    /// 再生中の収録（声での割り込み）を許してよい経路か。activate ごとに決まる。
    var isEchoCancelled: Bool { stateLock.withLock { state.isEchoCancelled } }
    var isCapturing: Bool { stateLock.withLock { state.capture != nil } }
    var isPlaying: Bool { stateLock.withLock { state.playback != nil } }
    var hasActiveAudioOwners: Bool {
        stateLock.withLock { state.capture != nil || state.playback != nil }
    }
    /// 入力ノードの現在のフォーマット。duplex で動いている間だけ読める（playback-only では入力ノードに触れない）。
    /// driver の読み取りも、停止や tap の付け外しと同じ lock で直列にする（session actor の deactivate と
    /// recognizer actor の読み取りは並行し得る）。
    var inputFormat: AVAudioFormat? {
        driverLock.withLock {
            guard stateLock.withLock({ state.mode }) == .duplex else { return nil }
            return driver.inputFormat
        }
    }

    /// 停止中に driver をモードに合わせて構成してから engine を起動する。同じモードなら冪等。別のモードで動いていれば、
    /// 所有者を外して止めてから組み直す（古い lease は失効する）。duplex は voice processing を有効化し、使えない経路でも
    /// echo cancellation なしで起動する。playback-only は入力ノードに触れず、マイク（入力 I/O）を起動しない。
    func activate(mode: ConversationAudioMode = .duplex) throws {
        try driverLock.withLock {
            let current = stateLock.withLock { state.mode }
            guard current != mode else { return }
            if current != nil { release() }
            var echoCancelled = false
            switch mode {
            case .duplex:
                try? driver.configure(duplex: true)
                echoCancelled = driver.isVoiceProcessingEnabled
            case .playbackOnly:
                do {
                    try driver.configure(duplex: false)
                } catch {
                    throw ConversationServiceError.audioSessionFailed
                }
            }
            do {
                try driver.start()
            } catch {
                // 起動が途中で失敗しても部分起動を残さない（起動していない engine の stop / reset は無害）。
                driver.stop()
                throw ConversationServiceError.audioSessionFailed
            }
            stateLock.withLock {
                state = State(mode: mode, isEchoCancelled: echoCancelled)
            }
        }
    }

    /// 所有者が残っていても tap と player を外して engine を止める。以後、古い lease は無視される。
    func deactivate() {
        driverLock.withLock { release() }
    }

    /// driverLock を持って呼ぶ。所有者を外して engine を止め、状態を消す。
    private func release() {
        let released: (capture: Bool, playback: Bool)? = stateLock.withLock {
            guard state.mode != nil else { return nil }
            let released = (capture: state.capture != nil, playback: state.playback != nil)
            state = State()
            return released
        }
        guard let released else { return }
        if released.capture { driver.removeInputTap() }
        if released.playback { driver.stopPlayer() }
        driver.stop()
    }

    /// 入力ノードに tap を付ける。収録は同時に 1 つだけ。
    func beginCapture(bufferSize: AVAudioFrameCount,
                      block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) throws -> AudioCaptureLease {
        try driverLock.withLock {
            let lease = try stateLock.withLock { () throws -> AudioCaptureLease in
                // 止まっている engine にも、入力ノードを持たない playback-only の engine にも tap は付けられない。
                guard state.mode == .duplex else { throw ConversationServiceError.speechCaptureFailed }
                guard state.capture == nil else { throw ConversationServiceError.speechCaptureAlreadyRunning }
                let lease = AudioCaptureLease(id: UUID())
                state.capture = lease
                return lease
            }
            // driverLock は再入不可なので、ここでは self.inputFormat ではなく driver を直接読む。
            driver.installInputTap(bufferSize: bufferSize, format: driver.inputFormat) { [weak self] buffer, time in
                // tap を外した後に届く残りのバッファは、終わった収録へ流さない。
                guard let self, self.stateLock.withLock({ self.state.capture == lease }) else { return }
                block(buffer, time)
            }
            return lease
        }
    }

    func endCapture(_ lease: AudioCaptureLease) {
        driverLock.withLock {
            let owns = stateLock.withLock {
                guard state.capture == lease else { return false }
                state.capture = nil
                return true
            }
            if owns { driver.removeInputTap() }
        }
    }

    /// PCM を player node に予約して鳴らし始める。再生は同時に 1 つだけ。completion は再生し切ったときに呼ばれる。
    func beginPlayback(_ buffer: AVAudioPCMBuffer,
                       completion: @escaping @Sendable () -> Void) throws -> AudioPlaybackLease {
        try driverLock.withLock {
            let (lease, needsConnection) = try stateLock.withLock { () throws -> (AudioPlaybackLease, Bool) in
                guard state.mode != nil, state.playback == nil else { throw ConversationServiceError.speechSynthesisFailed }
                let lease = AudioPlaybackLease(id: UUID())
                state.playback = lease
                let needsConnection = state.connectedPlayerFormat != buffer.format
                state.connectedPlayerFormat = buffer.format
                return (lease, needsConnection)
            }
            if needsConnection { driver.connectPlayer(format: buffer.format) }
            driver.schedulePlayer(buffer, completion: completion)
            driver.startPlayer()
            return lease
        }
    }

    func endPlayback(_ lease: AudioPlaybackLease) {
        driverLock.withLock {
            let owns = stateLock.withLock {
                guard state.playback == lease else { return false }
                state.playback = nil
                return true
            }
            if owns { driver.stopPlayer() }
        }
    }

    /// その lease の再生位置。終わった lease には nil。照合と読み取りを driver の他の呼び出しと直列にする。
    func playbackSampleTime(_ lease: AudioPlaybackLease) -> AVAudioFramePosition? {
        driverLock.withLock {
            guard stateLock.withLock({ state.playback == lease }) else { return nil }
            return driver.playerSampleTime
        }
    }
}

/// 実機の AVAudioEngine。入力ノードの tap と、再生用の AVAudioPlayerNode → mainMixer → 出力の経路を 1 つの engine で持つ。
/// voice processing は入力ノードで有効化すると同じ engine の出力ノードにも効き、出力に流した音が入力から除かれる。
/// 呼び出しは ConversationAudioEngine が直列にする（同時に 1 つ）。
final class LiveAudioEngineDriver: AudioEngineDriving, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    /// この AVAudioEngine で入力ノードを生成したか。生成済みの engine は start で入力 I/O（マイク）も動かし、
    /// .playback のセッションでは起動に失敗するので、playback-only ではその engine を捨てて作り直す。
    private var usesInput = false

    init() {
        attachPlayer()
    }

    private func attachPlayer() {
        engine.attach(player)
        // 出力の経路（mainMixer → outputNode）を最初から作っておく。voice processing は入力と出力の両ノードを使う。
        _ = engine.mainMixerNode
    }

    /// 入力ノードを持たない新しい engine に置き換える（player node も作り直す。接続は次の再生で張り直される）。
    private func rebuildWithoutInput() {
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        usesInput = false
        attachPlayer()
    }

    var isVoiceProcessingEnabled: Bool {
        usesInput = true
        return engine.inputNode.isVoiceProcessingEnabled
    }
    var inputFormat: AVAudioFormat {
        usesInput = true
        return engine.inputNode.outputFormat(forBus: 0)
    }
    var playerSampleTime: AVAudioFramePosition? {
        guard let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return nil }
        return time.sampleTime
    }

    func configure(duplex: Bool) throws {
        if duplex {
            usesInput = true
            // 有効化済みなら呼び直さない（再 activate で失敗扱いにしない）。
            if !engine.inputNode.isVoiceProcessingEnabled {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            }
        } else if usesInput {
            rebuildWithoutInput()
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.reset()
    }

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat,
                         block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) {
        usesInput = true
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, time in
            block(buffer, time)
        }
    }

    func removeInputTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func connectPlayer(format: AVAudioFormat) {
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func schedulePlayer(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }

    func startPlayer() {
        player.play()
    }

    func stopPlayer() {
        player.stop()
    }
}
