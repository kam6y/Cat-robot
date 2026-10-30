import SwiftUI

/// 初回だけ出す説明画面。`isReview` のときは設定から見直す用途で、ボタンは閉じるだけにする。
struct OnboardingView: View {
    let onStart: () -> Void
    var isReview = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView { singleColumn }
            } else {
                // 標準の文字サイズでは1画面に収める。それでも入らない大きさだけスクロールに逃がす。
                ViewThatFits(in: .vertical) {
                    twoColumns
                    ScrollView { twoColumns }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var twoColumns: some View {
        HStack(alignment: .center, spacing: 36) {
            intro.frame(width: 250)
            points.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var singleColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            intro.frame(maxWidth: .infinity)
            points
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            CatFaceView(expression: .neutral, mouthPose: .closed, reduceMotion: true)
                .frame(width: 250, height: 115)
            Text("AIの猫と話そう")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button(isReview ? "閉じる" : "会話を始める", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityHint(isReview ? "説明を閉じます" : "会話画面を開きます")
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 14) {
            point("返事は Anthropic の Claude が作ります。送るのは話しかけた文字・会話の要約・覚えたことと、「見て」と頼んだときの静止画像1枚。音声や動画は送りません",
                  systemImage: "cloud")
            point("聞き取り・読み上げ・記憶はこのiPhoneの中。マイクは会話画面を開いている間だけ使います。記憶はいつでも消せます",
                  systemImage: "iphone")
            point("AIの返事は間違うことがあります。利用料は作者の負担です", systemImage: "exclamationmark.triangle")
            Text("カメラの許可とこの説明は、あとから「設定」で確認できます")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .font(.callout)
    }

    private func point(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onStart: {})
}
