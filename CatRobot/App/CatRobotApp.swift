import SwiftUI

@main
struct CatRobotApp: App {
    private let voiceSettings: SpeechVoiceSettings
    private let dependencies: ConversationDependencies

    init() {
        let settings = SpeechVoiceSettings()
        voiceSettings = settings
        dependencies = .live(voiceSettings: settings)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(dependencies: dependencies, voiceSettings: voiceSettings)
        }
    }
}
