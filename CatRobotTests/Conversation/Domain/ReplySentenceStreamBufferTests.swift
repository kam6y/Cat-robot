import XCTest
@testable import CatRobot

final class ReplySentenceStreamBufferTests: XCTestCase {
    func testPreparationHintDoesNotCommitOrLoseTrailingOriginalCharacters() throws {
        var buffer = ReplySentenceStreamBuffer()
        XCTAssertTrue(try buffer.receive("第一文。").isEmpty)
        XCTAssertEqual(buffer.preparationCandidate, .init(ordinal: 0, original: "第一文。"))
        let first = try buffer.receive("第一文。 \n第二文。")
        XCTAssertEqual(first, [.init(ordinal: 0, original: "第一文。 \n")])
        XCTAssertNil(buffer.preparationCandidate, "Later sentences use existing prefetch")
        let last = try buffer.receive("第一文。 \n第二文。", final: true)
        XCTAssertEqual(last, [.init(ordinal: 1, original: "第二文。")])
        XCTAssertEqual((first + last).map(\.original).joined(), "第一文。 \n第二文。")
    }

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
    func testMixedCaseURLRemainsProtectedAcrossSentenceSplits() throws {
        for scheme in ["HTTPS", "HtTp", "https"] {
            let original = "確認してね。\(scheme)://example.test/?q=iPhone&device=Bluetooth 次。最後。"
            var buffer = ReplySentenceStreamBuffer()
            var output: [SpeechSentence] = []
            for index in original.indices { output += try buffer.receive(String(original[...index])) }
            output += try buffer.receive(original, final: true)
            XCTAssertEqual(output.map(\.original).joined(), original)
        }
    }
    func testProtectsCodeAndOnlyAllowsUnsentSuffixRevision() throws {
        var buffer = ReplySentenceStreamBuffer()
        XCTAssertEqual(try buffer.receive("前。`iPhone。Bluetooth。`次。後").map(\.original), ["前。", "`iPhone。Bluetooth。`次。"])
        XCTAssertEqual(try buffer.receive("前。`iPhone。Bluetooth。`次。別", final: true).map(\.original), ["別"])
        XCTAssertThrowsError(try buffer.receive("改変。", final: true))
        XCTAssertThrowsError(try buffer.receive("前", final: true)) {
            XCTAssertEqual($0 as? ConversationServiceError, .modelGenerationFailed)
        }
        var unclosed = ReplySentenceStreamBuffer()
        XCTAssertTrue(try unclosed.receive("`iPhone。Bluetooth。次").isEmpty)
        var long = ReplySentenceStreamBuffer()
        XCTAssertThrowsError(try long.receive(String(repeating: "猫", count: 2001)))
    }
}

@MainActor
final class SpeechSentenceChannelTests: XCTestCase {
    func testPreparationHintsAreBoundedAndCommittedInputTakesPrecedence() async throws {
        let channel = SpeechSentenceChannel()
        await channel.offerPreparation(.init(ordinal: 0, original: "候補。"))
        await channel.offerPreparation(.init(ordinal: 0, original: "二つ目の候補。"))
        let hint = try await channel.nextInput()
        guard case .candidate(let candidate) = hint else { return XCTFail("Expected one preparation hint") }
        XCTAssertEqual(candidate.original, "候補。")
        try await channel.send(.init(ordinal: 0, original: "確定。"))
        await channel.offerPreparation(.init(ordinal: 0, original: "古い候補。"))
        await channel.finish()
        let committed = try await channel.next()
        let end = try await channel.nextInput()
        XCTAssertEqual(committed, .init(ordinal: 0, original: "確定。"))
        XCTAssertNil(end)

        let queued = SpeechSentenceChannel()
        await queued.offerPreparation(.init(ordinal: 0, original: "破棄する候補。"))
        try await queued.send(.init(ordinal: 0, original: "優先する確定文。"))
        await queued.finish()
        let value = try await queued.next()
        XCTAssertEqual(value?.original, "優先する確定文。")

        let failed = SpeechSentenceChannel()
        await failed.offerPreparation(.init(ordinal: 0, original: "失敗前の候補。"))
        await failed.finish(throwing: ConversationServiceError.modelGenerationFailed)
        do { _ = try await failed.nextInput(); XCTFail("Failure must discard the hint") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
    }

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
