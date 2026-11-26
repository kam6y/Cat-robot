import Foundation
import Observation

@MainActor @Observable
final class SpeechVoiceSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "speech.supertonic.voicePreset"
    private static let wakePhraseKey = "speech.wakePhrase"
    private(set) var wakePhrase: String

    static func cleanedWakePhrase(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    @discardableResult
    func saveWakePhrase(_ phrase: String) -> Bool {
        let trimmed = Self.cleanedWakePhrase(phrase)
        guard !AddresseePolicy.words(in: trimmed).isEmpty else { return false }
        wakePhrase = trimmed
        defaults.set(trimmed, forKey: Self.wakePhraseKey)
        return true
    }

    var selected: SpeechVoicePreset {
        didSet { defaults.set(selected.rawValue, forKey: Self.key) }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = Self.cleanedWakePhrase(defaults.string(forKey: Self.wakePhraseKey) ?? "")
        wakePhrase = AddresseePolicy.words(in: saved).isEmpty ? AddresseePolicy.defaultWakePhrase : saved
        selected = defaults.string(forKey: Self.key).flatMap(SpeechVoicePreset.init(rawValue:)) ?? .f1
    }
}
