import SwiftUI

/// ConversationView.faceLayout と同じ全画面基準の枠・safe area の水平中央・画面の垂直中央を使う。
/// 配置式を変えるときは本体側も更新する（scale は画面に対する絶対倍率）。
struct FaceSizePreview: View {
    let scale: Double
    let expression: FaceExpression

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                CatFaceView(expression: expression, mouthPose: .closed, reduceMotion: true)
                    .frame(width: (proxy.size.width + insets.leading + insets.trailing) * CGFloat(scale),
                           height: (proxy.size.height + insets.top + insets.bottom) * CGFloat(scale))
                    .position(x: proxy.size.width / 2, y: (proxy.size.height + insets.bottom - insets.top) / 2)
            }
        }
    }
}
