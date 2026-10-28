import SwiftUI

/// 黒い画面に目・鼻・口・ひげだけを描く猫の顔。親が 16:9 の領域へ等比配置する。
struct CatFaceView: View {
    let expression: FaceExpression
    let mouthPose: MouthPose
    let reduceMotion: Bool
    /// 周期的な装飾（まばたき）を動かしてよいか。音声・首・録音には関与しない。
    let isAnimating: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.scenePhase) private var scenePhase
    /// 0 で開き、1 で閉じたまばたきの量。
    @State private var blink: CGFloat = 0

    init(expression: FaceExpression, mouthPose: MouthPose, reduceMotion: Bool, isAnimating: Bool) {
        self.expression = expression
        self.mouthPose = mouthPose
        self.reduceMotion = reduceMotion
        self.isAnimating = isAnimating
    }

    var body: some View {
        GeometryReader { proxy in
            let size = fittedSize(in: proxy.size)
            CatFaceCanvas(appearance: .preset(expression),
                          mouthOpening: CatFaceGeometry.mouthOpening(for: mouthPose),
                          blink: blink,
                          lineScale: colorSchemeContrast == .increased ? 1.35 : 1)
                .animation(interpolates ? .easeInOut(duration: 0.25) : nil, value: expression)
                .animation(interpolates ? .easeInOut(duration: 0.14) : nil, value: mouthPose)
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(CatFaceGeometry.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
        .task(id: blinksPeriodically) { await blinkWhileAllowed() }
    }

    /// 表情と口の補間。Reduce Motion と非 active では止め、静止形と口の違いだけを残す。
    private var interpolates: Bool {
        !reduceMotion && scenePhase == .active
    }

    private var blinksPeriodically: Bool {
        expression == .neutral && isAnimating && !reduceMotion && scenePhase == .active
    }

    /// neutral のときだけ 3.5 秒ごとに 0.10 秒で閉じ 0.12 秒で開く。取り消されたら開いた状態で終える。
    private func blinkWhileAllowed() async {
        blink = 0
        guard blinksPeriodically else { return }
        defer { blink = 0 }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.5 - 0.10 - 0.12))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.10)) { blink = 1 }
            try? await Task.sleep(for: .seconds(0.10))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.12)) { blink = 0 }
            try? await Task.sleep(for: .seconds(0.12))
        }
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        let candidateHeight = available.width / CatFaceGeometry.aspectRatio
        if candidateHeight <= available.height {
            return CGSize(width: available.width, height: candidateHeight)
        }
        return CGSize(width: available.height * CatFaceGeometry.aspectRatio, height: available.height)
    }
}

/// 表情・口・まばたきの数値を補間しながら描く。
private struct CatFaceCanvas: View, Animatable {
    var appearance: CatFaceAppearance
    var mouthOpening: CGFloat
    var blink: CGFloat
    let lineScale: CGFloat

    nonisolated var animatableData: AnimatablePair<CatFaceAppearance.AnimationVector, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(appearance.animationVector, AnimatablePair(mouthOpening, blink)) }
        set {
            appearance.animationVector = newValue.first
            mouthOpening = newValue.second.first
            blink = newValue.second.second
        }
    }

    var body: some View {
        let renderer = CatFaceRenderer(appearance: appearance, mouthOpening: mouthOpening, blink: blink,
                                       lineScale: lineScale)
        Canvas { context, size in
            renderer.draw(in: &context, size: size)
        }
    }
}

private struct CatFaceRenderer {
    let appearance: CatFaceAppearance
    let mouthOpening: CGFloat
    let blink: CGFloat
    let lineScale: CGFloat

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let iris = Palette.Iris(brightness: appearance.irisBrightness)
        for side in CatFaceSide.allCases {
            drawEye(side: side, iris: iris, in: &context, rect: rect)
        }
        // 口の縦線の上端は鼻の下に隠し、採用画像どおり鼻とつながって見せる。
        drawMouth(in: &context, rect: rect)
        context.fill(CatFaceGeometry.nose().path(in: rect), with: .color(Palette.nose))
        for side in CatFaceSide.allCases {
            for whisker in CatFaceGeometry.whiskers(side: side, appearance: appearance, lineScale: lineScale) {
                context.fill(whisker.path(in: rect), with: .color(Palette.cream))
            }
        }
    }

    private func drawEye(side: CatFaceSide, iris: Palette.Iris, in context: inout GraphicsContext, rect: CGRect) {
        let eye = appearance.eye(side)
        let geometry = CatFaceGeometry.eye(side: side, appearance: appearance, blink: blink)
        let outline = geometry.outline.path(in: rect)

        if appearance.glow > 0.001 {
            // 輪郭のすぐ外にごく控えめな赤寄りの橙のにじみ（happy-b の縁の外の明るさの実測に合わせた）。
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: rect.height * 0.040))
                layer.fill(outline, with: .color(iris.glow.opacity(0.26 * appearance.glow)))
            }
        }

        context.drawLayer { layer in
            layer.clip(to: outline)
            let cap = Gradient(stops: zip(iris.cap, CatFaceGeometry.EyeGeometry.capGradientStops).map {
                Gradient.Stop(color: $0, location: $1)
            })
            layer.fill(outline, with: .linearGradient(cap,
                                                      startPoint: scaled(geometry.capGradientStart, rect),
                                                      endPoint: scaled(geometry.capGradientEnd, rect)))
            layer.fill(geometry.litRim.path(in: rect), with: .color(iris.bright))
            layer.fill(geometry.innerIris.path(in: rect), with: .color(iris.deep))
            layer.drawLayer { inner in
                inner.clip(to: geometry.innerIris.path(in: rect))
                inner.fill(geometry.innerLit.path(in: rect), with: .color(iris.lit))
            }
            layer.fill(geometry.pupil.path(in: rect), with: .color(Palette.background))
            layer.fill(geometry.highlight.path(in: rect), with: .color(Palette.highlight))
            if eye.dotOpacity > 0.001 {
                layer.fill(geometry.dot.path(in: rect), with: .color(Palette.highlight.opacity(eye.dotOpacity)))
            }
            if eye.sparkleOpacity > 0.001 {
                layer.fill(geometry.sparkle.path(in: rect), with: .color(Palette.cream.opacity(eye.sparkleOpacity)))
            }
        }

        if eye.lid > 0.001 || blink > 0.001 {
            context.fill(geometry.lid.path(in: rect), with: .color(Palette.background))
        }
        if eye.closed > 0.001 {
            context.fill(geometry.closedLid.path(in: rect), with: .color(Palette.closedLid.opacity(eye.closed)))
        }
    }

    private func drawMouth(in context: inout GraphicsContext, rect: CGRect) {
        let mouth = CatFaceGeometry.mouth(appearance: appearance, opening: mouthOpening, lineScale: lineScale)
        let style = StrokeStyle(lineWidth: rect.height * CatFaceGeometry.mouthLineWidth * lineScale,
                                lineCap: .round, lineJoin: .round)
        let lines = 1 - mouth.roundness
        if mouth.showsOpening {
            // 開き始めに線が急に現れないよう、小さい開きでは薄く描く。
            let visibility = min(1, mouth.opening / 0.012) * lines
            context.fill(mouth.cavity.path(in: rect), with: .color(Palette.mouthInside.opacity(visibility)))
            context.stroke(mouth.lowerLip.path(in: rect), with: .color(Palette.cream.opacity(visibility)), style: style)
        }
        if mouth.showsLines {
            // 縦棒（塗り）と弧（線）は重なるので、1 枚の層にまとめてから透明度をかける。
            context.drawLayer { layer in
                layer.opacity = lines
                layer.fill(mouth.neck.path(in: rect), with: .color(Palette.cream))
                for line in mouth.lines {
                    layer.stroke(line.path(in: rect), with: .color(Palette.cream), style: style)
                }
            }
        }
        if mouth.showsRound {
            let round = mouth.round.path(in: rect)
            context.fill(round, with: .color(Palette.mouthInside.opacity(mouth.roundness)))
            context.stroke(round, with: .color(Palette.cream.opacity(mouth.roundness)), style: style)
        }
    }

    private func scaled(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}

/// 色は neutral-b / happy-b の画素の実測値（visual-comparison.md）。
private enum Palette {
    static let background = Color.black
    static let highlight = rgb(0xFC, 0xFB, 0xF9)
    static let cream = rgb(0xF9, 0xE9, 0xCB)
    static let nose = rgb(0xFB, 0x8B, 0x6D)
    static let mouthInside = rgb(0x3A, 0x1A, 0x1E)
    /// 閉じた目の弧（sleeping）。下書き sleeping-draft.png の弧の内側（縁から 2px 以上）の中央値 #FDCA44 / #FDCA43 の実測。
    /// 虹彩の明るい黄 #FDCA40 より青が 3 段階強い。
    static let closedLid = rgb(0xFD, 0xCA, 0x43)

    /// 虹彩の色と縁の光。brightness 0 が neutral-b、1 が happy-b。
    struct Iris {
        let bright: Color
        /// 上の陰のグラデーション（外側 → 鼻側。位置は EyeGeometry.capGradientStops）。
        let cap: [Color]
        let deep: Color
        let lit: Color
        let glow: Color

        init(brightness t: CGFloat) {
            bright = Palette.mix((0xFD, 0xCA, 0x40), (0xFD, 0xD1, 0x3C), t)
            let outer = Palette.mix((0xD6, 0x89, 0x20), (0xE9, 0x95, 0x0E), t)
            let middle = Palette.mix((0xD6, 0x89, 0x20), (0xE0, 0x8C, 0x14), t)
            // 鼻側の縁の帯は中間の琥珀（濃い琥珀は瞳を囲む層だけ）。
            let inner = Palette.mix((0xCD, 0x7B, 0x0E), (0xE0, 0x8C, 0x14), t)
            cap = [outer, middle, middle, inner]
            deep = Palette.mix((0xBF, 0x6D, 0x14), (0xBF, 0x6A, 0x0E), t)
            lit = Palette.mix((0xEE, 0x96, 0x27), (0xF4, 0x9A, 0x20), t)
            glow = Palette.rgb(0xFF, 0x7D, 0x05)
        }
    }

    private static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: CGFloat) -> Color {
        let t = Double(min(max(t, 0), 1))
        return Color(.sRGB,
                     red: (a.0 + (b.0 - a.0) * t) / 255,
                     green: (a.1 + (b.1 - a.1) * t) / 255,
                     blue: (a.2 + (b.2 - a.2) * t) / 255)
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
}

#if DEBUG
#Preview("Expressions") {
    VStack(spacing: 8) {
        ForEach(FaceExpression.allCases, id: \.self) { expression in
            CatFaceView(expression: expression, mouthPose: .closed, reduceMotion: true, isAnimating: false)
                .frame(height: 120)
        }
    }
    .padding()
    .background(Color.black)
}
#endif
