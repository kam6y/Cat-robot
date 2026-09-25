import AVFAudio
import Foundation

@MainActor
protocol PCMPlaying: Sendable {
    func play(_ pcm: SpeechPCM) async throws -> AsyncThrowingStream<SpeechEvent, Error>
    func stop() async
}

@MainActor
final class PCMPlayer: PCMPlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var active: (id: UUID, continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation)?
    private var startMonitor: Task<Void, Never>?
    init() { engine.attach(node) }

    func play(_ pcm: SpeechPCM) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        guard active == nil else { throw ConversationServiceError.speechSynthesisFailed }
        try pcm.validate()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: pcm.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw SupertonicError.invalidPCM }
        buffer.frameLength = buffer.frameCapacity
        pcm.samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: source.count) }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        let id = UUID()
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        active = (id, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.finish(id: id, event: .cancelled) }
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finish(id: id, event: .finished) }
        }
        node.play()
        startMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active?.id == id else { return }
                if let render = self.node.lastRenderTime,
                   let time = self.node.playerTime(forNodeTime: render), time.sampleTime > 0 {
                    self.active?.continuation.yield(.started)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return pair.stream
    }
    func stop() async {
        if let id = active?.id { finish(id: id, event: .cancelled) }
    }
    private func finish(id: UUID, event: SpeechEvent) {
        guard let run = active, run.id == id else { return }
        active = nil
        startMonitor?.cancel(); startMonitor = nil
        node.stop(); engine.stop()
        run.continuation.yield(event); run.continuation.finish()
    }
}
