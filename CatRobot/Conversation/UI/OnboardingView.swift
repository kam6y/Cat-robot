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
            point("返事は設定した Hermes の接続先が作り、会話の続きと履歴も Hermes に残ります。送るのは話しかけた文字だけで、音声や映像は送りません。声で話しかけたときは、猫に話しかけたかの判定に Anthropic の Claude も使います",
                  systemImage: "cloud")
            point("聞き取りと読み上げはこのiPhoneの中。マイクは会話画面を開いている間だけ使います。「新しい会話を始める」は Hermes で新しい会話に切り替えます。前の会話を Hermes から消すことはしません",
                  systemImage: "iphone")
            point("AIの返事は間違うことがあります。利用料は作者の負担です", systemImage: "exclamationmark.triangle")
            Text("聞き取り中はカメラで顔の向きを確認し、こちらを向いていればすぐ返答します。顔の判定はiPhone内だけで行います。カメラの許可とこの説明は、あとから「設定」で確認できます")
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
