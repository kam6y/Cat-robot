import XCTest
@testable import CatRobot

@MainActor
final class JapanesePronunciationServiceTests: XCTestCase {
    private var dictionary: URL { (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("dictionary") }

    func testLargeNumberReadingChangesOnlyNumericalSpans() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for (input, expected) in [
            ("1500000円。", "百五十万円。"),
            ("残高は1,500,000円だよ。", "残高は百五十万円だよ。"),
            ("３億５０００万だよ。", "三億五千万だよ。"),
            ("１，２３４個あるよ。", "千二百三十四個あるよ。"),
            ("1500000人で分けるよ。", "百五十万人で分けるよ。"),
        ] {
            let actual = try await service.normalize(input)
            XCTAssertEqual(actual, expected, input)
        }
        let long = String(repeating: "あ", count: 125) + "1,500,000円。"
        let spoken = try await service.normalize(long)
        XCTAssertTrue(SpeechTextAudit(input: spoken).processedChunks.contains { $0.contains("百五十万円") },
                      "Upstream chunking must receive a whole quantity rather than comma-separated digit fragments")
    }

    func testNumericalReadingPreservesAmbiguousAndProtectedNotation() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for original in [
            "3人で25個を分けるよ。", "2026年7月30日",
            "001500000", "1,2,3", "1,50,000", "1,500,000.5",
            "12345/67890", "12345:67890", "α1500000", "zzqx1500000",
            "https://example.test/1,500,000", "a1500000@example.test", "`1,500,000円`",
        ] {
            let actual = try await service.normalize(original)
            XCTAssertEqual(actual, original)
        }
        let labelledID = try await service.normalize("ID:123456789")
        XCTAssertEqual(labelledID, "アイディー:\n\nイチ\n\nニ\n\nサン\n\nヨン\n\nゴ\n\nロク\n\nナナ\n\nハチ\n\nキュー\n\n")
    }

    func testDecimalPercentClockPhoneAndIDCarryTheirMeaningToSynthesis() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for (original, expected) in [
            ("3.14だよ。", "サンテンイチヨンだよ。"),
            ("25%だよ。", "ニジューゴパーセントだよ。"),
            ("7:30に起こしてね。", "七時三十分に起こしてね。"),
            ("090-1234-5678だよ。", "ゼロキューゼロ、イチニーサンヨン、ゴーロクナナハチだよ。"),
            ("IDは123456789だよ。", "アイディーは\n\nイチ\n\nニ\n\nサン\n\nヨン\n\nゴ\n\nロク\n\nナナ\n\nハチ\n\nキュー\n\nだよ。"),
        ] {
            let spoken = try await service.normalize(original)
            XCTAssertEqual(spoken, expected)
        }
    }

    func testIDDigitsUseSeparateUpstreamChunksWithTheirOriginalContext() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        let spoken = try await service.normalize("IDは123456789だよ。")
        let chunks = SpeechTextAudit(input: spoken).processedChunks.map {
            $0.precomposedStringWithCanonicalMapping
        }
        XCTAssertEqual(chunks.count, 11)
        guard chunks.count == 11 else { return }
        XCTAssertTrue(chunks[0].contains("アイディーは"))
        for (index, digit) in ["イチ", "ニ", "サン", "ヨン", "ゴ", "ロク", "ナナ", "ハチ", "キュー"].enumerated() {
            XCTAssertTrue(chunks[index + 1].contains(digit), "Missing digit in chunk \(index + 1)")
        }
        XCTAssertTrue(chunks[10].contains("だよ"))
    }

    func testIDPausesAlsoObeyTheExpandedSynthesisLimit() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        let original = "IDは" + String(repeating: "1234567890", count: 90)
        do {
            _ = try await service.normalize(original)
            XCTFail("Digit separators must count toward the 2000-character synthesis limit")
        } catch {
            XCTAssertEqual(error as? JapanesePronunciationError, .outputTooLong)
        }
    }

    func testExplicitNumericContextsAcrossTheNativeBoundary() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for (original, expected) in [
            ("IDは0123456789", "アイディーは\n\nゼロ\n\nイチ\n\nニ\n\nサン\n\nヨン\n\nゴ\n\nロク\n\nナナ\n\nハチ\n\nキュー\n\n"),
            ("電話は090-1234-5678", "電話はゼロキューゼロ、イチニーサンヨン、ゴーロクナナハチ"),
            ("7:30〜8:30に集合", "7:30〜8:30に集合"),
            ("バージョン：3.14", "バージョン：3.14"),
        ] {
            let spoken = try await service.normalize(original)
            XCTAssertEqual(spoken, expected)
        }
    }

    func testNumericExpansionCannotExceedTheSynthesisLimit() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        do {
            _ = try await service.normalize(String(repeating: "12345 ", count: 333))
            XCTFail("Expanded number readings must not reach synthesis above 2000 characters")
        } catch {
            XCTAssertEqual(error as? JapanesePronunciationError, .outputTooLong)
        }
    }

    func testCorrectionKeepsNaturalJapaneseAroundLatinTerms() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for (input, expected) in [
            ("YouTubeで動画を見て、友達と共有するよ。", "ユーチューブで動画を見て、友達と共有するよ。"),
            ("こんにちは。今日も一緒に遊ぼうね。", "こんにちは。今日も一緒に遊ぼうね。"),
            ("iPhoneとBluetoothを使う。", "アイフォーンとブルートゥースを使う。"),
            ("+ボタンを押してね。", "プラスボタンを押してね。"),
        ] {
            let output = try await service.normalize(input)
            XCTAssertEqual(output, expected, input)
        }
    }

    func testRealDictionaryReadsNamesOperatorsAndJapanese() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for (input, expected) in [
            ("YouTubeを見よう。", "ユーチューブを見よう。"),
            ("+ボタンを押してね。", "プラスボタンを押してね。"),
            ("iPhoneとBluetooth。", "アイフォーンとブルートゥース。"),
            ("3人と25%。", "3人とニジューゴパーセント。"),
            ("Disney+を見よう。", "ディズニープラスを見よう。"),
            ("+ボタンを押してね♪", "プラスボタンを押してね♪"),
            ("｢+ボタン｣", "｢プラスボタン｣"),
            ("“iPhone”", "“アイフォーン”"),
        ] {
            let output = try await service.normalize(input)
            XCTAssertEqual(output, expected, input)
        }
    }

    func testProtectedAndUnknownContentSurvivesConversion() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for input in ["HTTPS://example.test/iPhone?q=YouTube+Bluetooth", "a+youtube@example.test", "`YouTube + iPhone`", "zzqx987", "👩🏽‍🚀"] {
            let output = try await service.normalize(input)
            XCTAssertEqual(output, input)
        }
        var buffer = ReplySentenceStreamBuffer()
        let original = "見てね。HTTPS://example.test/?q=YouTube+iPhone 次。"
        let sentences = try buffer.receive(original, final: true)
        var spoken = ""
        for sentence in sentences { spoken += try await service.normalize(sentence.original) }
        XCTAssertEqual(sentences.map(\.original).joined(), original)
        XCTAssertTrue(spoken.contains("HTTPS://example.test/?q=YouTube+iPhone"))
    }

    func testPreparedDictionaryIsReusedWithoutReadingItsPathAgain() async throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dictionary)
        defer { try? FileManager.default.removeItem(at: link) }
        let service = JapanesePronunciationService(root: link)
        try await service.prepare()
        try FileManager.default.removeItem(at: link)
        try await service.prepare()
        let output = try await service.normalize("YouTube")
        XCTAssertEqual(output, "ユーチューブ")
    }

    func testFailedPreparationStaysFailedAndNeverReturnsOriginalText() async throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: link) }
        let service = JapanesePronunciationService(root: link)
        do { try await service.prepare(); XCTFail("missing dictionary succeeded") }
        catch { XCTAssertEqual(error as? JapanesePronunciationError, .dictionaryUnavailable) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dictionary)
        do { _ = try await service.normalize("iPhone"); XCTFail("failed service returned speech text") }
        catch { XCTAssertEqual(error as? JapanesePronunciationError, .dictionaryUnavailable) }
    }

    func testInputAndExpandedOutputLimitsNeverTruncateOrBypassConversion() async throws {
        let service = JapanesePronunciationService(root: dictionary)
        for input in ["", " \n", "a\0b", String(repeating: "猫", count: 2001), "a" + String(repeating: "\u{0301}", count: 17_000)] {
            do { _ = try await service.normalize(input); XCTFail("invalid input succeeded") }
            catch { XCTAssertEqual(error as? JapanesePronunciationError, .invalidInput) }
        }
        let boundary = try await service.normalize(String(repeating: "+", count: 666) + "12")
        XCTAssertEqual(boundary, String(repeating: "プラス", count: 666) + "12")
        do { _ = try await service.normalize(String(repeating: "+", count: 667)); XCTFail("expanded output exceeded engine limit") }
        catch { XCTAssertEqual(error as? JapanesePronunciationError, .outputTooLong) }
    }
}
