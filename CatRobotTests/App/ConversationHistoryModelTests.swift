import XCTest
@testable import CatRobot

/// 設定の「会話の履歴」。開くたびに Hermes から読み、未設定・キーの拒否・失われた会話・通信失敗を区別して出す。
@MainActor
final class ConversationHistoryModelTests: XCTestCase {
    func testTheTranscriptIsShownOldestFirstAsHermesReturnedIt() async {
        let entries = [HermesTranscriptEntry(speaker: .user, text: "こんにちは"), HermesTranscriptEntry(speaker: .cat, text: "やあ")]
        let model = ConversationHistoryModel(reader: ScriptedTranscriptReader([.success(entries)]))
        await model.reload()
        XCTAssertEqual(model.phase, .loaded(entries))
    }

    func testAnUnconfiguredConnectionIsNotReportedAsAFailure() async {
        let model = ConversationHistoryModel(reader: ScriptedTranscriptReader([.failure(ConversationServiceError.modelUnavailable(.hermesNotConfigured))]))
        await model.reload()
        XCTAssertEqual(model.phase, .unconfigured)
    }

    func testFailuresSayWhatToDoAndAReloadReadsAgain() async throws {
        let entries = [HermesTranscriptEntry(speaker: .user, text: "もう一度")]
        let reader = ScriptedTranscriptReader([.failure(ConversationServiceError.modelUnavailable(.hermesUnauthorized)),
                                                .failure(ConversationMemoryError.unavailable),
                                                .failure(HermesClientError.transport("NSURLErrorDomain -1009")),
                                                .success(entries)])
        let model = ConversationHistoryModel(reader: reader)
        var messages: [String] = []
        for _ in 0..<3 {
            await model.reload()
            guard case .failed(let message) = model.phase else { return XCTFail("\(model.phase)") }
            messages.append(message)
        }
        XCTAssertTrue(messages[0].contains("API キー"), messages[0])
        XCTAssertTrue(messages[0].contains("もう一度確認"), "a refused key is checked again from the conversation screen: \(messages[0])")
        XCTAssertTrue(messages[1].contains("新しい会話"), messages[1])
        XCTAssertFalse(messages[1].contains("削除"), messages[1])
        XCTAssertTrue(messages[2].contains("通信"), messages[2])
        await model.reload()
        XCTAssertEqual(model.phase, .loaded(entries))
        let reads = await reader.reads
        XCTAssertEqual(reads, 4, "each reload reads Hermes again; nothing is cached on the iPhone")
    }
}

/// 台本どおりに履歴を返す読み手。
actor ScriptedTranscriptReader: ConversationTranscriptReading {
    private var results: [Result<[HermesTranscriptEntry], Error>]
    private(set) var reads = 0
    init(_ results: [Result<[HermesTranscriptEntry], Error>]) { self.results = results }
    func transcript() throws -> [HermesTranscriptEntry] {
        reads += 1
        return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
}
