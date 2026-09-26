import Foundation
import Observation

@MainActor @Observable
final class SpeechVoiceSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "speech.supertonic.voicePreset"
    var selected: SpeechVoicePreset {
        didSet { defaults.set(selected.rawValue, forKey: Self.key) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.key).flatMap(SpeechVoicePreset.init(rawValue:)) ?? .f1
    }
}
