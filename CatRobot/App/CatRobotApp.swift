import SwiftUI

@main
struct CatRobotApp: App {
    private let composition: ConversationComposition?
    private let onboardingSettings: OnboardingSettings

    init() {
#if DEBUG
        // Dedicated speech trials own AVAudioSession and measure their first dictionary load.
        // Running the live scene alongside them would prepare the shared service early.
        if ProcessInfo.processInfo.environment["SUPER_INTEGRATION_TESTS"] == "1" {
            composition = nil
        } else {
            composition = .live()
        }
#else
        composition = .live()
#endif
        onboardingSettings = OnboardingSettings()
    }

    var body: some Scene {
        WindowGroup {
            if let composition {
                AppRootView(dependencies: composition.dependencies, voiceSettings: composition.voiceSettings,
                            modelSettings: composition.modelSettings, memory: composition.longTermMemory, usage: composition.usage,
                            robotSettings: composition.robotSettings, robotLink: composition.robotLink, faceTracking: composition.faceTracking, camera: composition.camera, onboardingSettings: onboardingSettings)
            } else {
                Color.clear
            }
        }
    }
}
