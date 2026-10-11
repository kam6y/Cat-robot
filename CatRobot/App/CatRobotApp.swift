import SwiftUI

@main
struct CatRobotApp: App {
    private let composition: ConversationComposition

    init() { composition = .live() }

    var body: some Scene {
        WindowGroup {
            AppRootView(dependencies: composition.dependencies, voiceSettings: composition.voiceSettings,
                        modelSettings: composition.modelSettings, memory: composition.longTermMemory, usage: composition.usage)
        }
    }
}
