import SwiftUI

/// 顔の左右。形は左目・左のひげを基準に定義し、右側は x を反転して作る。
enum CatFaceSide: Hashable, CaseIterable, Sendable {
    case left
    case right

    func point(_ point: CGPoint) -> CGPoint {
        switch self {
        case .left:
            point
        case .right:
            CGPoint(x: 1 - point.x, y: point.y)
        }
    }

    /// 目の局所座標で「鼻側」を正とした u を画面の x 方向へ変換する符号。
    var inwardSign: CGFloat { self == .left ? 1 : -1 }
}

/// 16:9 キャンバスを 0...1 に正規化した座標で、描画に使う全パスを組み立てる。
/// 描画・XCTest・scripts/face-render の check は、ここが返す同じパスを使う。
/// 値の根拠（採用画像 neutral-b / happy-b の実測）は docs/design/face-expression-2026-10-26/visual-comparison.md。
enum CatFaceGeometry {
    static let aspectRatio = 16.0 / 9.0
    static let mouthPoses: [MouthPose] = [.closed, .small, .medium, .wide]

    // MARK: neutral の配置

    /// 左目の外形の中心と半径（キャンバス単位）。右目は左右反転。
    static let baseEyeCenter = CGPoint(x: 0.2374, y: 0.4327)
    static let baseEyeRadii = CGSize(width: 0.1247, height: 0.2231)
    static var baseEyeBottom: CGFloat { baseEyeCenter.y + baseEyeRadii.height }

    static let noseTop: CGFloat = 0.6163
    /// 鼻の左の肩（最も幅の広い点）。右は反転。
    static let noseShoulder = CGPoint(x: 0.4602, y: 0.6400)
    static let noseBottom: CGFloat = 0.7045

    /// 口の「ω」の縦棒は鼻の下端の内側から始め、鼻を後から描いて採用画像どおりつながって見せる。
    static let mouthStemTop: CGFloat = 0.700
    static let mouthJunction = CGPoint(x: 0.5, y: 0.7265)
    /// 口の線幅（キャンバス高さに対する比）。
    static let mouthLineWidth: CGFloat = 0.0185
    /// 丸い口（surprised）の上端。
    static let roundMouthTop: CGFloat = 0.722

    // MARK: あくび（yawn）の配置
    // 値は参考 docs/design/idle-cat-life-2026-10-30/yawn-reference.png（16:9 の全面がキャンバス）の実測
    // （同じ場所の trace_yawn.py）。yawn の値で 0（通常）から 1（峰）へ線形に補間する。

    /// 峰での鼻の移動量（キャンバス高さ単位、上が負。下端 0.7045 → 0.5154）と、下端を基準にした倍率（高さ 0.0882 → 0.0840、幅 0.0796 → 0.0754）。
    static let yawnNoseShift: CGFloat = -0.1891
    static let yawnNoseScale: CGFloat = 0.95
    /// ω（または丸い口）からあくびの口へ透明度で切り替え終わる yawn の値。それまでに峰の口は約 1/3 の大きさに育つ。
    static let yawnMouthBlendEnd: CGFloat = 0.35
    /// 峰での口の輪郭の中心線を鼻に吊るす基準点の y（`yawnOutline` の座標。鼻の下端 0.5154 + 線幅の半分）。
    static let yawnMouthAnchor: CGFloat = 0.5245
    /// 上中央の尖りが基準点より上へ出る量。参考では唇が尖りで薄くなり、線の外縁が鼻の下端より上（0.5112）まで届くので、
    /// 口全体は動かさず尖りの曲線だけをその分上げる（鼻を後から描くので、鼻の先が尖りに埋まって見える）。
    static let yawnMouthCuspRise: CGFloat = 0.0042

    static func mouthOpening(for pose: MouthPose) -> CGFloat {
        switch pose {
        case .closed: 0
        case .small: 0.025
        case .medium: 0.055
        case .wide: 0.090
        }
    }

    // MARK: 目

    struct EyeFrame {
        let side: CatFaceSide
        let center: CGPoint
        let radii: CGSize

        /// 目の局所座標 (u: 鼻側が正, v: 下が正, 外形はおよそ単位円) をキャンバス座標へ。
        func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: center.x + side.inwardSign * u * radii.width, y: center.y + v * radii.height)
        }

        /// 画面の向き（反転しない）で局所単位だけずらした点。ハイライト用。
        func screenPoint(from origin: CGPoint, offset: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + offset.x * radii.width, y: origin.y + offset.y * radii.height)
        }

        /// 局所座標の楕円（angle 度だけ回す）。鼻側から描き始めるので、左右の目で点の並びが鏡像になる。
        func ellipse(_ u: CGFloat, _ v: CGFloat, _ ru: CGFloat, _ rv: CGFloat, angle: CGFloat = 0) -> NormalizedPath {
            let k: CGFloat = 0.5523
            let cosA = cos(angle * .pi / 180)
            let sinA = sin(angle * .pi / 180)
            func p(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) {
                (u + cosA * x * ru - sinA * y * rv, v + sinA * x * ru + cosA * y * rv)
            }
            func curve(_ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat)) -> LocalCommand {
                .curve(c1.0, c1.1, c2.0, c2.1, to.0, to.1)
            }
            let start = p(1, 0)
            return path([
                .move(start.0, start.1),
                curve(p(1, k), p(k, 1), p(0, 1)),
                curve(p(-k, 1), p(-1, k), p(-1, 0)),
                curve(p(-1, -k), p(-k, -1), p(0, -1)),
                curve(p(k, -1), p(1, -k), p(1, 0)),
                .close,
            ])
        }

        /// 実寸で円になる半径 r（目の横半径単位）の円。
        func circle(at center: CGPoint, radius r: CGFloat) -> NormalizedPath {
            let rx = r * radii.width
            return NormalizedPath.ellipse(center: center, radii: CGSize(width: rx, height: rx * CGFloat(aspectRatio)))
        }

        func path(_ commands: [LocalCommand]) -> NormalizedPath {
            NormalizedPath(commands.map { command in
                switch command {
                case let .move(u, v): .move(point(u, v))
                case let .line(u, v): .line(point(u, v))
                case let .curve(c1u, c1v, c2u, c2v, u, v):
                    .curve(to: point(u, v), control1: point(c1u, c1v), control2: point(c2u, c2v))
                case .close: .close
                }
            })
        }
    }

    enum LocalCommand {
        case move(CGFloat, CGFloat)
        case line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case close
    }

    /// 虹彩は外形で切り抜いた 4 色の層: 上の陰（外側→鼻側のグラデーション）、明るい黄、
    /// 瞳を囲む内側の層（上が濃い琥珀、下がオレンジ）。
    struct EyeGeometry {
        let outline: NormalizedPath
        /// この回転楕円の内側が明るい黄、外側（上と鼻側の縁）が陰。
        let litRim: NormalizedPath
        let innerIris: NormalizedPath
        /// 内側の層のうち明るいオレンジになる範囲。
        let innerLit: NormalizedPath
        let pupil: NormalizedPath
        let highlight: NormalizedPath
        let dot: NormalizedPath
        let sparkle: NormalizedPath
        /// 黒いまぶた。背景と同じ黒で虹彩の上側を覆う。
        let lid: NormalizedPath
        /// 閉じた目（sleeping）の金色の弧。まぶたの上に塗る。
        let closedLid: NormalizedPath
        /// 上の陰のグラデーションの軸（外側の端 → 鼻側の端）と色の切り替え位置。
        let capGradientStart: CGPoint
        let capGradientEnd: CGPoint
        static let capGradientStops: [CGFloat] = [0, 0.27, 0.78, 1]

        var all: [NormalizedPath] {
            [outline, litRim, innerIris, innerLit, pupil, highlight, dot, sparkle, lid, closedLid]
        }

        /// 左右対称の検査に使う形（ハイライトは光源が一つなので反転しない）。
        var mirroredShapes: [(name: String, path: NormalizedPath)] {
            [("eye outline", outline), ("lit rim", litRim), ("inner iris", innerIris), ("inner lit", innerLit),
             ("pupil", pupil), ("lid", lid), ("closed lid", closedLid)]
        }
    }

    static func eyeFrame(side: CatFaceSide, eye: CatFaceAppearance.Eye) -> EyeFrame {
        let radii = CGSize(width: baseEyeRadii.width * eye.widthScale,
                           height: baseEyeRadii.height * eye.heightScale)
        // 大きくなる目は下端を保って上と外側へ広がる（happy-b の実測）。
        let leftCenter = CGPoint(x: baseEyeCenter.x - eye.outwardShift,
                                 y: baseEyeBottom - radii.height - eye.lift)
        return EyeFrame(side: side, center: side.point(leftCenter), radii: radii)
    }

    static func eye(side: CatFaceSide, appearance: CatFaceAppearance) -> EyeGeometry {
        let eye = appearance.eye(side)
        let frame = eyeFrame(side: side, eye: eye)
        let pupilCenter = frame.point(eye.pupilCenter.x, eye.pupilCenter.y)
        // まばたきは静止のまぶたの残りを閉じる（足して 1 を超えないように）。
        let lidAmount = min(1, eye.lid + (1 - eye.lid) * eye.blink)
        // ハイライト群（大きな白丸・小白点・四つ星）は静止のまぶたの線より下へ下げ、両目に白丸を残す。
        // まばたきの量は使わない（まばたき中にハイライトが動かないように）。
        let highlightCenter = frame.screenPoint(from: pupilCenter, offset: eye.highlightOffset)
        let drop = highlightDrop(frame: frame, center: highlightCenter, radius: eye.highlightRadius,
                                 lid: eye.lid, tilt: eye.lidTilt)
        func lowered(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: point.y + drop) }

        return EyeGeometry(
            outline: frame.path(eyeOutline(roundness: eye.outlineRoundness)),
            litRim: litRim(frame: frame, roundness: eye.outlineRoundness),
            // 上端（v −0.91）を保ち、下端だけを innerIrisBottom へ動かす（neutral は 0.89 で従来どおり）。
            innerIris: frame.ellipse(0.03, -0.01 + (eye.innerIrisBottom - 0.89) / 2, 0.625,
                                     0.90 + (eye.innerIrisBottom - 0.89) / 2),
            innerLit: frame.ellipse(0.15, 0.51, 0.80, 0.72),
            pupil: frame.ellipse(eye.pupilCenter.x, eye.pupilCenter.y, eye.pupilRadii.width, eye.pupilRadii.height),
            highlight: frame.circle(at: lowered(highlightCenter), radius: eye.highlightRadius),
            dot: frame.circle(at: lowered(frame.screenPoint(from: pupilCenter, offset: eye.dotOffset)),
                              radius: eye.dotRadius),
            sparkle: sparkle(frame: frame,
                             center: lowered(frame.screenPoint(from: pupilCenter, offset: eye.sparkleOffset)),
                             size: eye.sparkleSize),
            lid: eye.lid > 0 && eye.lid < 1 && eye.blink > 0
                ? blinkingLids(frame: frame, restingAmount: eye.lid, tilt: eye.lidTilt, progress: min(1, eye.blink))
                : lid(frame: frame, amount: lidAmount, tilt: eye.lidTilt),
            closedLid: closedLid(frame: frame, yawn: appearance.yawn),
            capGradientStart: frame.point(-0.60, 0),
            capGradientEnd: frame.point(0.70, 0)
        )
    }

    /// 明るい黄の範囲（回転楕円）。外側では外形に沿う上の中間琥珀の帯が細りながら続き、
    /// 鼻側では琥珀の帯が約 47〜50% で終わる（neutral-b / happy-b の帯の厚さを行ごとに当てはめた。
    /// roundness 0 が neutral-b、1 が happy-b の丸い外形）。
    /// 外側の帯の終わりに明るい黄の細い三日月（`capTailFill`）を足して帯を早く細らせる。
    private static func litRim(frame: EyeFrame, roundness t: CGFloat) -> NormalizedPath {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let u = lerp(0.0165, 0.0269)
        let v = lerp(0.2466, 0.2238)
        let ru = lerp(0.9182, 0.9317)
        let rv = lerp(1.1085, 1.1113)
        let angle = lerp(-46.14, -45.11)
        let ellipse = frame.ellipse(u, v, ru, rv, angle: angle)
        let fill = capTailFill(frame: frame, ellipse: (u, v, ru, rv, angle), roundness: t)
        // 三日月を先に置く（楕円の後に置くと、尾から離れた楕円の縁の画素まで 1 段階ずれた。macOS 26 で確認）。
        return NormalizedPath(fill.commands + ellipse.commands)
    }

    /// 楕円の外側の弧（外側の下 → 外側の上）のうち帯の終わりの区間 [t0, t1] と、同じ両端・同じ接線で手を伸ばした
    /// 3 次曲線とに挟まれた細い三日月（楕円と同じ向きの閉じた部分パス。楕円と一緒に塗ると和になる）。
    /// 楕円の弧そのものは変えないので、上端 t1（帯の厚さが約 1.5pt の行。neutral 約 34.6%、happy 約 35.6%）より
    /// 上の帯は Round 6 と同じ。下端 t0 は楕円が外形の外へ出た所（neutral 約 46%、happy 約 53%）。
    /// 手を伸ばすほど曲線が外形へ寄り、帯は 1.5pt から急に細って neutral は約 36%、happy は約 38% で
    /// 0.4pt 以下になり、そのまま外形の外へ抜ける。
    private static func capTailFill(frame: EyeFrame, ellipse: (u: CGFloat, v: CGFloat, ru: CGFloat, rv: CGFloat, angle: CGFloat),
                                    roundness t: CGFloat) -> NormalizedPath {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let k: CGFloat = 0.5523
        let cosA = cos(ellipse.angle * .pi / 180)
        let sinA = sin(ellipse.angle * .pi / 180)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ellipse.u + cosA * x * ellipse.ru - sinA * y * ellipse.rv,
                    y: ellipse.v + sinA * x * ellipse.ru + cosA * y * ellipse.rv)
        }
        let t0 = lerp(0.66, 0.53)
        let t1 = lerp(0.825, 0.78)
        let outer = [p(-1, 0), p(-1, -k), p(-k, -1), p(0, -1)]
        let arc = splitCubic(splitCubic(outer, at: t0).1, at: (t1 - t0) / (1 - t0)).0
        // 手の長さの倍率（1 で元の弧と同じ曲線）。
        let stretchLow = lerp(2.75, 2.25)
        let stretchHigh = lerp(0.75, 0.5)
        let control1 = CGPoint(x: arc[0].x + (arc[1].x - arc[0].x) * stretchLow,
                               y: arc[0].y + (arc[1].y - arc[0].y) * stretchLow)
        let control2 = CGPoint(x: arc[3].x + (arc[2].x - arc[3].x) * stretchHigh,
                               y: arc[3].y + (arc[2].y - arc[3].y) * stretchHigh)
        return frame.path([
            .move(arc[0].x, arc[0].y),
            .curve(control1.x, control1.y, control2.x, control2.y, arc[3].x, arc[3].y),
            .curve(arc[2].x, arc[2].y, arc[1].x, arc[1].y, arc[0].x, arc[0].y),
            .close,
        ])
    }

    /// 3 次ベジェ [始点, 制御点 1, 制御点 2, 終点] を t で二つに分ける（de Casteljau。分けても同じ曲線）。
    private static func splitCubic(_ points: [CGPoint], at t: CGFloat) -> ([CGPoint], [CGPoint]) {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let a = mix(points[0], points[1])
        let b = mix(points[1], points[2])
        let c = mix(points[2], points[3])
        let d = mix(a, b)
        let e = mix(b, c)
        let f = mix(d, e)
        return ([points[0], a, d, f], [f, e, c, points[3]])
    }

    /// 目の外形。roundness 0 は neutral-b の「下ぶくれで上端が外側へ傾いた」形、1 は happy-b のほぼ真円の形
    /// （どちらも行ごとの左右端の実測に当てはめた）。間は補間する。
    private static func eyeOutline(roundness t: CGFloat) -> [LocalCommand] {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let top = (u: lerp(-0.09, -0.01), v: CGFloat(-1.0))
        let right = (u: CGFloat(0.995), v: lerp(0.20, 0.05))
        let bottom = (u: lerp(0.07, 0.035), v: CGFloat(1.0))
        let left = (u: CGFloat(-1.0), v: lerp(0.02, 0.0))
        let upper: CGFloat = 0.535
        let lower = lerp(0.62, 0.60)
        return [
            .move(top.u, top.v),
            .curve(top.u + upper * (right.u - top.u), top.v,
                   right.u, right.v - upper * (right.v - top.v),
                   right.u, right.v),
            .curve(right.u, right.v + lower * (bottom.v - right.v),
                   bottom.u + lower * (right.u - bottom.u), bottom.v,
                   bottom.u, bottom.v),
            .curve(bottom.u - lower * (bottom.u - left.u), bottom.v,
                   left.u, left.v + lower * (bottom.v - left.v),
                   left.u, left.v),
            .curve(left.u, left.v - upper * (left.v - top.v),
                   top.u - upper * (top.u - left.u), top.v,
                   top.u, top.v),
            .close,
        ]
    }

    /// 内側へ反った辺を持つ四つ星。size は目の横半径単位の横の半径。縦は実寸で横の 1.12 倍、
    /// 腕の太さ（k, n）は happy-b の星の面積（外接矩形の約 0.46 倍）に合わせた。
    private static func sparkle(frame: EyeFrame, center: CGPoint, size: CGFloat) -> NormalizedPath {
        let rx = size * frame.radii.width
        let ry = rx * CGFloat(aspectRatio) * 1.12
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * rx, y: center.y + y * ry) }
        let k: CGFloat = 0.12
        let n: CGFloat = 0.32
        return NormalizedPath([
            .move(p(0, -1)),
            .curve(to: p(1, 0), control1: p(k, -n), control2: p(n, -k)),
            .curve(to: p(0, 1), control1: p(n, k), control2: p(k, n)),
            .curve(to: p(-1, 0), control1: p(-k, n), control2: p(-n, k)),
            .curve(to: p(0, -1), control1: p(-n, -k), control2: p(-k, -n)),
            .close,
        ])
    }

    /// amount 0 で完全に開き、1 で目全体を覆う黒いまぶた。tilt が正なら外側（耳側）が下がる。
    private static func lid(frame: EyeFrame, amount: CGFloat, tilt: CGFloat) -> NormalizedPath {
        let edge = lidEdge(amount: amount, tilt: tilt)
        return frame.path([
            .move(-1.3, -1.3),
            .line(1.3, -1.3),
            .line(edge[0].u, edge[0].v),
            .curve(edge[1].u, edge[1].v, edge[2].u, edge[2].v, edge[3].u, edge[3].v),
            .close,
        ])
    }

    /// 半目からの瞬きは、上下のまぶたを閉眼の弧へ寄せる。
    /// 上まぶただけを目の下まで通過させると、閉眼の弧が出る前に虹彩が消えてしまう。
    /// 開始時は既存の半目と同じ曲線、終了時は closedLid と同じ上下の縁になる。
    private static func blinkingLids(frame: EyeFrame, restingAmount: CGFloat, tilt: CGFloat,
                                     progress: CGFloat) -> NormalizedPath {
        // Split the resting cubic at its midpoint so both poses have two cubics.
        func splitEdge(amount: CGFloat) -> [LidPoint] {
            let edge = lidEdge(amount: amount, tilt: tilt)
            let a = mix(edge[0], edge[1], 0.5), b = mix(edge[1], edge[2], 0.5)
            let c = mix(edge[2], edge[3], 0.5)
            let d = mix(a, b, 0.5), e = mix(b, c, 0.5)
            return [edge[0], a, d, mix(d, e, 0.5), e, c, edge[3]]
        }
        let upperStart = splitEdge(amount: restingAmount)
        let ordinaryUpper = splitEdge(amount: restingAmount + (1 - restingAmount) * progress)
        // Fade the correction out at open/closed presets, including interrupted blinks.
        let sleepyAmount = CatFaceAppearance.sleepy.leftEye.lid
        let weight = min(restingAmount / sleepyAmount, (1 - restingAmount) / (1 - sleepyAmount))
        let strength = weight * weight * (3 - 2 * weight)
        let arc = sleepingLidArc
        let upperEnd = [arc[6], arc[5], arc[4], arc[3], arc[2], arc[1], arc[0]]
        let lowerEnd = [arc[6], arc[7], arc[8], arc[9], arc[10], arc[11], arc[0]]
        let lowerStart = upperStart.map { (u: $0.u, v: CGFloat(1.3)) }
        func mask(from start: [LidPoint], to end: [LidPoint], ordinary: [LidPoint], outside: CGFloat) -> NormalizedPath {
            let closing = zip(start, end).map { mix($0, $1, progress) }
            var p = zip(ordinary, closing).map { mix($0, $1, strength) }
            // Use the same winding so overlapping masks stay opaque during transitions.
            let direction: CGFloat = outside < 0 ? 1 : -1
            if direction < 0 { p.reverse() }
            return frame.path([
                .move(-1.3 * direction, outside), .line(1.3 * direction, outside), .line(1.3 * direction, p[0].v),
                .line(p[0].u, p[0].v),
                .curve(p[1].u, p[1].v, p[2].u, p[2].v, p[3].u, p[3].v),
                .curve(p[4].u, p[4].v, p[5].u, p[5].v, p[6].u, p[6].v),
                .line(-1.3 * direction, p[6].v), .close
            ])
        }
        let upper = mask(from: upperStart, to: upperEnd, ordinary: ordinaryUpper, outside: -1.3)
        let lower = mask(from: lowerStart, to: lowerEnd, ordinary: lowerStart, outside: 1.3)
        return NormalizedPath(upper.commands + lower.commands)
    }

    /// まぶたの縁の 3 次ベジェ（目の局所座標、鼻側 u = 1.3 → 耳側 u = -1.3）。
    private static func lidEdge(amount: CGFloat, tilt: CGFloat) -> [LidPoint] {
        let edge = -1.25 + 2.5 * amount
        let bulge: CGFloat = 0.16
        return [(1.3, edge - tilt), (0.45, edge + bulge - tilt * 0.35),
                (-0.45, edge + bulge + tilt * 0.35), (-1.3, edge + tilt)]
    }

    /// 閉じた目の金色の弧。上縁と下縁を別の 3 次ベジェで描き、両端は同じ点に集めて尖らせる。yawn 0 は sleeping の ∪、
    /// 1 はあくびの ∩ で、間は 12 の点（先端・制御点・中央）を線形に補間する（0.5 付近はほぼ平らな線になる）。
    private static func closedLid(frame: EyeFrame, yawn: CGFloat) -> NormalizedPath {
        let t = min(max(yawn, 0), 1)
        let p = zip(sleepingLidArc, yawningLidArc).map { mix($0, $1, t) }
        return frame.path([
            .move(p[0].u, p[0].v),
            .curve(p[1].u, p[1].v, p[2].u, p[2].v, p[3].u, p[3].v),
            .curve(p[4].u, p[4].v, p[5].u, p[5].v, p[6].u, p[6].v),
            .curve(p[7].u, p[7].v, p[8].u, p[8].v, p[9].u, p[9].v),
            .curve(p[10].u, p[10].v, p[11].u, p[11].v, p[0].u, p[0].v),
            .close,
        ])
    }

    /// まばたき・まぶたが閉じきる直前（closedArcStart を超えてから）に閉じた目の金色の弧を出し始める量（1 で不透明）。
    /// 描画の弧の透明度（CatFaceRenderer）と、あくび中に目を閉じる CatFaceAppearance.eye(_:) が同じ坂を使う。
    static let closedArcStart: CGFloat = 0.9
    static func closedArcVisibility(_ closure: CGFloat) -> CGFloat {
        min(1, max(0, (closure - closedArcStart) / (1 - closedArcStart)))
    }

    /// まぶたの縁・閉じた目の弧の点（目の局所座標）と、その線形補間。
    private typealias LidPoint = (u: CGFloat, v: CGFloat)
    private static func mix(_ a: LidPoint, _ b: LidPoint, _ t: CGFloat) -> LidPoint {
        (a.u + (b.u - a.u) * t, a.v + (b.v - a.v) * t)
    }

    /// 閉じた目の弧の点列（目の局所座標、描く順）: 耳側の先端、上縁の制御点 2 つ、上縁の中央、制御点 2 つ、鼻側の先端、
    /// 下縁の制御点 2 つ、下縁の中央、制御点 2 つ（最後は耳側の先端へ戻る）。
    private typealias LidArc = [LidPoint]

    /// sleeping の ∪: 目の枠の下半分に、外形と同じ横幅で置く（中央で太さ約 0.031、|u| 0.9 で約 0.06×縦半径、先端で 0）。
    /// 各縁は中央で水平に接する左右対称の 2 本。値は下書き sleeping-draft.png の両目の弧を列ごとに実測して当てはめたもの
    /// （docs/design/sleeping-2026-10-26/visual-comparison.md。当てはめの残差は rms 0.3px、描画と下書きの縁の差は
    /// 先端の 1 列を除いて 1280×720 で 1px 以下）。
    private static let sleepingLidArc: LidArc = {
        let centerU: CGFloat = 0.017
        let tip = (u: CGFloat(0.988), v: CGFloat(0.265))
        // 各縁: 先端側の制御点（先端からの u・v のずれ）、中央側の制御点の u のずれ、中央の v。
        let upper = (tipHandle: (u: CGFloat(0.084), v: CGFloat(0.0)), centerHandle: CGFloat(0.577), v: CGFloat(0.573))
        let lower = (tipHandle: (u: CGFloat(0.144), v: CGFloat(0.180)), centerHandle: CGFloat(0.502), v: CGFloat(0.714))
        let ear = centerU - tip.u
        let nose = centerU + tip.u
        return [
            (ear, tip.v),
            (ear + upper.tipHandle.u, tip.v + upper.tipHandle.v), (centerU - upper.centerHandle, upper.v), (centerU, upper.v),
            (centerU + upper.centerHandle, upper.v), (nose - upper.tipHandle.u, tip.v + upper.tipHandle.v), (nose, tip.v),
            (nose - lower.tipHandle.u, tip.v + lower.tipHandle.v), (centerU + lower.centerHandle, lower.v), (centerU, lower.v),
            (centerU - lower.centerHandle, lower.v), (ear + lower.tipHandle.u, tip.v + lower.tipHandle.v),
        ]
    }()

    /// あくびの ∩: 頂点は目の中心より上（u 0.056、太さ 0.188 = キャンバス高さの 0.042）、外側の先端は短く、鼻側の先端は
    /// 目の中心の少し下まで長く垂れる。各縁は頂点で水平に接する非対称の 2 本。値は参考 yawn-reference.png の両目の弧を
    /// neutral の目の枠の局所座標に写して平均し、列ごとの上縁・下縁に当てはめたもの（trace_yawn.py。残差 rms ≤ 1.6px @941）。
    private static let yawningLidArc: LidArc = [
        (-0.515, -0.064),
        (-0.417, -0.269), (-0.161, -0.358), (0.056, -0.358),
        (0.442, -0.358), (0.867, -0.215), (1.106, 0.098),
        (0.808, -0.065), (0.419, -0.170), (0.056, -0.170),
        (-0.137, -0.170), (-0.362, -0.089),
    ]

    /// 局所座標 u でのまぶたの縁の v（u は縁の上で単調なので二分法で求める）。
    private static func lidEdgeV(at u: CGFloat, amount: CGFloat, tilt: CGFloat) -> CGFloat {
        let p = lidEdge(amount: amount, tilt: tilt)
        func bezier(_ t: CGFloat, _ value: ((u: CGFloat, v: CGFloat)) -> CGFloat) -> CGFloat {
            let s = 1 - t
            return s * s * s * value(p[0]) + 3 * s * s * t * value(p[1]) + 3 * s * t * t * value(p[2]) + t * t * t * value(p[3])
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if bezier(middle, { $0.u }) > u { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, { $0.v })
    }

    /// 白丸の上端がまぶたの縁より margin 以上下になるまで下げる量（キャンバス単位、下が正）。
    /// 完全に閉じたまぶた（sleeping）の下に見せる白丸はないので、そのときは動かさない。
    private static func highlightDrop(frame: EyeFrame, center: CGPoint, radius: CGFloat,
                                      lid: CGFloat, tilt: CGFloat) -> CGFloat {
        guard lid > 0.000_1, lid < 1 else { return 0 }
        let margin: CGFloat = 0.04
        let centerU = (center.x - frame.center.x) * frame.side.inwardSign / frame.radii.width
        let centerV = (center.y - frame.center.y) / frame.radii.height
        // 実寸の円なので、局所座標では横半径 radius、縦半径 radiusV の楕円になる。
        let radiusV = radius * frame.radii.width * CGFloat(aspectRatio) / frame.radii.height
        var needed: CGFloat = 0
        for step in 0...16 {
            let x = -1 + CGFloat(step) / 8
            let top = centerV - radiusV * sqrt(max(0, 1 - x * x))
            let edge = lidEdgeV(at: centerU + x * radius, amount: lid, tilt: tilt)
            needed = max(needed, edge + margin - top)
        }
        return needed * frame.radii.height
    }

    // MARK: 鼻

    /// 上辺がゆるく凸で角の丸い逆三角（neutral-b の輪郭の実測に合わせた）。
    /// あくびでは下端を基準に上へ動き、少し小さくなる（`yawnNoseShift` / `yawnNoseScale`）。
    static func nose(yawn: CGFloat) -> NormalizedPath {
        let shoulder = noseShoulder
        let half = 0.5 - shoulder.x
        let path = NormalizedPath([
            .move(0.5, noseTop),
            .curve(to: shoulder,
                   control1: CGPoint(x: 0.5 - half * 0.70, y: noseTop),
                   control2: CGPoint(x: shoulder.x, y: shoulder.y - (shoulder.y - noseTop) * 0.60)),
            .curve(to: CGPoint(x: 0.5, y: noseBottom),
                   control1: CGPoint(x: shoulder.x, y: shoulder.y + 0.014),
                   control2: CGPoint(x: 0.5 - half * 0.32, y: noseBottom)),
        ]).closedWithMirror()
        let amount = min(max(yawn, 0), 1)
        guard amount > 0 else { return path }
        let scale = 1 - (1 - yawnNoseScale) * amount
        let shift = yawnNoseShift * amount
        return path.mapped { point in
            CGPoint(x: 0.5 + (point.x - 0.5) * scale, y: noseBottom + (point.y - noseBottom) * scale + shift)
        }
    }

    // MARK: 口

    struct MouthGeometry {
        /// クリーム色で塗る「ω」の縦棒（鼻の下から左右の弧へ広がる首）。
        let neck: NormalizedPath
        /// クリーム色の線で描く「ω」の左右の弧。
        let lines: [NormalizedPath]
        /// 開口時の下唇（クリーム色）と暗い内側。
        let lowerLip: NormalizedPath
        let cavity: NormalizedPath
        /// 丸い口（クリーム色の輪郭と暗い内側）。
        let round: NormalizedPath
        let opening: CGFloat
        /// 0 で ω、1 で丸い口。間は重ねて切り替える。
        let roundness: CGFloat
        /// あくびの口（yawn 0 では空）: 輪郭の中心線（クリーム色の線で描き、内側を暗く塗る閉じたパス）、
        /// 舌（上縁の弧を下で閉じた形。輪郭の内側で切り抜いて描く）、左右の牙。
        let yawnOutline: NormalizedPath
        let yawnTongue: NormalizedPath
        let yawnFangs: [NormalizedPath]
        /// 0 で ω（または丸い口）だけ、1 であくびの口だけ。間は透明度で重ねて切り替える。
        let yawnBlend: CGFloat

        var showsLines: Bool { roundness < 1 && yawnBlend < 1 }
        var showsOpening: Bool { opening > 0 && roundness < 1 && yawnBlend < 1 }
        var showsRound: Bool { roundness > 0 && yawnBlend < 1 }
        var showsYawn: Bool { yawnBlend > 0 }
    }

    /// lineScale はコントラスト強調の線幅の倍率（縦棒の太さも同じ倍率で太る）。
    /// あくび（yawn > 0）では ω・丸い口を鼻と一緒に上へ動かしながら透明度で消し、代わりに峰の口を鼻の下端に吊るして
    /// yawn 倍の大きさで描く（鼻の下端の基準点 `yawnMouthAnchor` を中心に相似に縮め、線幅は変えない）。
    static func mouth(appearance: CatFaceAppearance, opening: CGFloat, lineScale: CGFloat = 1) -> MouthGeometry {
        let yawn = min(max(appearance.yawn, 0), 1)
        let yawnShift = yawnNoseShift * yawn
        func raised(_ path: NormalizedPath) -> NormalizedPath {
            yawn > 0 ? path.mapped { CGPoint(x: $0.x, y: $0.y + yawnShift) } : path
        }
        let anchorY = noseBottom + yawnShift + mouthLineWidth * lineScale / 2
        func placed(_ path: NormalizedPath) -> NormalizedPath {
            path.mapped { CGPoint(x: 0.5 + ($0.x - 0.5) * yawn, y: anchorY + ($0.y - yawnMouthAnchor) * yawn) }
        }
        let placedOutline = yawn > 0 ? placed(yawnOutline) : NormalizedPath([])
        let placedTongue = yawn > 0 ? placed(yawnTongue) : NormalizedPath([])
        let placedFangs = yawn > 0 ? [placed(yawnFangLeft), placed(yawnFangRight)] : []

        let width = appearance.mouthWidth
        let smile = appearance.mouthSmile
        let j = mouthJunction
        func p(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: j.x + dx * width, y: j.y + dy * smile) }
        // 鼻側の合流点 → 弧の底 → 上へ巻き上がる端（neutral-b の線の中心を当てはめた）。
        // 合流点からはほぼ真下へ出て丸く外へ曲がる（V 字に刺さらない）。
        let bottom = p(-0.049, 0.0650)
        let toBottom1 = p(-0.0085, 0.0382)
        let toBottom2 = p(-0.0304, 0.0650)
        let end = p(-0.0934, 0.0150)
        let leftArc = NormalizedPath([
            .move(j),
            .curve(to: bottom, control1: toBottom1, control2: toBottom2),
            .curve(to: end, control1: p(-0.0687, 0.0650), control2: p(-0.0883, 0.0488)),
        ])
        let neck = mouthNeck(junction: j, toBottom1: toBottom1, toBottom2: toBottom2, bottom: bottom,
                             lineWidth: mouthLineWidth * lineScale)

        let lipDepth = opening * 1.33
        let rightBottom = CatFaceSide.right.point(bottom)
        let lowerLip = NormalizedPath([
            .move(bottom),
            .curve(to: rightBottom,
                   control1: CGPoint(x: bottom.x, y: bottom.y + lipDepth),
                   control2: CGPoint(x: rightBottom.x, y: rightBottom.y + lipDepth)),
        ])
        let cavity = NormalizedPath([
            .move(bottom),
            .curve(to: j, control1: toBottom2, control2: toBottom1),
            .curve(to: rightBottom, control1: CatFaceSide.right.point(toBottom1),
                   control2: CatFaceSide.right.point(toBottom2)),
            .curve(to: bottom,
                   control1: CGPoint(x: rightBottom.x, y: rightBottom.y + lipDepth),
                   control2: CGPoint(x: bottom.x, y: bottom.y + lipDepth)),
            .close,
        ])

        // 丸い口は上端を保ったまま、開きに応じて縦長に大きくなる。
        let roundRadius = CGSize(width: (0.024 + opening * 0.25) / CGFloat(aspectRatio), height: 0.028 + opening * 0.5)
        let round = NormalizedPath.ellipse(center: CGPoint(x: 0.5, y: roundMouthTop + roundRadius.height),
                                           radii: roundRadius)

        return MouthGeometry(neck: raised(neck), lines: [raised(leftArc), raised(leftArc.mirrored)], lowerLip: raised(lowerLip),
                             cavity: raised(cavity), round: raised(round), opening: opening, roundness: appearance.mouthRoundness,
                             yawnOutline: placedOutline, yawnTongue: placedTongue, yawnFangs: placedFangs,
                             yawnBlend: min(1, yawn / yawnMouthBlendEnd))
    }

    /// あくびの峰の口の輪郭（クリーム色の線の中心線、キャンバス単位）。上中央の尖り（鼻の下）→ くぼみ → 口角の上向きの瘤 →
    /// 最も幅の広い点 → 底中央の左半分を 9 本の 3 次ベジェで描き、右は鏡映。参考 yawn-reference.png のクリーム色の輪郭の
    /// 外縁を追跡し、線幅の半分だけ内側へずらした中心線に当てはめた（trace_yawn.py。区間ごとの残差 rms ≤ 1.5px @941。
    /// 線幅は参考の実測 0.018〜0.019 で製品の mouthLineWidth と同じ）。
    /// 上中央の尖りとそこから出る制御点だけ `yawnMouthCuspRise` 上げる（最初の区間の終点から先は当てはめのまま）。
    private static let yawnOutline = NormalizedPath([
        .move(0.5, yawnMouthAnchor - yawnMouthCuspRise),
        .curve(to: CGPoint(x: 0.4411, y: 0.5753), control1: CGPoint(x: 0.4836, y: 0.5484 - yawnMouthCuspRise),
               control2: CGPoint(x: 0.4650, y: 0.5753)),
        .curve(to: CGPoint(x: 0.4113, y: 0.5608), control1: CGPoint(x: 0.4306, y: 0.5753), control2: CGPoint(x: 0.4203, y: 0.5707)),
        .curve(to: CGPoint(x: 0.4035, y: 0.5513), control1: CGPoint(x: 0.4095, y: 0.5587), control2: CGPoint(x: 0.4035, y: 0.5515)),
        .curve(to: CGPoint(x: 0.4060, y: 0.5470), control1: CGPoint(x: 0.4035, y: 0.5513), control2: CGPoint(x: 0.4058, y: 0.5470)),
        .curve(to: CGPoint(x: 0.4152, y: 0.5735), control1: CGPoint(x: 0.4087, y: 0.5470), control2: CGPoint(x: 0.4152, y: 0.5693)),
        .curve(to: CGPoint(x: 0.3983, y: 0.6308), control1: CGPoint(x: 0.4152, y: 0.5903), control2: CGPoint(x: 0.4031, y: 0.6137)),
        .curve(to: CGPoint(x: 0.3815, y: 0.7434), control1: CGPoint(x: 0.3886, y: 0.6648), control2: CGPoint(x: 0.3815, y: 0.7050)),
        .curve(to: CGPoint(x: 0.3852, y: 0.7907), control1: CGPoint(x: 0.3815, y: 0.7591), control2: CGPoint(x: 0.3827, y: 0.7755)),
        .curve(to: CGPoint(x: 0.5, y: 0.9026), control1: CGPoint(x: 0.3997, y: 0.8812), control2: CGPoint(x: 0.4531, y: 0.9026)),
    ]).closedWithMirror()

    /// 舌: 上縁の弧（輪郭の中心線上の接点 → 中央で水平な頂点 → 鏡映の接点）を、口より下まで広げた長方形で閉じた形。
    /// 描くときは輪郭の内側で切り抜くので、見えるのは弧より下の口の中だけ。参考の舌の上縁の当てはめ（残差 rms 1.8px @941）。
    private static let yawnTongue: NormalizedPath = {
        let contact = CGPoint(x: 0.3876, y: 0.8034)
        let apex = CGPoint(x: 0.5, y: 0.7024)
        let control1 = CGPoint(x: 0.4059, y: 0.7279)
        let control2 = CGPoint(x: 0.4544, y: 0.7024)
        let right = CatFaceSide.right
        return NormalizedPath([
            .move(contact),
            .curve(to: apex, control1: control1, control2: control2),
            .curve(to: right.point(contact), control1: right.point(control2), control2: right.point(control1)),
            .line(0.70, contact.y),
            .line(0.70, 0.96),
            .line(0.30, 0.96),
            .line(0.30, contact.y),
            .close,
        ])
    }()

    /// 左の牙: 上唇のくぼみの底から垂れる小さな三角（根元は唇の線の中心線上に隠し、先端はわずかに鼻側へ向く）。
    /// 参考の牙の左右の縁の当てはめ（残差 rms ≤ 0.7px @941）。右は鏡映。
    private static let yawnFangLeft = NormalizedPath([
        .move(0.4243, 0.5749),
        .curve(to: CGPoint(x: 0.4405, y: 0.6281), control1: CGPoint(x: 0.4279, y: 0.5952), control2: CGPoint(x: 0.4315, y: 0.6153)),
        .curve(to: CGPoint(x: 0.4496, y: 0.5749), control1: CGPoint(x: 0.4474, y: 0.6155), control2: CGPoint(x: 0.4464, y: 0.5932)),
        .close,
    ])
    private static let yawnFangRight = yawnFangLeft.mirrored

    /// 縦棒の上端の半幅（線幅に対する比）、外側の輪郭が弧の外側の縁へ接する位置（弧の最初の 3 次ベジェの t）、
    /// 輪郭の制御点の長さ（上端側・接点側、上端と接点の距離に対する比）。neutral-b の縦棒の輪郭の行ごとの追跡に当てはめた。
    private static let neckTopHalfWidth: CGFloat = 0.39
    private static let neckJoin: CGFloat = 0.28
    private static let neckHandles: (top: CGFloat, join: CGFloat) = (0.15, 0.50)

    /// 鼻の下から左右の弧へ移る縦棒（塗り）。鼻の直下では線幅より細く、下へ向けて少しずつ太り、外側の輪郭は
    /// 傾きを途切れずに増やして弧の外側の縁に接線をそろえてつながる（まっすぐな区間も急な折れもない）。
    /// 下は合流点で閉じるので、左右の弧の間の股の形は弧の線のまま変わらない。座標は実寸（x にアスペクト比を掛けた値）で計算する。
    private static func mouthNeck(junction j: CGPoint, toBottom1: CGPoint, toBottom2: CGPoint, bottom: CGPoint,
                                  lineWidth: CGFloat) -> NormalizedPath {
        let a = CGFloat(aspectRatio)
        func physical(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * a, y: point.y) }
        func normalized(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / a, y: point.y) }
        let p0 = physical(j), p1 = physical(toBottom1), p2 = physical(toBottom2), p3 = physical(bottom)
        let t = neckJoin
        let s = 1 - t
        func cubic(_ value: (CGPoint) -> CGFloat) -> CGFloat {
            s * s * s * value(p0) + 3 * s * s * t * value(p1) + 3 * s * t * t * value(p2) + t * t * t * value(p3)
        }
        func derivative(_ value: (CGPoint) -> CGFloat) -> CGFloat {
            3 * s * s * (value(p1) - value(p0)) + 6 * s * t * (value(p2) - value(p1)) + 3 * t * t * (value(p3) - value(p2))
        }
        let center = CGPoint(x: cubic(\.x), y: cubic(\.y))
        let direction = CGPoint(x: derivative(\.x), y: derivative(\.y))
        let length = max(0.000_001, hypot(direction.x, direction.y))
        let tangent = CGPoint(x: direction.x / length, y: direction.y / length)
        // 左の弧は左下へ進むので、(−ty, tx) が外側（左上）の向き。
        let join = CGPoint(x: center.x - tangent.y * lineWidth / 2, y: center.y + tangent.x * lineWidth / 2)
        let top = CGPoint(x: 0.5 * a - neckTopHalfWidth * lineWidth, y: mouthStemTop)
        let span = hypot(join.x - top.x, join.y - top.y)
        let control1 = CGPoint(x: top.x, y: top.y + neckHandles.top * span)
        let control2 = CGPoint(x: join.x - tangent.x * neckHandles.join * span,
                               y: join.y - tangent.y * neckHandles.join * span)
        return NormalizedPath([
            .move(0.5, mouthStemTop),
            .line(normalized(top)),
            .curve(to: normalized(join), control1: normalized(control1), control2: normalized(control2)),
            .line(j),
        ]).closedWithMirror()
    }

    // MARK: ひげ

    /// 左のひげ3本の中心線（内側の根元 → 外側の先端）。neutral-b の左右のひげの中心線（淡い両端まで）の平均に当てはめた。
    private struct WhiskerSpec {
        let root: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let tip: CGPoint
        /// 中央の太さ（キャンバス高さに対する比）。
        var thickness: CGFloat = whiskerThickness
    }

    private static let leftWhiskerSpecs: [WhiskerSpec] = [
        WhiskerSpec(root: CGPoint(x: 0.2402, y: 0.7138), control1: CGPoint(x: 0.1785, y: 0.6704),
                    control2: CGPoint(x: 0.1068, y: 0.6514), tip: CGPoint(x: 0.0420, y: 0.6853)),
        WhiskerSpec(root: CGPoint(x: 0.2585, y: 0.7445), control1: CGPoint(x: 0.1915, y: 0.7263),
                    control2: CGPoint(x: 0.1172, y: 0.7328), tip: CGPoint(x: 0.0570, y: 0.7913)),
        WhiskerSpec(root: CGPoint(x: 0.2571, y: 0.7872), control1: CGPoint(x: 0.2004, y: 0.7879),
                    control2: CGPoint(x: 0.1429, y: 0.8112), tip: CGPoint(x: 0.0993, y: 0.8761)),
    ]
    /// あくびの峰のひげ（根元 → 先端の中心線と中央の太さ）。参考 yawn-reference.png の左右のひげ（端の白っぽい画素も含めて
    /// 測る）の端の位置と中心線を平均して当てはめた（trace_yawn.py。残差 rms ≤ 0.5px @941。左右の外接は 0.001 以内で一致）。
    /// 通常より上にあるだけで長さはほぼ同じ、下の 1 本は少し太い。既存の表情は yawn 0 なので触らず、yawn > 0 のときだけ
    /// ここへ補間する。
    private static let yawnWhiskerSpecs: [WhiskerSpec] = [
        WhiskerSpec(root: CGPoint(x: 0.2460, y: 0.5221), control1: CGPoint(x: 0.1809, y: 0.4913),
                    control2: CGPoint(x: 0.1066, y: 0.4937), tip: CGPoint(x: 0.0453, y: 0.5433), thickness: 0.0149),
        WhiskerSpec(root: CGPoint(x: 0.2630, y: 0.5553), control1: CGPoint(x: 0.1929, y: 0.5539),
                    control2: CGPoint(x: 0.1224, y: 0.5793), tip: CGPoint(x: 0.0651, y: 0.6514), thickness: 0.0149),
        WhiskerSpec(root: CGPoint(x: 0.2627, y: 0.5964), control1: CGPoint(x: 0.2049, y: 0.6132),
                    control2: CGPoint(x: 0.1503, y: 0.6498), tip: CGPoint(x: 0.1099, y: 0.7279), thickness: 0.0169),
    ]
    /// ひげの中央の太さ（キャンバス高さに対する比）、両端の丸い端の太さ（中央に対する比）、
    /// 端から中央への太り方（1 で直線的、大きいほど早く太る）。
    static let whiskerThickness: CGFloat = 0.0146
    private static let whiskerEndRatio: CGFloat = 0.33
    private static let whiskerFullness: CGFloat = 1.0

    /// 中央が太く両端へ細る丸い端のひげ（中心線を 2 分割し、上下に太さ分ずらした 4 本の 3 次ベジェと
    /// 両端の半円で閉じる）。
    /// lift は外側の先端を上げる角度（度）、spread は扇の開き（度/本）。あくび（yawn > 0）では、表情の角度を付けた
    /// 通常のひげから峰のひげ（`yawnWhiskerSpecs`）へ根元・制御点・先端・太さを線形に補間する。
    static func whiskers(side: CatFaceSide, appearance: CatFaceAppearance, lineScale: CGFloat = 1) -> [NormalizedPath] {
        let settings = appearance.whiskers(side)
        let a = CGFloat(aspectRatio)
        let yawn = min(max(appearance.yawn, 0), 1)
        return leftWhiskerSpecs.enumerated().map { index, spec in
            let angle = (settings.lift + settings.spread * CGFloat(1 - index)) * .pi / 180
            var root = spec.root
            var c1 = rotated(spec.control1, around: root, by: angle)
            var c2 = rotated(spec.control2, around: root, by: angle)
            var tip = rotated(spec.tip, around: root, by: angle)
            var thickness = spec.thickness
            if yawn > 0 {
                let peak = yawnWhiskerSpecs[index]
                func mix(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
                    CGPoint(x: from.x + (to.x - from.x) * yawn, y: from.y + (to.y - from.y) * yawn)
                }
                root = mix(root, peak.root)
                c1 = mix(c1, peak.control1)
                c2 = mix(c2, peak.control2)
                tip = mix(tip, peak.tip)
                thickness += (peak.thickness - thickness) * yawn
            }
            // 中心線を t = 0.5 で分割（de Casteljau）
            let q1 = mid(root, c1), q2 = mid(c1, c2), q3 = mid(c2, tip)
            let r1 = mid(q1, q2), r2 = mid(q2, q3)
            let m = mid(r1, r2)
            // 実寸での弦の法線
            let chord = CGPoint(x: (tip.x - root.x) * a, y: tip.y - root.y)
            let length = max(0.000_1, hypot(chord.x, chord.y))
            let normal = CGPoint(x: -chord.y / length, y: chord.x / length)
            let along = CGPoint(x: chord.x / length, y: chord.y / length)
            let half = thickness * lineScale / 2
            let end = half * whiskerEndRatio
            let shoulder = end + (half - end) * whiskerFullness
            func offset(_ point: CGPoint, _ amount: CGFloat, forward: CGFloat = 0) -> CGPoint {
                CGPoint(x: point.x + (normal.x * amount + along.x * forward) / a,
                        y: point.y + normal.y * amount + along.y * forward)
            }
            // 半円の端は 1 本の 3 次ベジェ（制御点を半径の 4/3 だけ外へ）で近似する。
            let cap = end * 4 / 3
            let path = NormalizedPath([
                .move(offset(root, end)),
                .curve(to: offset(m, half), control1: offset(q1, shoulder), control2: offset(r1, half)),
                .curve(to: offset(tip, end), control1: offset(r2, half), control2: offset(q3, shoulder)),
                .curve(to: offset(tip, -end), control1: offset(tip, end, forward: cap),
                       control2: offset(tip, -end, forward: cap)),
                .curve(to: offset(m, -half), control1: offset(q3, -shoulder), control2: offset(r2, -half)),
                .curve(to: offset(root, -end), control1: offset(r1, -half), control2: offset(q1, -shoulder)),
                .curve(to: offset(root, end), control1: offset(root, -end, forward: -cap),
                       control2: offset(root, end, forward: -cap)),
                .close,
            ])
            return side == .left ? path : path.mirrored
        }
    }

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func rotated(_ point: CGPoint, around origin: CGPoint, by angle: CGFloat) -> CGPoint {
        let a = CGFloat(aspectRatio)
        let dx = (point.x - origin.x) * a
        let dy = point.y - origin.y
        // 左のひげは -x へ伸びるので、正の角度で先端が上がる向きに回す。
        let x = dx * cos(angle) - dy * sin(angle)
        let y = dx * sin(angle) + dy * cos(angle)
        return CGPoint(x: origin.x + x / a, y: origin.y + y)
    }

    // MARK: 眠りの Z（sleeping）

    /// 右上の 3 つの Z（小 → 中 → 大で右上がり）。外接の左上（キャンバス単位）と高さ（キャンバス高さ単位）。
    /// 大きさと縦の位置は参照 sleeping-zzz-reference.png の実測、横は実測からキャンバス幅の 3.5% 右
    /// （「もう少し右へ」という要望に合わせた調整値。docs/design/sleeping-zzz-2026-10-28/visual-comparison.md）。
    private static let sleepMarkBoxes: [(origin: CGPoint, height: CGFloat)] = [
        (CGPoint(x: 0.7788, y: 0.2644), 0.0687),
        (CGPoint(x: 0.8263, y: 0.1837), 0.0949),
        (CGPoint(x: 0.8894, y: 0.0830), 0.1332),
    ]

    static func sleepMarks() -> [NormalizedPath] {
        sleepMarkBoxes.map { sleepMark(origin: $0.origin, height: $0.height) }
    }

    /// 太い Z。字形の単位は Z の高さで、横も実寸（キャンバスの x へは aspectRatio で割って換算）。
    /// 上下の横棒と斜めの棒はほぼ同じ太さで、外側の角を少し丸め、斜めの棒と横棒の内側の角は尖らせる。
    private static func sleepMark(origin: CGPoint, height h: CGFloat) -> NormalizedPath {
        let width: CGFloat = 0.877
        let topBarBottom: CGFloat = 0.255
        let bottomBarTop: CGFloat = 0.738
        let topBarInset: CGFloat = 0.02
        // 斜めの棒: 上の横棒の下端での中心 x、横幅、下へ 1 進むと左へ進む量。
        let diagonalCenter: CGFloat = 0.649
        let diagonalWidth: CGFloat = 0.366
        let slope: CGFloat = 0.874
        func diagonalX(_ y: CGFloat, _ offset: CGFloat) -> CGFloat {
            diagonalCenter + offset - slope * (y - topBarBottom)
        }
        let right = diagonalWidth / 2
        let left = -diagonalWidth / 2
        // 角の丸め。横棒の斜めの棒と離れた側の端（上の棒の左下、下の棒の右上）は少し大きく丸める。
        let corner: CGFloat = 0.05
        let barEnd: CGFloat = 0.075
        let corners: [(point: CGPoint, cut: CGFloat)] = [
            (CGPoint(x: topBarInset, y: 0), corner),
            (CGPoint(x: width, y: 0), corner),
            (CGPoint(x: width, y: topBarBottom - (width - diagonalX(topBarBottom, right)) / slope), corner),
            (CGPoint(x: diagonalX(bottomBarTop, right), y: bottomBarTop), 0),
            (CGPoint(x: width, y: bottomBarTop), barEnd),
            (CGPoint(x: width, y: 1), corner),
            (CGPoint(x: 0, y: 1), corner),
            (CGPoint(x: 0, y: topBarBottom + diagonalX(topBarBottom, left) / slope), corner),
            (CGPoint(x: diagonalX(topBarBottom, left), y: topBarBottom), 0),
            (CGPoint(x: topBarInset, y: topBarBottom), barEnd),
        ]
        return roundedPolygon(corners) { point in
            CGPoint(x: origin.x + point.x * h / CGFloat(aspectRatio), y: origin.y + point.y * h)
        }
    }

    /// 頂点ごとに辺を cut だけ戻して角を丸めた閉じた多角形（丸めは円弧に近い 3 次ベジェ。直角なら半径 cut の 4 分円）。
    private static func roundedPolygon(_ corners: [(point: CGPoint, cut: CGFloat)],
                                       transform: (CGPoint) -> CGPoint) -> NormalizedPath {
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        var commands: [NormalizedPath.Command] = []
        for (index, corner) in corners.enumerated() {
            let previous = corners[(index + corners.count - 1) % corners.count].point
            let next = corners[(index + 1) % corners.count].point
            func toward(_ target: CGPoint) -> CGPoint {
                let length = hypot(target.x - corner.point.x, target.y - corner.point.y)
                return mix(corner.point, target, corner.cut / length)
            }
            let start = toward(previous)
            commands.append(index == 0 ? .move(transform(start)) : .line(transform(start)))
            if corner.cut > 0 {
                let end = toward(next)
                commands.append(.curve(to: transform(end), control1: transform(mix(start, corner.point, 0.5523)),
                                       control2: transform(mix(end, corner.point, 0.5523))))
            }
        }
        commands.append(.close)
        return NormalizedPath(commands)
    }

    // MARK: 検証用の公開ヘルパー（XCTest と scripts/face-render の check が共有する）

    /// 描画に使う全パスのアンカーと制御点。
    static func drawingPoints(for appearance: CatFaceAppearance, mouthPose: MouthPose) -> [CGPoint] {
        let mouth = mouth(appearance: appearance, opening: mouthOpening(for: mouthPose))
        let paths = CatFaceSide.allCases.flatMap { eye(side: $0, appearance: appearance).all }
            + [nose(yawn: appearance.yawn)]
            + [mouth.neck] + mouth.lines + [mouth.lowerLip, mouth.cavity, mouth.round]
            + [mouth.yawnOutline, mouth.yawnTongue] + mouth.yawnFangs
            + CatFaceSide.allCases.flatMap { whiskers(side: $0, appearance: appearance) }
            + (appearance.sleepMarks > 0 ? sleepMarks() : [])
        return paths.flatMap(\.points)
    }

    /// 見えている口の外接矩形（線幅を含む）。
    static func mouthBounds(for appearance: CatFaceAppearance, mouthPose: MouthPose) -> CGRect {
        let a = CGFloat(aspectRatio)
        let bounds = featurePaths(for: appearance, mouthPose: mouthPose, in: CGRect(x: 0, y: 0, width: a, height: 1))
            .filter { $0.kind == .mouthLine || $0.kind == .mouthOpening }
            .reduce(CGRect.null) { $0.union($1.path.boundingRect) }
        return CGRect(x: bounds.minX / a, y: bounds.minY, width: bounds.width / a, height: bounds.height)
    }

    enum FeatureKind: Equatable, Sendable {
        case eye(CatFaceSide)
        case nose
        case mouthLine
        case mouthOpening
        case whisker(CatFaceSide)
    }

    struct FeaturePath {
        let kind: FeatureKind
        let name: String
        let path: Path
    }

    /// 交差の検査用に、要素ごとのパスを描画と同じ形で返す（塗りはそのまま、線は描画と同じ線幅・端の形で太らせる）。
    /// 線の太らせは CoreGraphics の `copy(strokingWithWidth:)` を使う（SwiftUI の `strokedPath` の結果は
    /// 集合演算で引数の順により誤った交差を返したため。macOS 26 で確認）。
    static func featurePaths(for appearance: CatFaceAppearance, mouthPose: MouthPose, lineScale: CGFloat = 1,
                             in rect: CGRect) -> [FeaturePath] {
        let lineWidth = mouthLineWidth * rect.height * lineScale
        func stroked(_ path: NormalizedPath) -> CGPath {
            path.path(in: rect).cgPath.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        let mouth = mouth(appearance: appearance, opening: mouthOpening(for: mouthPose), lineScale: lineScale)
        var result = CatFaceSide.allCases.map { side in
            let eye = eye(side: side, appearance: appearance)
            // 完全に閉じた目は金色の弧だけが見える（外形はまぶたの下）。
            let visible = appearance.eye(side).closed >= 1 ? eye.closedLid : eye.outline
            return FeaturePath(kind: .eye(side), name: "\(side) eye", path: visible.path(in: rect))
        }
        result.append(FeaturePath(kind: .nose, name: "nose", path: nose(yawn: appearance.yawn).path(in: rect)))
        if mouth.showsLines {
            result.append(FeaturePath(kind: .mouthLine, name: "mouth stem", path: mouth.neck.path(in: rect)))
            result += zip(["left mouth arc", "right mouth arc"], mouth.lines).map {
                FeaturePath(kind: .mouthLine, name: $0, path: Path(stroked($1)))
            }
        }
        if mouth.showsOpening {
            result.append(FeaturePath(kind: .mouthOpening, name: "lower lip", path: Path(stroked(mouth.lowerLip))))
            result.append(FeaturePath(kind: .mouthOpening, name: "mouth inside", path: mouth.cavity.path(in: rect)))
        }
        if mouth.showsRound {
            let round = mouth.round.path(in: rect).cgPath
            result.append(FeaturePath(kind: .mouthOpening, name: "round mouth", path: Path(round.union(stroked(mouth.round)))))
        }
        if mouth.showsYawn {
            let inside = mouth.yawnOutline.path(in: rect).cgPath
            result.append(FeaturePath(kind: .mouthLine, name: "yawn mouth outline", path: Path(stroked(mouth.yawnOutline))))
            result.append(FeaturePath(kind: .mouthOpening, name: "yawn mouth inside", path: Path(inside)))
            // 舌は描画と同じく輪郭の内側で切り抜いた形。
            result.append(FeaturePath(kind: .mouthOpening, name: "yawn tongue",
                                      path: Path(inside.intersection(mouth.yawnTongue.path(in: rect).cgPath))))
            result += zip(["left yawn fang", "right yawn fang"], mouth.yawnFangs).map {
                FeaturePath(kind: .mouthOpening, name: $0, path: $1.path(in: rect))
            }
        }
        for side in CatFaceSide.allCases {
            result += whiskers(side: side, appearance: appearance, lineScale: lineScale).enumerated().map {
                FeaturePath(kind: .whisker(side), name: "\(side) whisker \($0.offset + 1)", path: $0.element.path(in: rect))
            }
        }
        return result
    }

    /// 左右対称であるべき要素のうち、右の点集合を x→1−x で鏡映しても左の点集合と一致しない要素名。
    /// パスの描き順や開始点には依存せず、要素ごとの点集合として比べる。ハイライトは光源が一つなので含めない。
    static func unmirroredShapeNames(for appearance: CatFaceAppearance, tolerance: CGFloat = 0.000_1) -> [String] {
        let leftEye = eye(side: .left, appearance: appearance).mirroredShapes
        let rightEye = eye(side: .right, appearance: appearance).mirroredShapes
        let leftWhiskers = whiskers(side: .left, appearance: appearance)
        let rightWhiskers = whiskers(side: .right, appearance: appearance)
        let pairs = zip(leftEye, rightEye).map { ($0.name, $0.path, $1.path) }
            + leftWhiskers.indices.map { ("whisker \($0 + 1)", leftWhiskers[$0], rightWhiskers[$0]) }
        return pairs.compactMap { name, left, right in
            var remaining = right.points.map(CatFaceSide.right.point)
            guard remaining.count == left.points.count else { return name }
            for point in left.points {
                guard let match = remaining.firstIndex(where: {
                    abs($0.x - point.x) <= tolerance && abs($0.y - point.y) <= tolerance
                }) else { return name }
                remaining.remove(at: match)
            }
            return nil
        }
    }

    /// 目の実寸の大きさ（幅×高さの幾何平均）。happy の拡大率の検査に使う。
    static func eyeSize(for appearance: CatFaceAppearance, side: CatFaceSide) -> CGFloat {
        let bounds = eye(side: side, appearance: appearance).outline.bounds
        return sqrt(bounds.width * CGFloat(aspectRatio) * bounds.height)
    }
}

/// 正規化座標のパス。描画・境界計算・検証が同じ値を使う。
struct NormalizedPath: Sendable {
    enum Command: Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close

        static func move(_ x: CGFloat, _ y: CGFloat) -> Self { .move(CGPoint(x: x, y: y)) }
        static func line(_ x: CGFloat, _ y: CGFloat) -> Self { .line(CGPoint(x: x, y: y)) }

        var points: [CGPoint] {
            switch self {
            case let .move(point), let .line(point): [point]
            case let .curve(to, control1, control2): [control1, control2, to]
            case .close: []
            }
        }

    }

    let commands: [Command]

    init(_ commands: [Command]) {
        self.commands = commands
    }

    /// 4本の3次ベジェで近似した楕円。
    static func ellipse(center: CGPoint, radii: CGSize) -> Self {
        let k: CGFloat = 0.5523
        let rx = radii.width
        let ry = radii.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * rx, y: center.y + y * ry) }
        return Self([
            .move(p(1, 0)),
            .curve(to: p(0, 1), control1: p(1, k), control2: p(k, 1)),
            .curve(to: p(-1, 0), control1: p(-k, 1), control2: p(-1, k)),
            .curve(to: p(0, -1), control1: p(-1, -k), control2: p(-k, -1)),
            .curve(to: p(1, 0), control1: p(k, -1), control2: p(1, -k)),
            .close,
        ])
    }

    var points: [CGPoint] { commands.flatMap(\.points) }
    var mirrored: Self { mapped(CatFaceSide.right.point) }

    /// 全てのアンカーと制御点を transform で写したパス（鏡映・平行移動・相似の拡大縮小に使う）。
    func mapped(_ transform: (CGPoint) -> CGPoint) -> Self {
        Self(commands.map { command in
            switch command {
            case let .move(point): .move(transform(point))
            case let .line(point): .line(transform(point))
            case let .curve(to, control1, control2):
                .curve(to: transform(to), control1: transform(control1), control2: transform(control2))
            case .close: .close
            }
        })
    }

    /// 左半分（中心線上の点から始まり中心線上の点で終わる開いたパス）を反転してつなぎ、閉じる。
    func closedWithMirror() -> Self {
        var result = commands
        var anchors: [CGPoint] = []
        for command in commands {
            switch command {
            case let .move(point), let .line(point): anchors.append(point)
            case let .curve(to, _, _): anchors.append(to)
            case .close: break
            }
        }
        for (index, command) in commands.enumerated().reversed() where index > 0 {
            let previous = anchors[index - 1]
            switch command {
            case .line:
                result.append(.line(CatFaceSide.right.point(previous)))
            case let .curve(_, control1, control2):
                result.append(.curve(to: CatFaceSide.right.point(previous),
                                     control1: CatFaceSide.right.point(control2),
                                     control2: CatFaceSide.right.point(control1)))
            case .move, .close:
                break
            }
        }
        result.append(.close)
        return Self(result)
    }

    /// 曲線そのものの外接矩形（制御点ではなく実際の線）。
    var bounds: CGRect {
        path(in: CGRect(x: 0, y: 0, width: 1, height: 1)).cgPath.boundingBoxOfPath
    }

    func path(in rect: CGRect) -> Path {
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + normalized.x * rect.width,
                    y: rect.minY + normalized.y * rect.height)
        }

        var path = Path()
        for command in commands {
            switch command {
            case let .move(value): path.move(to: point(value))
            case let .line(value): path.addLine(to: point(value))
            case let .curve(to, control1, control2):
                path.addCurve(to: point(to), control1: point(control1), control2: point(control2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
