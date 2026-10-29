import XCTest
@testable import CatRobot

@MainActor
final class JapanesePronunciationServiceTests: XCTestCase {
    private var dictionary: URL { (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("dictionary") }

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
            ("3人と25%。", "3人と25%。"),
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
