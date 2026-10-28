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
