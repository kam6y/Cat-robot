import SwiftUI

struct VoiceSettingsView: View {
    @Bindable var settings: SpeechVoiceSettings
    let onDone: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("声", selection: $settings.selected) {
                        ForEach(SpeechVoicePreset.allCases, id: \.self) { voice in
                            Text("Supertonic \(voice.rawValue)").tag(voice)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("voicePresetPicker")
                } footer: {
                    Text("選んだ声は次の会話から使います。初期設定はF1です。")
                }
            }
            .navigationTitle("声を選ぶ")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了", action: onDone) } }
        }
        .preferredColorScheme(.dark)
    }
}
