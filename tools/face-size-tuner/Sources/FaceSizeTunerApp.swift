import SwiftUI

@main
struct FaceSizeTunerApp: App {
    @StateObject private var model = FaceSizeTuningModel()

    var body: some Scene {
        WindowGroup {
            FaceSizeTunerView(model: model)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
