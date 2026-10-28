import SwiftUI

@main
struct CatRobotApp: App {
    private let composition: ConversationComposition
    private let onboardingSettings: OnboardingSettings

    init() {
        composition = .live()
        onboardingSettings = OnboardingSettings()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(dependencies: composition.dependencies, voiceSettings: composition.voiceSettings,
                        modelSettings: composition.modelSettings, memory: composition.longTermMemory, usage: composition.usage,
                        robotSettings: composition.robotSettings, robotLink: composition.robotLink, faceTracking: composition.faceTracking, camera: composition.camera, onboardingSettings: onboardingSettings)
        }
    }
}
