import SwiftUI

@main
struct CatRobotApp: App {
    let composition: ConversationComposition?
    private let onboardingSettings: OnboardingSettings
#if DEBUG
    let isHermesProbe: Bool
#endif

    init() {
#if DEBUG
        self.init(environment: ProcessInfo.processInfo.environment)
#else
        composition = .live()
        onboardingSettings = OnboardingSettings()
#endif
    }

#if DEBUG
    init(environment: [String: String]) {
        isHermesProbe = environment["HERMES_PROBE"] == "1"
        // Dedicated speech trials own AVAudioSession and measure their first dictionary load.
        // Running the live scene alongside them would prepare the shared service early.
        if isHermesProbe || environment["SUPER_INTEGRATION_TESTS"] == "1" {
            composition = nil
        } else {
            composition = .live()
        }
        onboardingSettings = OnboardingSettings()
    }
#endif

    var body: some Scene {
        WindowGroup {
            if let composition {
                AppRootView(composition: composition, onboardingSettings: onboardingSettings)
            } else {
#if DEBUG
                if isHermesProbe {
                    HermesProbeHostView()
                } else {
                    Color.clear
                }
#else
                Color.clear
#endif
            }
        }
    }
}
