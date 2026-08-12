import AVFAudio
import CoreMedia
import Speech
import XCTest
@testable import CatRobot

final class SpeechAudioConverterTests: XCTestCase {
    func testMatchingFormatProducesAnalyzerInputWithSourceTimestamp() throws {
        let format = makeFormat(sampleRate: 48_000)
        let buffer = makeBuffer(format: format, frameCount: 480)
        let converter = try SpeechAudioConverter(
            sourceFormat: format,
            analyzerFormat: format
        )

        let output = try converter.convert(
            buffer,
            at: AVAudioTime(sampleTime: 960, atRate: 48_000)
        )

        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].buffer === buffer)
        XCTAssertEqual(
            output[0].bufferStartTime,
            CMTime(value: 960, timescale: 48_000)
        )
    }

    func testMatchingFormatOmitsInvalidSampleTimestamp() throws {
        let format = makeFormat(sampleRate: 48_000)
        let converter = try SpeechAudioConverter(
            sourceFormat: format,
            analyzerFormat: format
        )

        let output = try converter.convert(
            makeBuffer(format: format, frameCount: 480),
            at: AVAudioTime(hostTime: 1)
        )

        XCTAssertNil(output[0].bufferStartTime)
    }

    func testResamplesFortyEightKilohertzPCMToSixteenKilohertzPCM() throws {
        let sourceFormat = makeFormat(sampleRate: 48_000)
        let analyzerFormat = makeFormat(sampleRate: 16_000)
        let converter = try SpeechAudioConverter(
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat
        )

        let output = try converter.convert(
            makeBuffer(format: sourceFormat, frameCount: 4_800),
            at: AVAudioTime(sampleTime: 4_800, atRate: 48_000)
        )

        let converted = try XCTUnwrap(output.first)
        XCTAssertGreaterThan(converted.buffer.frameLength, 0)
        XCTAssertEqual(converted.buffer.format.sampleRate, 16_000)
        XCTAssertEqual(converted.buffer.format.channelCount, 1)
        XCTAssertEqual(
            converted.bufferStartTime,
            CMTime(value: 4_800, timescale: 48_000)
        )
    }

    func testResampledOutputTimestampsRemainContinuousAcrossInputBuffers() throws {
        let sourceFormat = makeFormat(sampleRate: 48_000)
        let analyzerFormat = makeFormat(sampleRate: 16_000)
        let converter = try SpeechAudioConverter(
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat
        )

        let firstOutput = try converter.convert(
            makeBuffer(format: sourceFormat, frameCount: 4_800),
            at: AVAudioTime(sampleTime: 9_600, atRate: 48_000)
        )
        let secondOutput = try converter.convert(
            makeBuffer(format: sourceFormat, frameCount: 4_800),
            at: AVAudioTime(sampleTime: 1_000_000, atRate: 48_000)
        )

        let first = try XCTUnwrap(firstOutput.first)
        let second = try XCTUnwrap(secondOutput.first)
        let firstStart = try XCTUnwrap(first.bufferStartTime)
        let expectedSecondStart = CMTimeAdd(
            firstStart,
            CMTime(
                value: CMTimeValue(first.buffer.frameLength),
                timescale: 16_000
            )
        )
        XCTAssertEqual(second.bufferStartTime, expectedSecondStart)
    }

    func testConvertDrainsEveryHaveDataBufferWithoutResupplyingInput() throws {
        let backend = FakeSpeechAudioConverterBackend(
            responses: [
                .init(
                    outcome: .init(status: .haveData, error: nil),
                    frameLength: 100
                ),
                .init(
                    outcome: .init(status: .inputRanDry, error: nil),
                    frameLength: 40
                ),
            ]
        )
        let converter = try makeConverter(backend: backend)

        let outputs = try converter.convert(
            makeBuffer(format: makeFormat(sampleRate: 48_000), frameCount: 480),
            at: nil
        )

        XCTAssertEqual(outputs.map(\.buffer.frameLength), [100, 40])
        XCTAssertEqual(backend.receivedInputPresence, [true, false])
    }

    func testFlushReturnsRealPrimedFramesOnlyOnce() throws {
        let sourceFormat = makeFormat(sampleRate: 48_000)
        let analyzerFormat = makeFormat(sampleRate: 16_000)
        let converter = try SpeechAudioConverter(
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat
        )
        _ = try converter.convert(
            makeBuffer(format: sourceFormat, frameCount: 4_800),
            at: nil
        )

        let first = try converter.flush()
        let second = try converter.flush()

        let firstFrameCount = first.reduce(0) {
            $0 + Int($1.buffer.frameLength)
        }
        XCTAssertGreaterThan(firstFrameCount, 0)
        XCTAssertTrue(second.isEmpty)
    }

    func testUnsupportedConversionThrowsCaptureFailure() {
        let invalid = AVAudioFormat(
            commonFormat: .otherFormat,
            sampleRate: 0,
            channels: 0,
            interleaved: false
        )!

        XCTAssertThrowsError(
            try SpeechAudioConverter(
                sourceFormat: invalid,
                analyzerFormat: makeFormat(sampleRate: 16_000)
            )
        ) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
        }
    }

    func testConverterErrorStatusMapsToCaptureFailure() throws {
        let backend = FakeSpeechAudioConverterBackend(
            outcome: .init(status: .error, error: nil)
        )
        let converter = try makeConverter(backend: backend)

        XCTAssertThrowsError(
            try converter.convert(
                makeBuffer(format: makeFormat(sampleRate: 48_000), frameCount: 480),
                at: nil
            )
        ) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
        }
    }

    func testConverterNSErrorMapsToCaptureFailure() throws {
        let backend = FakeSpeechAudioConverterBackend(
            outcome: .init(
                status: .inputRanDry,
                error: NSError(domain: "SpeechAudioConverterTests", code: 1)
            )
        )
        let converter = try makeConverter(backend: backend)

        XCTAssertThrowsError(
            try converter.convert(
                makeBuffer(format: makeFormat(sampleRate: 48_000), frameCount: 480),
                at: nil
            )
        ) { error in
            XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
        }
    }
}

private func makeFormat(sampleRate: Double) -> AVAudioFormat {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
}

private func makeBuffer(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount
) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    )!
    buffer.frameLength = frameCount

    if let samples = buffer.floatChannelData?[0] {
        for index in 0..<Int(frameCount) {
            samples[index] = sin(Float(index) * 0.1)
        }
    }
    return buffer
}

private func makeConverter(
    backend: any SpeechAudioConverterBackend
) throws -> SpeechAudioConverter {
    try SpeechAudioConverter(
        sourceFormat: makeFormat(sampleRate: 48_000),
        analyzerFormat: makeFormat(sampleRate: 16_000),
        backendFactory: { _, _ in backend }
    )
}

private final class FakeSpeechAudioConverterBackend: SpeechAudioConverterBackend {
    struct Response {
        let outcome: SpeechAudioConversionOutcome
        let frameLength: AVAudioFrameCount
    }

    private var responses: [Response]
    private(set) var receivedInputPresence: [Bool] = []

    init(outcome: SpeechAudioConversionOutcome) {
        responses = [.init(outcome: outcome, frameLength: 0)]
    }

    init(responses: [Response]) {
        self.responses = responses
    }

    func convert(
        into outputBuffer: AVAudioPCMBuffer,
        inputBuffer: AVAudioPCMBuffer?,
        exhaustedStatus: AVAudioConverterInputStatus
    ) -> SpeechAudioConversionOutcome {
        receivedInputPresence.append(inputBuffer != nil)
        let response = responses.removeFirst()
        outputBuffer.frameLength = response.frameLength
        return response.outcome
    }

    func reset() {}
}
