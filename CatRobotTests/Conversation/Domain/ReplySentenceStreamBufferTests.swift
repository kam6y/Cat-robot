import XCTest
@testable import CatRobot

final class ReplySentenceStreamBufferTests: XCTestCase {
    func testSnapshotsPreserveEveryCharacterAcrossMultipleSentences() throws {
        for text in ["一文目。二文目。終わり", "「はい。」（次です！）最後。", "3.14とU.S.A.です。次。", "https://a.test/?q=a! 次。終わり", "```\niPhone。Bluetooth。\n```です。次。", "前。`閉じない。次。", "👩🏽‍🚀です。猫。終わり"] {
            var buffer = ReplySentenceStreamBuffer()
            var output: [SpeechSentence] = []
            for index in text.indices { output += try buffer.receive(String(text[...index])) }
            output += try buffer.receive(text, final: true)
            XCTAssertEqual(output.map(\.original).joined(), text)
            XCTAssertEqual(output.map(\.ordinal), Array(0..<output.count))
            XCTAssertTrue(try buffer.receive(text, final: true).isEmpty)
        }
    }
    func testProtectsCodeAndOnlyAllowsUnsentSuffixRevision() throws {
        var buffer = ReplySentenceStreamBuffer()
        XCTAssertEqual(try buffer.receive("前。`iPhone。Bluetooth。`次。後").map(\.original), ["前。", "`iPhone。Bluetooth。`次。"])
        XCTAssertEqual(try buffer.receive("前。`iPhone。Bluetooth。`次。別", final: true).map(\.original), ["別"])
        XCTAssertThrowsError(try buffer.receive("改変。", final: true))
        var unclosed = ReplySentenceStreamBuffer()
        XCTAssertTrue(try unclosed.receive("`iPhone。Bluetooth。次").isEmpty)
        var long = ReplySentenceStreamBuffer()
        XCTAssertThrowsError(try long.receive(String(repeating: "猫", count: 2001)))
    }
}

@MainActor
final class SpeechSentenceChannelTests: XCTestCase {
    func testBackpressurePreservesAllSentencesAndDrainsBeforeEnd() async throws {
        let channel = SpeechSentenceChannel(capacity: 2)
        let producer = Task {
            for ordinal in 0..<20 { try await channel.send(.init(ordinal: ordinal, original: "文\(ordinal)。")) }
            await channel.finish()
        }
        var ordinals: [Int] = []
        while let sentence = try await channel.next() { ordinals.append(sentence.ordinal) }
        try await producer.value
        XCTAssertEqual(ordinals, Array(0..<20))
    }
    func testCancellationAndFailureUnblockBothSides() async throws {
        let full = SpeechSentenceChannel(capacity: 1)
        try await full.send(.init(ordinal: 0, original: "一。"))
        let sender = Task { try await full.send(.init(ordinal: 1, original: "二。")) }
        sender.cancel()
        do { try await sender.value; XCTFail("cancelled send succeeded") } catch {}
        await full.finish(throwing: ConversationServiceError.modelGenerationFailed)
        do { _ = try await full.next(); XCTFail("buffer must be discarded on failure") } catch {}
        let empty = SpeechSentenceChannel(capacity: 1)
        let receiver = Task { try await empty.next() }
        receiver.cancel()
        do { _ = try await receiver.value; XCTFail("cancelled receive succeeded") } catch {}
        let another = Task { try await empty.next() }
        await empty.finish(throwing: ConversationServiceError.modelGenerationFailed)
        do { _ = try await another.value; XCTFail("closed channel succeeded") } catch {}
    }
}
