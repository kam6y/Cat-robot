import AVFAudio
import Foundation

struct AudioTurnEndObservation: Equatable, Sendable {
    let probability: Float?
    let accepted: Bool
}

/// 音声 tap から Smart Turn 判定までを capture 単位で束ねる pipeline。
///
/// - tap 側の `consume` はコピーと有界 queue（深さ 8）への投入だけを行う。
/// - worker actor が 16 kHz mono へ変換し、512 sample ごとに VAD → `AudioTurnEndState` を進める。
/// - Smart Turn 推論は別 Task（同時 1 件）で走らせ、VAD を待たせない。結果は worker に戻して
///   `AudioTurnEndState.accept` で検証し、未処理の音声が残っていなければ `AudioTurnEndSignal` を通知する。
/// - `cancel` は即時に gate を無効化して queue を閉じる。進行中の推論は join せず、遅れて届いた結果は捨てる。
/// - queue あふれ・不正な音声・変換/VAD の失敗はこの capture を無効化し、呼び出し元にエラーを通知する。
final class AudioTurnEndCapture: @unchecked Sendable {
    static let queueDepth = 8

    private let gate: AudioTurnEndGate
    private let progress: AudioTurnEndProgress
    private let continuation: AsyncStream<AudioTurnEndChunk>.Continuation
    private let worker: AudioTurnEndWorker
    private let sourceFormat: AVAudioFormat
    private let consumerTask: Task<Void, Never>
    private let onFailure: @Sendable (any Error) -> Void

    init(sourceFormat: AVAudioFormat, vad: any VoiceActivityScoring,
         scorer: any AudioTurnScoring,
         configuration: AudioTurnEndConfiguration = .init(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onEndpoint: @escaping @Sendable (AudioTurnEndSignal) -> Void,
         onFailure: @escaping @Sendable (any Error) -> Void,
         onObservation: @escaping @Sendable (AudioTurnEndObservation) -> Void = { _ in }) throws {
        guard sourceFormat.commonFormat == .pcmFormatFloat32, sourceFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw AudioTurnModelError.invalidInput
        }
        let gate = AudioTurnEndGate()
        let progress = AudioTurnEndProgress()
        let worker = try AudioTurnEndWorker(
            sourceFormat: sourceFormat, targetFormat: targetFormat, gate: gate, progress: progress,
            vad: vad, scorer: scorer, configuration: configuration, now: now, onEndpoint: onEndpoint, onFailure: onFailure, onObservation: onObservation
        )
        let (stream, continuation) = AsyncStream<AudioTurnEndChunk>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.queueDepth)
        )
        self.onFailure = onFailure
        self.sourceFormat = sourceFormat
        self.gate = gate
        self.progress = progress
        self.worker = worker
        self.continuation = continuation
        consumerTask = Task.detached(priority: .userInitiated) {
            for await chunk in stream {
                await worker.process(chunk)
            }
        }
    }

    deinit {
        cancel()
    }

    /// tap から呼ぶ。バッファをコピーして queue に入れるだけで、変換や推論はしない。
    func consume(_ buffer: AVAudioPCMBuffer, at timestamp: TimeInterval) {
        guard progress.admit(timestamp: timestamp) else {
            fail(AudioTurnModelError.invalidInput)
            return
        }
        guard buffer.frameLength > 0, gate.beginAudio() else { return }
        progress.noteEnqueued()
        guard buffer.format == sourceFormat, let copy = Self.copy(buffer) else {
            rejectAudio()
            return
        }
        switch continuation.yield(AudioTurnEndChunk(buffer: copy, timestamp: timestamp)) {
        case .enqueued:
            break
        case .dropped, .terminated:
            // 落ちた音声を無音扱いにしないため、この capture をエラーで止める。
            rejectAudio()
        @unknown default:
            rejectAudio()
        }
    }

    /// 即時に無効化する。進行中の推論は待たない。
    func cancel() {
        guard progress.markCancelled() else { return }
        gate.invalidate()
        continuation.finish()
    }

    private func rejectAudio() {
        fail(AudioTurnModelError.invalidInput)
        gate.endAudio()
        progress.noteProcessed()
    }

    private func fail(_ error: any Error) {
        guard progress.claimFailure() else { return }
        gate.invalidate()
        continuation.finish()
        onFailure(error)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData else { return nil }
        if buffer.format.isInterleaved {
            destination[0].update(from: source[0], count: frames * channels)
        } else {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        }
        copy.frameLength = buffer.frameLength
        return copy
    }
}

/// tap が作った私有コピー。worker だけが読む。
private struct AudioTurnEndChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let timestamp: TimeInterval
}

/// tap・worker・cancel が共有する進捗。enqueued == processed のとき未処理の音声はない。
private final class AudioTurnEndProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var enqueued = 0
    private var processed = 0
    private var cancelled = false
    private var invalidated = false
    private var failureReported = false
    private var lastTimestamp: TimeInterval?

    func admit(timestamp: TimeInterval) -> Bool {
        lock.withLock {
            guard !cancelled, !invalidated else { return false }
            guard timestamp.isFinite, timestamp >= (lastTimestamp ?? timestamp) else {
                invalidated = true
                return false
            }
            lastTimestamp = timestamp
            return true
        }
    }

    var isStopped: Bool { lock.withLock { cancelled || invalidated } }
    var isDrained: Bool { lock.withLock { enqueued == processed } }

    func noteEnqueued() { lock.withLock { enqueued += 1 } }
    func noteProcessed() { lock.withLock { processed += 1 } }
    func claimFailure() -> Bool {
        lock.withLock {
            guard !cancelled, !failureReported else { return false }
            invalidated = true
            failureReported = true
            return true
        }
    }

    /// 最初の呼び出しだけ true。
    func markCancelled() -> Bool {
        lock.withLock {
            let first = !cancelled
            cancelled = true
            return first
        }
    }
}

private actor AudioTurnEndWorker {
    private let resampler: AudioTurnEndResampler
    private let gate: AudioTurnEndGate
    private let progress: AudioTurnEndProgress
    private let vad: any VoiceActivityScoring
    private let scorer: any AudioTurnScoring
    private let now: @Sendable () -> TimeInterval
    private let onEndpoint: @Sendable (AudioTurnEndSignal) -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private let onObservation: @Sendable (AudioTurnEndObservation) -> Void
    private let configuration: AudioTurnEndConfiguration
    private var state: AudioTurnEndState
    private var pendingSamples: [Float] = []
    private var inferenceInFlight = false
    private var deferredRequest: AudioTurnEndRequest?
    private struct PendingSignal {
        let probability: Float
        let requestedAt: TimeInterval
    }
    private var pendingSignal: PendingSignal?

    init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat,
         gate: AudioTurnEndGate, progress: AudioTurnEndProgress,
         vad: any VoiceActivityScoring, scorer: any AudioTurnScoring,
         configuration: AudioTurnEndConfiguration,
         now: @escaping @Sendable () -> TimeInterval,
         onEndpoint: @escaping @Sendable (AudioTurnEndSignal) -> Void,
         onFailure: @escaping @Sendable (any Error) -> Void,
         onObservation: @escaping @Sendable (AudioTurnEndObservation) -> Void) throws {
        resampler = try AudioTurnEndResampler(sourceFormat: sourceFormat, targetFormat: targetFormat)
        self.gate = gate
        self.progress = progress
        self.vad = vad
        self.scorer = scorer
        self.configuration = configuration
        state = AudioTurnEndState(configuration: configuration)
        self.now = now
        self.onFailure = onFailure
        self.onEndpoint = onEndpoint
        self.onObservation = onObservation
    }

    func process(_ chunk: AudioTurnEndChunk) {
        if !progress.isStopped {
            analyze(chunk)
        }
        gate.endAudio()
        progress.noteProcessed()
        emitPendingSignalIfDrained()
    }

    private func analyze(_ chunk: AudioTurnEndChunk) {
        do {
            try resampler.append(chunk.buffer, to: &pendingSamples)
        } catch {
            invalidate(error)
            return
        }
        while !progress.isStopped, pendingSamples.count >= AudioTurnEndState.frameLength {
            let frame = Array(pendingSamples.prefix(AudioTurnEndState.frameLength))
            pendingSamples.removeFirst(AudioTurnEndState.frameLength)
            let probability: Float
            do {
                probability = try vad.speechProbability(samples: frame)
            } catch {
                invalidate(error)
                return
            }
            guard !progress.isStopped else { return }
            guard probability.isFinite, (0...1).contains(probability), frame.allSatisfy(\.isFinite) else {
                invalidate(AudioTurnModelError.invalidInput)
                return
            }
            if probability >= AudioTurnEndState.speechOnsetProbability {
                gate.noteSpeech()
                pendingSignal = nil
            }
            if let request = state.consume(samples: frame, speechProbability: probability, at: chunk.timestamp) {
                startInference(request)
            }
        }
    }

    private func startInference(_ request: AudioTurnEndRequest) {
        guard !progress.isStopped else { return }
        // 推論を積まず、再発話で古くなった結果を破棄する。
        guard !inferenceInFlight else {
            deferredRequest = request
            return
        }
        inferenceInFlight = true
        let scorer = self.scorer
        let progress = self.progress
        Task.detached(priority: .userInitiated) { [weak self] in
            guard !progress.isStopped else { return }
            let outcome = Result { try scorer.completionProbability(samples: request.samples) }
            await self?.apply(outcome, for: request)
        }
    }

    private func apply(_ outcome: Result<Float, any Error>, for request: AudioTurnEndRequest) {
        inferenceInFlight = false
        defer { inferDeferredPauseIfCurrent() }
        guard !progress.isStopped else { return }
        let completedAt = now()
        let probability = try? outcome.get()
        let accepted = probability.map { state.accept(probability: $0, for: request, at: completedAt) } ?? false
        onObservation(AudioTurnEndObservation(probability: probability, accepted: accepted))
        if case .failure(let error) = outcome { invalidate(error); return }
        guard let probability, probability.isFinite, (0...1).contains(probability) else {
            invalidate(AudioTurnModelError.invalidOutput)
            return
        }
        guard accepted else { return }
        pendingSignal = PendingSignal(probability: probability, requestedAt: request.requestedAt)
        emitPendingSignalIfDrained()
    }

    private func inferDeferredPauseIfCurrent() {
        let request = deferredRequest
        deferredRequest = nil
        guard !progress.isStopped, let request, state.isPending(request, at: now()) else { return }
        startInference(request)
    }

    /// queue に未処理の音声が残っている間は通知しない。残りが声なら pendingSignal は消える。
    private func emitPendingSignalIfDrained() {
        guard let pendingSignal else { return }
        // Snapshot before checking admission: a tap racing this check must
        // invalidate this exact signal, including while its buffer awaits VAD.
        let signal = AudioTurnEndSignal(probability: pendingSignal.probability,
                                        requestedAt: pendingSignal.requestedAt, gate: gate,
                                        configuration: configuration)
        guard progress.isDrained, signal.isValid(at: now()) else { return }
        if !pendingSamples.isEmpty {
            let probability: Float
            do {
                guard pendingSamples.allSatisfy(\.isFinite) else { throw AudioTurnModelError.invalidInput }
                probability = try vad.speechProbabilityOfTail(samples: pendingSamples)
            } catch {
                invalidate(error)
                return
            }
            guard !progress.isStopped else { return }
            guard probability.isFinite, (0...1).contains(probability) else {
                invalidate(AudioTurnModelError.invalidOutput)
                return
            }
            if probability >= AudioTurnEndState.speechOnsetProbability {
                gate.noteSpeech()
                self.pendingSignal = nil
                return
            }
        }
        // A raw chunk or cancellation during the synchronous preview retires
        // this exact snapshot. Keep real PCM/state unchanged for later frames.
        guard !progress.isStopped, progress.isDrained, signal.isValid(at: now()) else { return }
        self.pendingSignal = nil
        onEndpoint(signal)
    }

    private func invalidate(_ error: any Error) {
        guard progress.claimFailure() else { return }
        gate.invalidate()
        pendingSignal = nil
        pendingSamples.removeAll()
        onFailure(error)
    }
}

/// 16 kHz mono float32 への変換。source が同じ format ならコピーだけで済ませる。
private final class AudioTurnEndResampler {
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        self.targetFormat = targetFormat
        if sourceFormat == targetFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AudioTurnModelError.invalidInput
            }
            converter.primeMethod = .normal
            self.converter = converter
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) throws {
        guard let converter else {
            try Self.append(buffer, to: &samples)
            return
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        let input = AudioTurnEndConverterInput(buffer: buffer)
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw AudioTurnModelError.invalidInput
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                input.next(status: inputStatus)
            }
            guard conversionError == nil else { throw AudioTurnModelError.invalidInput }
            switch status {
            case .haveData:
                guard output.frameLength > 0 else { return }
                try Self.append(output, to: &samples)
            case .inputRanDry:
                try Self.append(output, to: &samples)
                return
            case .endOfStream:
                return
            case .error:
                throw AudioTurnModelError.invalidInput
            @unknown default:
                throw AudioTurnModelError.invalidInput
            }
        }
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) throws {
        guard buffer.frameLength > 0 else { return }
        guard let data = buffer.floatChannelData else { throw AudioTurnModelError.invalidInput }
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

/// AVAudioConverter の入力ブロックに 1 回だけバッファを渡す。
private final class AudioTurnEndConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
