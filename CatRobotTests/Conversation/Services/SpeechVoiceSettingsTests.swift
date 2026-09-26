import XCTest
@testable import CatRobot

@MainActor
final class SpeechVoiceSettingsTests: XCTestCase {
    func testDefaultInvalidValueAndEveryPresetSurviveRelaunch() {
        let name = "VoiceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SpeechVoiceSettings(defaults: defaults).selected, .f1)
        defaults.set("../../unknown", forKey: "speech.supertonic.voicePreset")
        XCTAssertEqual(SpeechVoiceSettings(defaults: defaults).selected, .f1)
        XCTAssertEqual(SpeechVoicePreset.allCases.map(\.rawValue), ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"])
        for preset in SpeechVoicePreset.allCases {
            SpeechVoiceSettings(defaults: defaults).selected = preset
            XCTAssertEqual(SpeechVoiceSettings(defaults: defaults).selected, preset)
        }
    }
}

final class SpeechPronunciationNormalizerTests: XCTestCase {
    func testCuratedWordsRespectBoundariesAndPreserveOriginal() {
        let cases: [(String, String)] = [
            ("iPhoneケースとBluetoothを使う。", "アイフォーンケースとブルートゥースを使う。"),
            ("IPHONE bluetooth iPhone 16 Pro", "アイフォーン ブルートゥース アイフォーン 16 Pro"),
            ("myiPhone iPhone16 _Bluetooth Bluetooth_2", "myiPhone iPhone16 _Bluetooth Bluetooth_2"),
            ("猫🐱とiPhone。Unknown。", "猫🐱とアイフォーン。Unknown。"),
            ("", ""),
            ("https://a.test/iPhone?q=Bluetooth iPhone", "https://a.test/iPhone?q=Bluetooth アイフォーン"),
            ("連絡a@Bluetooth.test、iPhone", "連絡a@Bluetooth.test、アイフォーン"),
            ("`iPhone。Bluetooth。` iPhone", "`iPhone。Bluetooth。` アイフォーン"),
            ("```swift\niPhone。\nBluetooth\n```Bluetooth", "```swift\niPhone。\nBluetooth\n```ブルートゥース"),
            ("iPhone `Bluetooth iPhone", "アイフォーン `Bluetooth iPhone")
        ]
        let normalizer = SpeechPronunciationNormalizer()
        for (source, expected) in cases {
            XCTAssertEqual(normalizer.normalize(source), expected, source)
            XCTAssertEqual(normalizer.normalize(normalizer.normalize(source)), expected, source)
        }
    }
}
