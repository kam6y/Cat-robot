import SwiftUI

/// 表情（まばたきを含む）・口の数値を補間しながら描く。
struct CatFaceCanvas: View, Animatable {
    var appearance: CatFaceAppearance
    var mouthOpening: CGFloat
    let lineScale: CGFloat

    nonisolated var animatableData: AnimatablePair<CatFaceAppearance.AnimationVector, CGFloat> {
        get { AnimatablePair(appearance.animationVector, mouthOpening) }
        set {
            appearance.animationVector = newValue.first
            mouthOpening = newValue.second
        }
    }

    var body: some View {
        let renderer = CatFaceRenderer(appearance: appearance, mouthOpening: mouthOpening, lineScale: lineScale)
        Canvas { context, size in
            renderer.draw(in: &context, size: size)
        }
    }
}

private struct CatFaceRenderer {
    let appearance: CatFaceAppearance
    let mouthOpening: CGFloat
    let lineScale: CGFloat

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let iris = Palette.Iris(brightness: appearance.irisBrightness)
        for side in CatFaceSide.allCases {
            drawEye(side: side, iris: iris, in: &context, rect: rect)
        }
        // 口の縦線の上端（あくびでは口の輪郭の上中央の尖り）は鼻の下に隠し、採用画像どおり鼻とつながって見せる。
        drawMouth(in: &context, rect: rect)
        context.fill(CatFaceGeometry.nose(yawn: appearance.yawn).path(in: rect), with: .color(Palette.nose))
        for side in CatFaceSide.allCases {
            for whisker in CatFaceGeometry.whiskers(side: side, appearance: appearance, lineScale: lineScale) {
                context.fill(whisker.path(in: rect), with: .color(Palette.cream))
            }
        }
        // 眠りの Z は右目の黒いまぶたと重なる位置にあるので、目より後に描く。
        if appearance.sleepMarks > 0.001 {
            for mark in CatFaceGeometry.sleepMarks() {
                context.fill(mark.path(in: rect), with: .color(Palette.sleepMark.opacity(appearance.sleepMarks)))
            }
        }
    }

    private func drawEye(side: CatFaceSide, iris: Palette.Iris, in context: inout GraphicsContext, rect: CGRect) {
        let eye = appearance.eye(side)
        let geometry = CatFaceGeometry.eye(side: side, appearance: appearance)
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

        if eye.lid > 0.001 || eye.blink > 0.001 {
            context.fill(geometry.lid.path(in: rect), with: .color(Palette.background))
        }
        // まばたきで閉じきる直前（CatFaceGeometry.closedArcStart から）は sleeping と同じ金色の弧を出し、閉じた目が真っ黒に
        // 消えないようにする。半目の瞬きでは上下のまぶたがこの弧へ寄り、同じ輪郭のまま閉眼へつながる。
        let closed = max(eye.closed, CatFaceGeometry.closedArcVisibility(eye.blink))
        if closed > 0.001 {
            context.fill(geometry.closedLid.path(in: rect), with: .color(Palette.closedLid.opacity(closed)))
        }
    }

    private func drawMouth(in context: inout GraphicsContext, rect: CGRect) {
        let mouth = CatFaceGeometry.mouth(appearance: appearance, opening: mouthOpening, lineScale: lineScale)
        let style = StrokeStyle(lineWidth: rect.height * CatFaceGeometry.mouthLineWidth * lineScale,
                                lineCap: .round, lineJoin: .round)
        // あくびの口へ切り替わる間は、ω・丸い口を薄くしていく。
        let usual = 1 - mouth.yawnBlend
        let lines = (1 - mouth.roundness) * usual
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
            context.fill(round, with: .color(Palette.mouthInside.opacity(mouth.roundness * usual)))
            context.stroke(round, with: .color(Palette.cream.opacity(mouth.roundness * usual)), style: style)
        }
        if mouth.showsYawn {
            // あくびの口: 暗い内側 → 舌（内側で切り抜く）→ 牙 → クリーム色の輪郭線。重なるので 1 枚の層にまとめて透明度をかける。
            context.drawLayer { layer in
                layer.opacity = mouth.yawnBlend
                let outline = mouth.yawnOutline.path(in: rect)
                layer.fill(outline, with: .color(Palette.mouthInside))
                layer.drawLayer { inside in
                    inside.clip(to: outline)
                    inside.fill(mouth.yawnTongue.path(in: rect), with: .color(Palette.tongue))
                }
                for fang in mouth.yawnFangs {
                    layer.fill(fang.path(in: rect), with: .color(Palette.cream))
                }
                layer.stroke(outline, with: .color(Palette.cream), style: style)
            }
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
    /// あくびの舌。参考 yawn-reference.png の舌の内側（縁から 3px 以上）の中央値 #EE7669 の実測（鼻より少し暗い珊瑚色）。
    static let tongue = rgb(0xEE, 0x76, 0x69)
    /// 閉じた目の弧（sleeping）。下書き sleeping-draft.png の弧の内側（縁から 2px 以上）の中央値 #FDCA44 / #FDCA43 の実測。
    /// 虹彩の明るい黄 #FDCA40 より青が 3 段階強い。
    static let closedLid = rgb(0xFD, 0xCA, 0x43)
    /// 眠りの Z（sleeping）。参照 sleeping-zzz-reference.png の Z の内側（縁から 2px 以上）の中央値 #76BBFC〜#78BCFD の実測。
    static let sleepMark = rgb(0x76, 0xBB, 0xFD)

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
            CatFaceView(expression: expression, mouthPose: .closed, reduceMotion: true)
                .frame(height: 120)
        }
    }
    .padding()
    .background(Color.black)
}
#endif
