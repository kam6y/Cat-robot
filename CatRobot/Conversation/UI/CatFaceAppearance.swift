import SwiftUI

/// 表情ごとの顔の形と色の値。描画は `CatFaceGeometry` がこの値からパスを作る。
/// 目の局所座標は外形をおよそ単位円とし、u は鼻側が正、v は下が正。
struct CatFaceAppearance: Equatable, Sendable {
    struct Eye: Equatable, Sendable {
        /// この目のまばたきの量（0 開き、1 閉じ）。CatFaceLife のまばたきが片目ずつ時間をずらして動かす。
        var blink: CGFloat = 0
        /// 基準の目に対する横・縦の倍率。大きくなるときは下端を保って上と外側へ広がる。
        var widthScale: CGFloat = 1
        var heightScale: CGFloat = 1
        /// 下端を保った位置からさらに上げる量（キャンバス高さ単位）。
        var lift: CGFloat = 0
        /// 外側（耳側）へ寄せる量（キャンバス幅単位）。
        var outwardShift: CGFloat = 0
        /// 外形の丸さ。0 は neutral-b の下ぶくれの形、1 は happy-b のほぼ真円。
        var outlineRoundness: CGFloat = 0
        /// 瞳は太い縦長の楕円で、やや鼻側に寄る（neutral-b の実測）。
        var pupilCenter = CGPoint(x: 0.234, y: -0.004)
        var pupilRadii = CGSize(width: 0.445, height: 0.845)
        /// 瞳を囲む層（上の濃い琥珀と下の橙の三日月）の下端（局所座標 v）。その下が明るい黄の帯になる。
        var innerIrisBottom: CGFloat = 0.89
        /// 上まぶたの下がり具合（0 開き、1 閉じ）と傾き（正で外側が下がる）。
        var lid: CGFloat = 0
        var lidTilt: CGFloat = 0
        /// 閉じた目の金色の弧（sleeping）の見え方。0 で開いた目、1 で弧だけが見える。
        var closed: CGFloat = 0
        /// ハイライトは光源が一つ（左上）なので、瞳の中心から画面の向きで測る（左右反転しない）。
        var highlightOffset = CGPoint(x: -0.313, y: -0.494)
        var highlightRadius: CGFloat = 0.198
        var dotOffset = CGPoint(x: 0.148, y: -0.248)
        var dotRadius: CGFloat = 0.034
        var dotOpacity: CGFloat = 0
        var sparkleOffset = CGPoint(x: 0.256, y: 0.273)
        var sparkleSize: CGFloat = 0.165
        var sparkleOpacity: CGFloat = 0
    }

    struct Whiskers: Equatable, Sendable {
        /// 外側の先端を上げる角度（度）と、3本の扇の開き（度/本）。
        var lift: CGFloat = 0
        var spread: CGFloat = 0
    }

    var leftEye: Eye
    var rightEye: Eye
    /// 0 で neutral-b、1 で happy-b の虹彩の色。
    var irisBrightness: CGFloat = 0
    /// 目の縁のにじむ光（静的）。
    var glow: CGFloat = 0
    var mouthWidth: CGFloat = 1
    var mouthSmile: CGFloat = 1
    /// 0 で ω の口、1 で小さい丸い口。
    var mouthRoundness: CGFloat = 0
    /// 右上の眠りの Z（sleeping）の見え方。0 で無し、1 で 3 つの Z が見える。
    var sleepMarks: CGFloat = 0
    /// あくび。0 で通常の口・鼻・ひげ、1 で参考 docs/design/idle-cat-life-2026-10-30/yawn-reference.png の峰
    /// （大きく開いた口に舌と牙、鼻とひげは一緒に上がり、閉じた目の弧は ∩ になる）。間は鼻の下から口が育つ。
    var yawn: CGFloat = 0
    var leftWhiskers = Whiskers()
    var rightWhiskers = Whiskers()

    func eye(_ side: CatFaceSide) -> Eye {
        var eye = side == .left ? leftEye : rightEye
        guard yawn > 0 else { return eye }
        // Interruption may tween directly to any preset. Close before the raised
        // whiskers reach the iris, and reopen only after they have descended.
        // The nearest preset outline is reached around yawn 0.18; finish by 0.15.
        let closure = min(1, yawn / 0.15)
        eye.lid = max(eye.lid, closure)
        eye.closed = max(eye.closed, closure) * CatFaceGeometry.closedArcVisibility(eye.lid)
        return eye
    }

    func whiskers(_ side: CatFaceSide) -> Whiskers {
        side == .left ? leftWhiskers : rightWhiskers
    }

    static func preset(_ expression: FaceExpression) -> Self {
        switch expression {
        case .neutral: neutral
        case .happy: happy
        case .curious: curious
        case .thinking: thinking
        case .speaking: speaking
        case .sleepy: sleepy
        case .surprised: surprised
        case .sorry: sorry
        case .sleeping: sleeping
        }
    }
}

// MARK: - プリセット（実測値と根拠は docs/design/face-expression-2026-10-26/visual-comparison.md）

extension CatFaceAppearance {
    /// neutral-b: ハイライトは左上の光源から。左目には小さな白点がなく、右目にだけある。
    static let neutral = CatFaceAppearance(
        leftEye: Eye(),
        rightEye: Eye(highlightOffset: CGPoint(x: -0.142, y: -0.481), highlightRadius: 0.188, dotOpacity: 1)
    )

    /// happy-b: 目を開いたまま大きくし（下端はほぼ保つ）、瞳を広げ、金色・縁の光・四つ星を足す。
    static let happy: CatFaceAppearance = {
        var value = neutral
        value.updateEyes { eye in
            eye.widthScale = 1.208
            eye.heightScale = 1.136
            eye.lift = -0.0019
            eye.outwardShift = 0.007
            eye.outlineRoundness = 1
            eye.pupilCenter = CGPoint(x: 0.198, y: -0.010)
            eye.pupilRadii = CGSize(width: 0.548, height: 0.80)
            // 橙の三日月の下端を上げ、下の明るい黄の帯を happy-b の太さにする（中央の列で目の高さの約 6%）。
            eye.innerIrisBottom = 0.870
            eye.highlightRadius = 0.203
            eye.dotRadius = 0.053
            eye.dotOpacity = 1
            eye.sparkleOpacity = 1
        }
        value.leftEye.highlightOffset = CGPoint(x: -0.323, y: -0.421)
        value.rightEye.highlightOffset = CGPoint(x: -0.226, y: -0.418)
        value.leftEye.dotOffset = CGPoint(x: -0.024, y: -0.134)
        value.rightEye.dotOffset = CGPoint(x: 0.058, y: -0.132)
        value.leftEye.sparkleOffset = CGPoint(x: 0.273, y: 0.273)
        value.rightEye.sparkleOffset = CGPoint(x: 0.323, y: 0.274)
        value.irisBrightness = 1
        value.glow = 1
        // ひげは neutral と同じ（happy-b のひげは neutral-b と 1px 以内で一致。採用画像の一致を仕様の
        // 「ひげをわずかに上げる」より優先する判断）。
        return value
    }()

    static let curious: CatFaceAppearance = {
        var value = neutral
        // 瞳は少し上へ。上端は neutral と同じ高さに保ち（瞳の上に虹彩を残す）、下端を上げて縦を少し詰める。
        value.updateEyes { eye in
            eye.pupilCenter.y = -0.05
            eye.pupilRadii.height = 0.80
        }
        value.rightEye.widthScale = 1.08
        value.rightEye.heightScale = 1.08
        value.rightEye.lift = 0.012
        value.rightWhiskers.lift = 4
        value.mouthWidth = 0.85
        value.mouthSmile = 0.9
        return value
    }()

    static let thinking: CatFaceAppearance = {
        var value = neutral
        // まぶたは少しだけ下げ、瞳を小さめにして上へ寄せる（瞳の上端がまぶたの下に見え、上を見ているのが分かる）。
        value.updateEyes { eye in
            eye.lid = 0.16
            eye.pupilRadii = CGSize(width: 0.40, height: 0.60)
        }
        // 両目とも画面の右上を見る（左目は鼻側、右目は耳側へ、同じ量）。
        value.leftEye.pupilCenter = CGPoint(x: 0.434, y: -0.08)
        value.rightEye.pupilCenter = CGPoint(x: 0.034, y: -0.08)
        // 中段・下段のひげを水平へ寄せる（neutral の +5° / −8° / −18° → +5° / −4° / −10°）。
        value.updateWhiskers { whiskers in
            whiskers.lift = 4
            whiskers.spread = -4
        }
        value.mouthWidth = 0.88
        value.mouthSmile = 0.65
        return value
    }()

    static let speaking: CatFaceAppearance = {
        var value = neutral
        value.updateEyes { eye in
            eye.widthScale = 1.03
            eye.heightScale = 1.03
        }
        return value
    }()

    static let sleepy: CatFaceAppearance = {
        var value = neutral
        value.updateEyes { eye in
            eye.lid = 0.55
            eye.pupilCenter.y = 0.12
        }
        value.mouthWidth = 0.8
        value.mouthSmile = 0.75
        value.updateWhiskers { $0.lift = -7 }
        return value
    }()

    static let surprised: CatFaceAppearance = {
        var value = neutral
        value.updateEyes { eye in
            eye.widthScale = 1.14
            eye.heightScale = 1.14
            eye.lift = 0.012
            eye.outlineRoundness = 1
            eye.pupilCenter = CGPoint(x: 0.12, y: -0.02)
            eye.pupilRadii = CGSize(width: 0.30, height: 0.56)
            eye.highlightRadius = 0.13
            eye.highlightOffset = CGPoint(x: -0.20, y: -0.30)
        }
        value.mouthRoundness = 1
        value.updateWhiskers { $0.spread = 2.5 }
        return value
    }()

    static let sorry: CatFaceAppearance = {
        var value = neutral
        value.updateEyes { eye in
            eye.lid = 0.24
            eye.lidTilt = 0.25
            eye.pupilCenter.y = 0.10
        }
        value.mouthWidth = 0.82
        value.mouthSmile = 0.55
        value.updateWhiskers { $0.lift = -9 }
        return value
    }()

    /// sleeping: sleepy の鼻・口・ひげのまま、まぶたを完全に閉じて虹彩を隠し、閉じた目の金色の弧だけを見せる
    /// （下書き docs/design/sleeping-2026-10-26/sleeping-draft.png の実測は同じ場所の visual-comparison.md）。
    static let sleeping: CatFaceAppearance = {
        var value = sleepy
        value.updateEyes { eye in
            eye.lid = 1
            eye.closed = 1
        }
        // 右上に小・中・大の青い Z（docs/design/sleeping-zzz-2026-10-28/sleeping-zzz-reference.png）。
        value.sleepMarks = 1
        return value
    }()

    /// あくびの峰（表情プリセットではなく、sleepy へ移る前に一度だけ通る姿）: sleepy のまま両目をぎゅっと閉じて
    /// ∩ の金色の弧を見せ、口を大きく開ける（参考 docs/design/idle-cat-life-2026-10-30/yawn-reference.png）。
    static let yawning: CatFaceAppearance = {
        var value = sleepy
        value.updateEyes { eye in
            eye.lid = 1
            eye.closed = 1
        }
        value.yawn = 1
        return value
    }()

    /// 両目に同じ変更を加える。
    mutating func updateEyes(_ body: (inout Eye) -> Void) {
        body(&leftEye)
        body(&rightEye)
    }

    private mutating func updateWhiskers(_ body: (inout Whiskers) -> Void) {
        body(&leftWhiskers)
        body(&rightWhiskers)
    }
}

// MARK: - 表情間の補間

extension CatFaceAppearance {
    /// SwiftUI が表情の切り替えを補間するための数値の並び。
    struct AnimationVector: VectorArithmetic, Sendable {
        var values: [Double]

        static var zero: Self { Self(values: []) }

        static func + (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, +) }
        static func - (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, -) }

        mutating func scale(by rhs: Double) {
            values = values.map { $0 * rhs }
        }

        var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

        private static func combine(_ lhs: Self, _ rhs: Self, _ operation: (Double, Double) -> Double) -> Self {
            let count = max(lhs.values.count, rhs.values.count)
            return Self(values: (0..<count).map { index in
                operation(index < lhs.values.count ? lhs.values[index] : 0,
                          index < rhs.values.count ? rhs.values[index] : 0)
            })
        }
    }

    /// 定数の key path を共有し、描画ごとの配列構築と path 合成を避ける。
    private static let animatedKeyPaths: [WritableKeyPath<CatFaceAppearance, CGFloat> & Sendable] = [
        \.leftEye.widthScale, \.leftEye.heightScale, \.leftEye.lift,
        \.leftEye.outwardShift, \.leftEye.outlineRoundness, \.leftEye.pupilCenter.x,
        \.leftEye.pupilCenter.y, \.leftEye.pupilRadii.width, \.leftEye.pupilRadii.height,
        \.leftEye.innerIrisBottom, \.leftEye.lid, \.leftEye.lidTilt,
        \.leftEye.highlightOffset.x, \.leftEye.highlightOffset.y, \.leftEye.highlightRadius,
        \.leftEye.dotOffset.x, \.leftEye.dotOffset.y, \.leftEye.dotRadius,
        \.leftEye.dotOpacity, \.leftEye.sparkleOffset.x, \.leftEye.sparkleOffset.y,
        \.leftEye.sparkleSize, \.leftEye.sparkleOpacity, \.rightEye.widthScale,
        \.rightEye.heightScale, \.rightEye.lift, \.rightEye.outwardShift,
        \.rightEye.outlineRoundness, \.rightEye.pupilCenter.x, \.rightEye.pupilCenter.y,
        \.rightEye.pupilRadii.width, \.rightEye.pupilRadii.height, \.rightEye.innerIrisBottom,
        \.rightEye.lid, \.rightEye.lidTilt, \.rightEye.highlightOffset.x,
        \.rightEye.highlightOffset.y, \.rightEye.highlightRadius, \.rightEye.dotOffset.x,
        \.rightEye.dotOffset.y, \.rightEye.dotRadius, \.rightEye.dotOpacity,
        \.rightEye.sparkleOffset.x, \.rightEye.sparkleOffset.y, \.rightEye.sparkleSize,
        \.rightEye.sparkleOpacity, \.leftWhiskers.lift, \.leftWhiskers.spread,
        \.rightWhiskers.lift, \.rightWhiskers.spread, \.irisBrightness,
        \.glow, \.mouthWidth, \.mouthSmile,
        \.mouthRoundness, \.leftEye.closed, \.rightEye.closed,
        \.sleepMarks, \.leftEye.blink, \.rightEye.blink,
        \.yawn,
    ]

    var animationVector: AnimationVector {
        get { AnimationVector(values: Self.animatedKeyPaths.map { Double(self[keyPath: $0]) }) }
        set {
            for (keyPath, value) in zip(Self.animatedKeyPaths, newValue.values) {
                self[keyPath: keyPath] = CGFloat(value)
            }
        }
    }

    /// SwiftUI の表情の補間と同じ数値で、この表情から other へ fraction だけ進んだ表情（テストと描画ハーネスが共有する）。
    func interpolated(toward other: CatFaceAppearance, fraction: Double) -> CatFaceAppearance {
        var delta = other.animationVector - animationVector
        delta.scale(by: fraction)
        var result = self
        result.animationVector = animationVector + delta
        return result
    }
}
