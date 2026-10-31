import AVFAudio
import Foundation

@MainActor
protocol PCMPlaying: Sendable {
    func play(_ pcm: SpeechPCM) async throws -> AsyncThrowingStream<SpeechEvent, Error>
    func stop() async
}

@MainActor
final class PCMPlayer: PCMPlaying {
    private struct Playback {
        let id: UUID
        let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
        /// 共有 engine での再生の所有権（共有しない構成では nil）。
        let lease: AudioPlaybackLease?
        /// この再生を始めたターンの trace。割り込みで止めた時刻を記す。
        let trace: ReplyTrace?
    }

    /// 再生の経路。収録と共有する engine か、共有 engine を持たない構成（device の benchmark / 統合テスト）だけが使う、
    /// play ごとに起動する再生専用の engine。
    private enum Backend {
        case shared(ConversationAudioEngine)
        case own(engine: AVAudioEngine, node: AVAudioPlayerNode)
    }

    private let backend: Backend
    private var active: Playback?
    private var startMonitor: Task<Void, Never>?

    init(engine shared: ConversationAudioEngine? = nil) {
        if let shared {
            backend = .shared(shared)
        } else {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            backend = .own(engine: engine, node: node)
        }
    }

    func play(_ pcm: SpeechPCM) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        guard active == nil else { throw ConversationServiceError.speechSynthesisFailed }
        try pcm.validate()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: pcm.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw SupertonicError.invalidPCM }
        buffer.frameLength = buffer.frameCapacity
        pcm.samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: source.count) }
        let id = UUID()
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        // 鳴り切った通知は音声スレッドから MainActor に跳ぶので、下の active の登録を追い越さない。
        let playedBack: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.finish(id: id, event: .finished) }
        }
        let lease: AudioPlaybackLease?
        switch backend {
        case .shared(let shared):
            // 共有 engine は動いたまま。player node の予約と開始だけを行う。
            lease = try shared.beginPlayback(buffer, completion: playedBack)
        case .own(let engine, let node):
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in playedBack() }
            node.play()
            lease = nil
        }
        active = Playback(id: id, continuation: pair.continuation, lease: lease, trace: ReplyTraceContext.current)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.finish(id: id, event: .cancelled) }
        }
        startMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active?.id == id else { return }
                if let time = self.playbackSampleTime(), time > 0 {
                    self.active?.continuation.yield(.started)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return pair.stream
    }

    func stop() async {
        guard let run = active else { return }
        finish(id: run.id, event: .cancelled)
    }

    private func playbackSampleTime() -> AVAudioFramePosition? {
        switch backend {
        case .shared(let shared):
            guard let lease = active?.lease else { return nil }
            return shared.playbackSampleTime(lease)
        case .own(_, let node):
            guard let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else { return nil }
            return time.sampleTime
        }
    }

    private func finish(id: UUID, event: SpeechEvent) {
        guard let run = active, run.id == id else { return }
        active = nil
        startMonitor?.cancel(); startMonitor = nil
        switch backend {
        case .shared(let shared):
            if let lease = run.lease { shared.endPlayback(lease) }
        case .own(let engine, let node):
            node.stop(); engine.stop()
        }
        // 割り込みの計測: 鳴り切る前に node を止めた時点を、その再生を始めたターンの trace に記す。
        // 止める経路は stop() でも購読の終了（task の取り消し）でもよい。割り込みの区間が開いていなければ trace 側で無視される。
        if event == .cancelled { run.trace?.mark(.interruptionPlaybackStopped) }
        run.continuation.yield(event); run.continuation.finish()
    }
}
