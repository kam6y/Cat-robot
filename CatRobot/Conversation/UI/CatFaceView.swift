import SwiftUI

/// 黒い画面に目・鼻・口・ひげだけを描く猫の顔。親が 16:9 の領域へ等比配置する。
struct CatFaceView: View {
    let expression: FaceExpression
    let mouthPose: MouthPose
    let reduceMotion: Bool
    /// Conversation-owned sparse keyframes (blinks, glances, the yawn); static render tools use the same path.
    /// nil のときは expression のプリセットを静止で描く。
    let appearanceOverride: CatFaceAppearance?

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.scenePhase) private var scenePhase

    init(expression: FaceExpression, mouthPose: MouthPose, reduceMotion: Bool, appearanceOverride: CatFaceAppearance? = nil) {
        self.expression = expression
        self.mouthPose = mouthPose
        self.reduceMotion = reduceMotion
        self.appearanceOverride = appearanceOverride
    }

    var body: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            CatFaceCanvas(appearance: appearanceOverride ?? .preset(expression),
                          mouthOpening: CatFaceGeometry.mouthOpening(for: mouthPose),
                          lineScale: colorSchemeContrast == .increased ? 1.35 : 1)
                .animation(interpolates ? .easeInOut(duration: 0.25) : nil, value: expression)
                .animation(interpolates ? .easeInOut(duration: 0.14) : nil, value: mouthPose)
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(CatFaceGeometry.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// 表情と口の補間。Reduce Motion と非 active では止め、静止形と口の違いだけを残す。
    private var interpolates: Bool {
        !reduceMotion && scenePhase == .active
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        let candidateHeight = available.width / CatFaceGeometry.aspectRatio
        if candidateHeight <= available.height {
            return CGSize(width: available.width, height: candidateHeight)
        }
        return CGSize(width: available.height * CatFaceGeometry.aspectRatio, height: available.height)
    }
}
