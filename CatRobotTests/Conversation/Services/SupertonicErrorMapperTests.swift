import XCTest
@testable import CatRobot
final class SupertonicErrorMapperTests: XCTestCase {
    func testUnavailableAssetsAreDistinguishedFromInferenceFailure() {
        for error in [SupertonicError.missingAssets, .invalidAssets, .unsupportedVoice] {
            XCTAssertEqual(SupertonicErrorMapper.map(error), .speechVoiceUnavailable)
        }
        XCTAssertEqual(SupertonicErrorMapper.map(SupertonicError.inferenceFailed), .speechSynthesisFailed)
    }

    func testDictionaryAndCancellationErrorsMapDirectlyToSynthesisFailure() {
        XCTAssertEqual(SupertonicErrorMapper.map(JapanesePronunciationError.dictionaryUnavailable), .speechSynthesisFailed)
        XCTAssertEqual(SupertonicErrorMapper.map(CancellationError()), .speechSynthesisFailed)
    }

    func testMappingRunsTheOperationOnceAndReturnsItsValue() async throws {
        let calls = OperationCounter()
        let text = try await SupertonicErrorMapper.mapping { () async throws -> String in
            await calls.increment(); return "よみ"
        }
        let pcm = try await SupertonicErrorMapper.mapping { () async throws -> SpeechPCM in
            await calls.increment(); return SpeechPCM(samples: [0.25, -0.5], sampleRate: 24_000)
        }
        let count = await calls.count
        XCTAssertEqual(text, "よみ")
        XCTAssertEqual(pcm.samples, [0.25, -0.5])
        XCTAssertEqual(pcm.sampleRate, 24_000)
        XCTAssertEqual(count, 2)
    }

    func testMappingKeepsCancellationAndOtherwiseMatchesMap() async {
        let cases: [(error: any Error, expected: ConversationServiceError)] = [
            (CancellationError(), .cancelled),
            (SupertonicError.missingAssets, .speechVoiceUnavailable),
            (SupertonicError.invalidAssets, .speechVoiceUnavailable),
            (SupertonicError.unsupportedVoice, .speechVoiceUnavailable),
            (SupertonicError.inferenceFailed, .speechSynthesisFailed),
            (JapanesePronunciationError.dictionaryUnavailable, .speechSynthesisFailed),
        ]
        for row in cases {
            let thrown = row.error
            do {
                _ = try await SupertonicErrorMapper.mapping { () async throws -> Int in throw thrown }
                XCTFail("\(thrown) must be rethrown")
            } catch {
                XCTAssertEqual(error as? ConversationServiceError, row.expected, "\(thrown)")
            }
        }
    }
}

private actor OperationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
