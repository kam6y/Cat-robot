import AVFAudio
import CoreMedia
import Foundation
import Speech

protocol SpeechAudioConverting: AnyObject {
    func convert(
        _ buffer: AVAudioPCMBuffer,
        at time: AVAudioTime?
    ) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

struct SpeechAudioConversionOutcome {
    let status: AVAudioConverterOutputStatus
    let error: NSError?
}

protocol SpeechAudioConverterBackend: AnyObject {
    func convert(
        into outputBuffer: AVAudioPCMBuffer,
        inputBuffer: AVAudioPCMBuffer?,
        exhaustedStatus: AVAudioConverterInputStatus
    ) -> SpeechAudioConversionOutcome
    func reset()
}

final class SpeechAudioConverter: SpeechAudioConverting {
    typealias BackendFactory = (
        _ sourceFormat: AVAudioFormat,
        _ analyzerFormat: AVAudioFormat
    ) -> (any SpeechAudioConverterBackend)?

    private let analyzerFormat: AVAudioFormat
    private let analyzerTimeScale: CMTimeScale
    private let backend: (any SpeechAudioConverterBackend)?
    private var nextOutputTime: CMTime?
    private var timelineInitializationAttempted = false
    private var hasPendingInput = false
    private var outputCapacity: AVAudioFrameCount = 32

    convenience init(
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat
    ) throws {
        try self.init(
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat,
            backendFactory: { sourceFormat, analyzerFormat in
                LiveSpeechAudioConverterBackend(
                    sourceFormat: sourceFormat,
                    analyzerFormat: analyzerFormat
                )
            }
        )
    }

    init(
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        backendFactory: BackendFactory
    ) throws {
        guard Self.isSupportedPCMFormat(sourceFormat),
              Self.isSupportedPCMFormat(analyzerFormat),
              let analyzerTimeScale = Self.makeTimeScale(
                  from: analyzerFormat.sampleRate
              ) else {
            throw ConversationServiceError.speechCaptureFailed
        }

        self.analyzerFormat = analyzerFormat
        self.analyzerTimeScale = analyzerTimeScale
        if sourceFormat == analyzerFormat {
            backend = nil
        } else {
            guard let backend = backendFactory(sourceFormat, analyzerFormat) else {
                throw ConversationServiceError.speechCaptureFailed
            }
            self.backend = backend
        }
    }

    func convert(
        _ buffer: AVAudioPCMBuffer,
        at time: AVAudioTime?
    ) throws -> [AnalyzerInput] {
        guard let backend else {
            return [
                AnalyzerInput(
                    buffer: buffer,
                    bufferStartTime: Self.makeTime(from: time)
                ),
            ]
        }
        guard buffer.frameLength > 0 else { return [] }

        if !timelineInitializationAttempted {
            timelineInitializationAttempted = true
            nextOutputTime = Self.makeTime(from: time)
        }

        outputCapacity = try Self.makeOutputCapacity(
            inputFrames: buffer.frameLength,
            sourceRate: buffer.format.sampleRate,
            analyzerRate: analyzerFormat.sampleRate
        )
        hasPendingInput = true
        var outputs: [AnalyzerInput] = []
        var pendingInput: AVAudioPCMBuffer? = buffer
        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: outputCapacity
            ) else {
                throw ConversationServiceError.speechCaptureFailed
            }
            let outcome = backend.convert(
                into: outputBuffer,
                inputBuffer: pendingInput,
                exhaustedStatus: .noDataNow
            )
            pendingInput = nil
            guard outcome.error == nil, outcome.status != .error else {
                throw ConversationServiceError.speechCaptureFailed
            }

            switch outcome.status {
            case .haveData:
                guard outputBuffer.frameLength > 0 else { return outputs }
                outputs.append(makeAnalyzerInput(from: outputBuffer))
            case .inputRanDry:
                if outputBuffer.frameLength > 0 {
                    outputs.append(makeAnalyzerInput(from: outputBuffer))
                }
                return outputs
            case .endOfStream:
                return outputs
            case .error:
                throw ConversationServiceError.speechCaptureFailed
            @unknown default:
                throw ConversationServiceError.speechCaptureFailed
            }
        }
    }

    func flush() throws -> [AnalyzerInput] {
        guard let backend, hasPendingInput else { return [] }
        hasPendingInput = false
        defer {
            backend.reset()
            nextOutputTime = nil
            timelineInitializationAttempted = false
        }

        var outputs: [AnalyzerInput] = []
        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: outputCapacity
            ) else {
                throw ConversationServiceError.speechCaptureFailed
            }
            let outcome = backend.convert(
                into: outputBuffer,
                inputBuffer: nil,
                exhaustedStatus: .endOfStream
            )
            guard outcome.error == nil, outcome.status != .error else {
                throw ConversationServiceError.speechCaptureFailed
            }

            switch outcome.status {
            case .haveData, .inputRanDry:
                guard outputBuffer.frameLength > 0 else { return outputs }
                outputs.append(makeAnalyzerInput(from: outputBuffer))
            case .endOfStream:
                return outputs
            case .error:
                throw ConversationServiceError.speechCaptureFailed
            @unknown default:
                throw ConversationServiceError.speechCaptureFailed
            }
        }
    }

    private func makeAnalyzerInput(
        from buffer: AVAudioPCMBuffer
    ) -> AnalyzerInput {
        let startTime = nextOutputTime
        if let startTime {
            nextOutputTime = CMTimeAdd(
                startTime,
                CMTime(
                    value: CMTimeValue(buffer.frameLength),
                    timescale: analyzerTimeScale
                )
            )
        }
        return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
    }

    private static func isSupportedPCMFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat != .otherFormat
            && format.sampleRate.isFinite
            && format.sampleRate > 0
            && format.channelCount > 0
    }

    private static func makeOutputCapacity(
        inputFrames: AVAudioFrameCount,
        sourceRate: Double,
        analyzerRate: Double
    ) throws -> AVAudioFrameCount {
        guard sourceRate.isFinite,
              sourceRate > 0,
              analyzerRate.isFinite,
              analyzerRate > 0 else {
            throw ConversationServiceError.speechCaptureFailed
        }
        let capacity = ceil(Double(inputFrames) * analyzerRate / sourceRate) + 32
        guard capacity.isFinite,
              capacity > 0,
              capacity <= Double(AVAudioFrameCount.max) else {
            throw ConversationServiceError.speechCaptureFailed
        }
        return AVAudioFrameCount(capacity)
    }

    private static func makeTime(from time: AVAudioTime?) -> CMTime? {
        guard let time,
              time.isSampleTimeValid,
              let timeScale = makeTimeScale(from: time.sampleRate) else {
            return nil
        }
        return CMTime(
            value: CMTimeValue(time.sampleTime),
            timescale: timeScale
        )
    }

    private static func makeTimeScale(from sampleRate: Double) -> CMTimeScale? {
        guard sampleRate.isFinite else { return nil }
        let roundedRate = sampleRate.rounded()
        guard roundedRate >= 1,
              roundedRate <= Double(CMTimeScale.max) else {
            return nil
        }
        return CMTimeScale(roundedRate)
    }
}

private final class LiveSpeechAudioConverterBackend: SpeechAudioConverterBackend {
    private let converter: AVAudioConverter

    init?(sourceFormat: AVAudioFormat, analyzerFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(
            from: sourceFormat,
            to: analyzerFormat
        ) else {
            return nil
        }
        converter.primeMethod = .normal
        self.converter = converter
    }

    func convert(
        into outputBuffer: AVAudioPCMBuffer,
        inputBuffer: AVAudioPCMBuffer?,
        exhaustedStatus: AVAudioConverterInputStatus
    ) -> SpeechAudioConversionOutcome {
        var conversionError: NSError?
        let inputState = ConverterInputState(
            buffer: inputBuffer,
            exhaustedStatus: exhaustedStatus
        )
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError
        ) { _, inputStatus in
            inputState.next(status: inputStatus)
        }
        return SpeechAudioConversionOutcome(
            status: status,
            error: conversionError
        )
    }

    func reset() {
        converter.reset()
    }
}

private final class ConverterInputState: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let exhaustedStatus: AVAudioConverterInputStatus
    private var didSupplyBuffer = false

    init(
        buffer: AVAudioPCMBuffer?,
        exhaustedStatus: AVAudioConverterInputStatus
    ) {
        self.buffer = buffer
        self.exhaustedStatus = exhaustedStatus
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !didSupplyBuffer, let buffer else {
            status.pointee = exhaustedStatus
            return nil
        }
        didSupplyBuffer = true
        status.pointee = .haveData
        return buffer
    }
}
