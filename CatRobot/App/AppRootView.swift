import SwiftUI

struct AppRootView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Text(AppIdentity.displayName)
                .font(.largeTitle)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
