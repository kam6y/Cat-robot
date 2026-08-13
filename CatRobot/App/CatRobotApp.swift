import SwiftUI

@main
struct CatRobotApp: App {
    private let dependencies: ConversationDependencies

    init() {
        dependencies = .live()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(dependencies: dependencies)
        }
    }
}
