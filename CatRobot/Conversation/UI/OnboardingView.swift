import SwiftUI

struct OnboardingView: View {
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 24)

                Text("AIの猫と話そう")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 16) {
                    Label("音声と会話はこのiPhone上で処理されます", systemImage: "iphone")
                    Label("マイクは会話画面を開いている間だけ使います", systemImage: "mic")
                    Label("AIの返事には間違いが含まれることがあります", systemImage: "exclamationmark.triangle")
                }
                .font(.body)

                Button("会話を始める", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .accessibilityHint("会話画面を開きます")
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(Color(uiColor: .label))
        .preferredColorScheme(.dark)
    }
}

#Preview {
    OnboardingView(onStart: {})
}
