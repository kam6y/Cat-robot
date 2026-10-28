import CoreGraphics
import Foundation

/// 採用画像の実測。座標は 3 通りで出す:
/// - px: 元画像 1536×1024 の画素
/// - scr: 画面矩形（黒い矩形の外接）に対する正規化
/// - cv: 顔の 16:9 キャンバスに対する正規化（Reference.swift の対応＝高さ基準の等比・中央）
/// 目の中の形は、目の外接の中心と半径で正規化した局所座標 (u: 鼻側が正, v: 下が正) でも出す。
@MainActor
enum Measurement {
    static let sleepingDirectory = "docs/design/sleeping-2026-10-26"
    /// sleeping の下書き（16:9 の全面がキャンバス）。計測と描画の比較で同じ画像を読む。
    static let sleepingDraftPath = "\(sleepingDirectory)/sleeping-draft.png"

    static func run(root: String, rendered: Bool) throws {
        let directory = "\(root)/docs/design/face-expression-2026-10-26"
        for (name, expression) in [("neutral", FaceExpression.neutral), ("happy", .happy)] {
            if rendered {
                // 現在の SwiftUI 描画を同じ計測にかける（採用画像の数値と直接比べる）。
                report(ReferenceImage(name: "rendered \(name)", rendered: FaceRender.screenImage(expression, .closed)))
            } else {
                report(try ReferenceImage(name: "\(name)-b.png", path: "\(directory)/\(name)-b.png"))
            }
        }
    }

    private static func report(_ reference: ReferenceImage) {
        let bitmap = reference.bitmap
        let screen = reference.screen
        let tones = ToneMap(bitmap: bitmap, region: screen)
        print("== \(reference.name) \(bitmap.width)x\(bitmap.height)")
        print(String(format: "screen rect px x %.0f..%.0f y %.0f..%.0f (%.0fx%.0f, %.3f:1)",
                     screen.minX, screen.maxX - 1, screen.minY, screen.maxY - 1, screen.width, screen.height,
                     screen.width / screen.height))
        print(String(format: "canvas rect px x %.1f..%.1f (16:9 of screen height, centered)",
                     reference.canvasRect.minX, reference.canvasRect.maxX))

        func describe(_ label: String, _ rect: CGRect) { Self.describe(label, rect, reference: reference) }
        func meanColor(_ pixels: [(Int, Int)]) -> String { Self.meanColor(pixels, bitmap: bitmap) }

        // 目（虹彩の 4 色の連結成分のうち大きい 2 つ）
        let irises = components(width: bitmap.width, height: bitmap.height, region: screen, minimumCount: 500) {
            tones[$0, $1].isIris
        }.prefix(2).sorted { $0.minX < $1.minX }
        var eyeBounds: [CGRect] = []
        for (index, iris) in irises.enumerated() {
            let side = index == 0 ? "left" : "right"
            let inward: CGFloat = index == 0 ? 1 : -1
            let box = iris.bounds
            eyeBounds.append(box)
            describe("\(side) eye", box)
            let center = CGPoint(x: box.midX, y: box.midY)
            let radius = CGSize(width: box.width / 2, height: box.height / 2)
            func local(_ p: CGPoint) -> CGPoint {
                CGPoint(x: inward * (p.x - center.x) / radius.width, y: (p.y - center.y) / radius.height)
            }

            // 瞳 = 目の外接の中で、外周から黒でたどり着けない黒い画素
            let inner = enclosedPixels(in: box, tones: tones) { $0 == .black }
            var pupil = Component()
            inner.forEach { pupil.add($0.0, $0.1) }
            if pupil.count > 0 {
                let pupilCenter = CGPoint(x: pupil.bounds.midX, y: pupil.bounds.midY)
                describe("\(side) pupil", pupil.bounds)
                let l = local(pupilCenter)
                print(String(format: "  \(side) pupil local center (%.3f, %.3f) radii (%.3f, %.3f) w/h %.3f fill %.3f of ellipse",
                             l.x, l.y, pupil.bounds.width / box.width, pupil.bounds.height / box.height,
                             pupil.bounds.width / pupil.bounds.height,
                             Double(pupil.count) / (Double.pi / 4 * pupil.bounds.width * pupil.bounds.height)))

                // ハイライト・小さな白点・四つ星（瞳の中心からの画面向きの位置、目の半径単位）
                let whites = components(width: bitmap.width, height: bitmap.height, region: box, minimumCount: 6) {
                    tones[$0, $1] == .white
                }
                for (rank, white) in whites.prefix(2).enumerated() {
                    let c = white.centroid
                    let diameter = 2 * sqrt(Double(white.count) / Double.pi)
                    print(String(format: "  \(side) %@ px c (%.1f, %.1f) d %.1f | from pupil center (%.3f, %.3f) r %.3f (eye-x radii) %@",
                                 rank == 0 ? "highlight" : "dot", c.x, c.y, diameter,
                                 (c.x - pupilCenter.x) / radius.width, (c.y - pupilCenter.y) / radius.height,
                                 diameter / 2 / radius.width, meanColor(white.pixels)))
                }
                let creams = components(width: bitmap.width, height: bitmap.height, region: box, minimumCount: 20) {
                    tones[$0, $1] == .cream
                }
                if let star = creams.first {
                    let c = CGPoint(x: star.bounds.midX, y: star.bounds.midY)
                    print(String(format: "  \(side) sparkle px c (%.1f, %.1f) size %.0fx%.0f | from pupil center (%.3f, %.3f) half-size (%.3f, %.3f) eye-x radii %@",
                                 c.x, c.y, star.bounds.width, star.bounds.height,
                                 (c.x - pupilCenter.x) / radius.width, (c.y - pupilCenter.y) / radius.height,
                                 star.bounds.width / 2 / radius.width, star.bounds.height / 2 / radius.width,
                                 meanColor(star.pixels)))
                }
            }

            // 虹彩の色ごとの平均と面積比
            var byTone: [ToneClass: [(Int, Int)]] = [:]
            for (x, y) in iris.pixels { byTone[tones[x, y], default: []].append((x, y)) }
            let summary = [ToneClass.brightIris, .cap, .deep, .litInner].map { tone -> String in
                let pixels = byTone[tone] ?? []
                return String(format: "%@ %@ %.1f%%", tone.rawValue, meanColor(pixels),
                              100 * Double(pixels.count) / Double(iris.count))
            }
            print("  \(side) iris tones: " + summary.joined(separator: ", "))

            // 行ごとの色の並び（局所座標）。形の当てはめに使う。
            for step in stride(from: -0.95, through: 0.951, by: 0.1) {
                let y = Int((center.y + CGFloat(step) * radius.height).rounded())
                var runs: [(ToneClass, Int, Int)] = []
                for x in Int(box.minX) - 2...Int(box.maxX) + 2 {
                    let tone = tones[x, y]
                    if let last = runs.last, last.0 == tone { runs[runs.count - 1].2 = x } else { runs.append((tone, x, x)) }
                }
                let ordered = inward > 0 ? runs : runs.reversed().map { ($0.0, $0.2, $0.1) }
                let text = ordered.filter { abs($0.2 - $0.1) >= 2 && $0.0 != .other && $0.0 != .black || $0.0 == .black && abs($0.2 - $0.1) >= 2 }
                    .map { run in
                        String(format: "%@[%+.2f,%+.2f]", run.0.rawValue,
                               local(CGPoint(x: CGFloat(run.1), y: CGFloat(y))).x,
                               local(CGPoint(x: CGFloat(run.2), y: CGFloat(y))).x)
                    }
                print(String(format: "  \(side) v=%+.2f ", step) + text.joined(separator: " "))
            }

            // 縁の光: 上半分の放射方向に、目の縁（最も外側の虹彩画素）から外へ d px の明るさ（R+G+B の平均）
            let offsets = [1, 2, 3, 4, 6, 8, 12, 16, 24]
            var sums = [Double](repeating: 0, count: offsets.count)
            var rays = 0
            for degrees in stride(from: 200.0, through: 340.0, by: 5.0) {
                let angle = degrees * Double.pi / 180
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                var edge: CGFloat = 0
                var t: CGFloat = 0
                while t < radius.width * 1.4 {
                    let x = Int(center.x + direction.x * t), y = Int(center.y + direction.y * t * radius.height / radius.width)
                    if tones[x, y].isIris { edge = t }
                    t += 0.5
                }
                rays += 1
                for (index, offset) in offsets.enumerated() {
                    let d = edge + CGFloat(offset)
                    let c = bitmap.rgb(Int(center.x + direction.x * d), Int(center.y + direction.y * d * radius.height / radius.width))
                    sums[index] += (c.r + c.g + c.b) / 3
                }
            }
            print("  \(side) glow profile (px beyond edge: mean RGB level) "
                  + zip(offsets, sums).map { String(format: "+%d:%.0f", $0, $1 / Double(rays)) }.joined(separator: " "))
        }

        // 鼻・口・ひげ（目の外のクリーム色）
        let features = faceFeatures(bitmap: bitmap, tones: tones, screen: screen, excluding: eyeBounds)
        if let nose = features.nose {
            describe("nose", nose.bounds)
            print("  nose color \(meanColor(nose.pixels))")
            let widths = stride(from: 0.1, through: 0.91, by: 0.2).map { f -> String in
                let y = Int(nose.bounds.minY + nose.bounds.height * f)
                let xs = nose.pixels.filter { $0.1 == y }.map(\.0)
                return String(format: "%.1f:%d", f, (xs.max() ?? 0) - (xs.min() ?? 0) + 1)
            }
            print("  nose width by height fraction px " + widths.joined(separator: " "))
        }
        if let mouth = features.mouth {
            describe("mouth", mouth.bounds)
            print("  mouth color \(meanColor(mouth.pixels))")
            print("  mouth columns (cv x: y ranges in cv) " + columnProfile(mouth, reference: reference, samples: 15))
        }
        for (name, whisker) in features.whiskers {
            describe(name, whisker.bounds)
            print("  centerline (cv x, cv y, thickness px) " + columnProfile(whisker, reference: reference, samples: 9))
        }
    }

    /// 鼻（珊瑚色の最大の成分）、口（中央の幅 ±10% にかかるクリーム色をまとめたもの。縦線の合流部で分かれることがある）、
    /// ひげ（残りのクリーム色。左→右、上→下の順に "left whisker 1" … と名付ける）。採用画像と sleeping の下書きで同じ計測。
    /// `excluding` は目（または閉じた目の弧）の外接で、2px 外側まで含めてクリーム色の候補から除く。
    private struct FaceFeatures {
        var nose: Component?
        var mouth: Component?
        var whiskers: [(name: String, component: Component)]
    }

    private static func faceFeatures(bitmap: Bitmap, tones: ToneMap, screen: CGRect, excluding boxes: [CGRect]) -> FaceFeatures {
        let corals = components(width: bitmap.width, height: bitmap.height, region: screen, minimumCount: 200) {
            tones[$0, $1] == .coral
        }
        let creams = components(width: bitmap.width, height: bitmap.height, region: screen, minimumCount: 150) { x, y in
            tones[x, y] == .cream && !boxes.contains { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: y)) }
        }
        let isMouth = { (c: Component) in abs(c.bounds.midX - screen.midX) < screen.width * 0.1 }
        var mouth = Component()
        creams.filter(isMouth).forEach { part in part.pixels.forEach { mouth.add($0.0, $0.1) } }
        let whiskers = creams.filter { !isMouth($0) }
            .sorted { ($0.bounds.midX < screen.midX ? 0 : 1, $0.bounds.minY) < ($1.bounds.midX < screen.midX ? 0 : 1, $1.bounds.minY) }
            .enumerated().map { index, whisker in
                (name: "\(whisker.bounds.midX < screen.midX ? "left" : "right") whisker \(index % 3 + 1)", component: whisker)
            }
        return FaceFeatures(nose: corals.first, mouth: mouth.count > 0 ? mouth : nil, whiskers: whiskers)
    }

    private static func describe(_ label: String, _ rect: CGRect, reference: ReferenceImage) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let s0 = reference.screenNormalized(rect.origin)
        let s1 = reference.screenNormalized(CGPoint(x: rect.maxX, y: rect.maxY))
        let v0 = reference.canvasNormalized(rect.origin)
        let v1 = reference.canvasNormalized(CGPoint(x: rect.maxX, y: rect.maxY))
        let sc = reference.screenNormalized(c)
        let vc = reference.canvasNormalized(c)
        print(String(format: "%@: px x %.0f..%.0f y %.0f..%.0f c (%.1f, %.1f) | scr x %.4f..%.4f y %.4f..%.4f c (%.4f, %.4f) | cv x %.4f..%.4f y %.4f..%.4f c (%.4f, %.4f) size (%.4f, %.4f)",
                     label, rect.minX, rect.maxX, rect.minY, rect.maxY, c.x, c.y,
                     s0.x, s1.x, s0.y, s1.y, sc.x, sc.y, v0.x, v1.x, v0.y, v1.y, vc.x, vc.y, v1.x - v0.x, v1.y - v0.y))
    }

    private static func meanColor(_ pixels: [(Int, Int)], bitmap: Bitmap) -> String {
        guard !pixels.isEmpty else { return "-" }
        var r = 0.0, g = 0.0, b = 0.0
        for (x, y) in pixels {
            let c = bitmap.rgb(x, y)
            r += c.r; g += c.g; b += c.b
        }
        let n = Double(pixels.count)
        return String(format: "#%02X%02X%02X", Int(r / n), Int(g / n), Int(b / n))
    }

    // MARK: sleeping（閉じた目の弧）

    /// sleeping の下書き（docs/design/sleeping-2026-10-26/sleeping-draft.png。16:9 の全面がキャンバス）と現在の描画
    /// （1280×720 のキャンバス）を同じ計測にかけ、最後に下書きを 1280×720 に縮めて色の分類ごとの IoU を出す。
    static func runSleeping(root: String) throws {
        let draft = try ReferenceImage(name: "sleeping-draft.png", path: "\(root)/\(sleepingDraftPath)")
        let draftProfile = reportSleeping(draft)
        let rendered = FaceRender.canvasImage(.sleeping, .closed)
        let renderedProfile = reportSleeping(ReferenceImage(name: "rendered sleeping (canvas 1280x720)", rendered: rendered))
        let draftArcs = draftProfile.arcs
        let renderedArcs = renderedProfile.arcs

        // 弧の縁の差（描画 − 下書き。局所 v 単位と 1280×720 の px）。先端の列（|u| = 1）は別に出す。
        print("== rendered - draft (closed lid edges; 1 local v = 0.2231 canvas height = 160.6 px @720 = 87.7 pt on 852x393)")
        for side in CatFaceSide.allCases {
            guard let d = draftArcs[side], let r = renderedArcs[side] else { continue }
            print("\(side): bounds diff px@1280x720 x \(String(format: "%+.1f/%+.1f", (r.bounds.minX - d.bounds.minX) * 1280, (r.bounds.maxX - d.bounds.maxX) * 1280))"
                  + " y \(String(format: "%+.1f/%+.1f", (r.bounds.minY - d.bounds.minY) * 720, (r.bounds.maxY - d.bounds.maxY) * 720))")
            print("  u      d.upper r.upper   dU    | d.lower r.lower   dL    | d.thick r.thick   dT")
            var worst = (upper: 0.0, lower: 0.0, thickness: 0.0)
            for u in d.rows.keys.sorted() {
                guard let a = d.rows[u], let b = r.rows[u] else { continue }
                let dU = b.upper - a.upper, dL = b.lower - a.lower
                let dT = (b.lower - b.upper) - (a.lower - a.upper)
                if abs(u) <= 0.95 {
                    worst = (max(worst.upper, abs(dU)), max(worst.lower, abs(dL)), max(worst.thickness, abs(dT)))
                }
                print(String(format: "  %+.2f   %6.3f  %6.3f  %+.3f  |  %6.3f  %6.3f  %+.3f  |  %6.3f  %6.3f  %+.3f",
                             u, a.upper, b.upper, dU, a.lower, b.lower, dL, a.lower - a.upper, b.lower - b.upper, dT))
            }
            print(String(format: "  max |diff| for |u| <= 0.95: upper %.3f lower %.3f thickness %.3f (local v) = %.1f / %.1f / %.1f px @720",
                         worst.upper, worst.lower, worst.thickness,
                         worst.upper * 0.2231 * 720, worst.lower * 0.2231 * 720, worst.thickness * 0.2231 * 720))
        }

        // 鼻・口・ひげの差（描画 − 下書き）: 外接の 4 辺（px @1280×720）と、同じ列（キャンバス幅 1/640 刻み）での中心 y の差。
        print("== rendered - draft (nose, mouth, whiskers; px @1280x720)")
        for name in draftProfile.features.keys.sorted() {
            guard let d = draftProfile.features[name], let r = renderedProfile.features[name] else { continue }
            let shared = Set(d.centerline.keys).intersection(r.centerline.keys).sorted()
            let deltas = shared.map { (r.centerline[$0]! - d.centerline[$0]!) * 720 }
            let mean = deltas.isEmpty ? 0 : deltas.reduce(0, +) / CGFloat(deltas.count)
            let maxAbs = deltas.map { abs($0) }.max() ?? 0
            print(String(format: "%@: bounds x %+.1f/%+.1f y %+.1f/%+.1f | centerline dy over %d shared columns: mean %+.2f max |dy| %.2f",
                         name, (r.bounds.minX - d.bounds.minX) * 1280, (r.bounds.maxX - d.bounds.maxX) * 1280,
                         (r.bounds.minY - d.bounds.minY) * 720, (r.bounds.maxY - d.bounds.maxY) * 720,
                         shared.count, mean, maxAbs))
        }
        let scaled = FaceRender.scaled(draft.bitmap.makeImage(), width: rendered.width, height: rendered.height)
        print("sleeping: color-class IoU draft(1280x720) vs rendered (Y arc, C cream, P nose): "
              + FaceRender.agreementSummary(reference: scaled, rendered: rendered))
    }

    struct ArcProfile {
        /// 弧の外接（キャンバス正規化座標）。
        var bounds = CGRect.zero
        /// 固定の局所 u（0.1 刻み）ごとの上縁・下縁（局所 v）。
        var rows: [CGFloat: (upper: CGFloat, lower: CGFloat)] = [:]
    }

    struct FeatureProfile {
        /// 外接（キャンバス正規化座標）。
        var bounds = CGRect.zero
        /// キャンバス幅を 640 に刻んだ列ごとの中心 y（キャンバス正規化座標）。画像の解像度が違っても同じ列で比べられる。
        var centerline: [Int: CGFloat] = [:]
    }

    struct SleepingProfile {
        var arcs: [CatFaceSide: ArcProfile] = [:]
        var features: [String: FeatureProfile] = [:]
    }

    /// 閉じた目の弧（虹彩の色の連結成分 2 つ）を列ごとに走査し、目の局所座標（sleeping の目の枠。neutral と同じ）で
    /// 上縁・下縁・太さを固定の u で出す。鼻・口・ひげは採用画像と同じ計測。戻り値は弧の縁（差分の計算用）。
    private static func reportSleeping(_ reference: ReferenceImage) -> SleepingProfile {
        let bitmap = reference.bitmap
        let screen = reference.screen
        let tones = ToneMap(bitmap: bitmap, region: screen)
        print("== \(reference.name) \(bitmap.width)x\(bitmap.height)")
        print(String(format: "canvas rect px x %.1f..%.1f y %.1f..%.1f", reference.canvasRect.minX, reference.canvasRect.maxX,
                     reference.canvasRect.minY, reference.canvasRect.maxY))
        let canvas = reference.canvasRect
        let appearance = CatFaceAppearance.preset(.sleeping)

        let arcs = components(width: bitmap.width, height: bitmap.height, region: screen, minimumCount: 200) {
            tones[$0, $1].isIris
        }.prefix(2).sorted { $0.minX < $1.minX }
        var result = SleepingProfile()
        func canvasBounds(_ rect: CGRect) -> CGRect {
            CGRect(origin: reference.canvasNormalized(rect.origin),
                   size: CGSize(width: rect.width / canvas.width, height: rect.height / canvas.height))
        }
        func featureProfile(_ component: Component) -> FeatureProfile {
            var sums: [Int: (CGFloat, Int)] = [:]
            for (x, y) in component.pixels {
                let point = reference.canvasNormalized(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                let bin = Int((point.x * 640).rounded(.down))
                let entry = sums[bin] ?? (0, 0)
                sums[bin] = (entry.0 + point.y, entry.1 + 1)
            }
            return FeatureProfile(bounds: canvasBounds(component.bounds),
                                  centerline: sums.mapValues { $0.0 / CGFloat($0.1) })
        }
        for (index, arc) in arcs.enumerated() {
            let side: CatFaceSide = index == 0 ? .left : .right
            let frame = CatFaceGeometry.eyeFrame(side: side, eye: appearance.eye(side))
            var profile = ArcProfile()
            profile.bounds = canvasBounds(arc.bounds)
            describe("\(side) closed lid", arc.bounds, reference: reference)
            func local(_ x: CGFloat, _ y: CGFloat) -> (u: CGFloat, v: CGFloat) {
                let n = reference.canvasNormalized(CGPoint(x: x, y: y))
                return (side.inwardSign * (n.x - frame.center.x) / frame.radii.width, (n.y - frame.center.y) / frame.radii.height)
            }
            let l0 = local(arc.bounds.minX, arc.bounds.minY)
            let l1 = local(arc.bounds.maxX, arc.bounds.maxY)
            // 色: 縁の画素を除いた内側（上下左右が同じ分類）、縁から 2px 以上内側（周囲 5×5 が同じ分類。平均と各チャネルの中央値）、全画素。
            let interior = arc.pixels.filter { x, y in
                [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].allSatisfy { tones[$0.0, $0.1].isIris }
            }
            let core = arc.pixels.filter { x, y in
                (-2...2).allSatisfy { dx in (-2...2).allSatisfy { dy in tones[x + dx, y + dy].isIris } }
            }
            func median(_ channel: Int) -> Int {
                let values = core.map { x, y in Int(bitmap.pixels[(y * bitmap.width + x) * 4 + channel]) }.sorted()
                return values.isEmpty ? 0 : values[values.count / 2]
            }
            print(String(format: "  local u %.3f..%.3f v %.3f..%.3f | color interior %@ (n=%d) core mean %@ median #%02X%02X%02X (n=%d) all %@ (n=%d)",
                         min(l0.u, l1.u), max(l0.u, l1.u), l0.v, l1.v,
                         meanColor(interior, bitmap: bitmap), interior.count, meanColor(core, bitmap: bitmap),
                         median(0), median(1), median(2), core.count, meanColor(arc.pixels, bitmap: bitmap), arc.count))
            var columns: [Int: (top: Int, bottom: Int)] = [:]
            for (x, y) in arc.pixels {
                var entry = columns[x] ?? (top: y, bottom: y)
                entry.top = min(entry.top, y)
                entry.bottom = max(entry.bottom, y)
                columns[x] = entry
            }
            let xs = columns.keys.sorted()
            for (label, x) in [("outer tip", xs.first!), ("inner tip", xs.last!)] {
                let entry = columns[x]!
                let tipX = side == .left ? (label == "outer tip" ? x : x + 1) : (label == "outer tip" ? x + 1 : x)
                let l = local(CGFloat(tipX), CGFloat(entry.top + entry.bottom + 1) / 2)
                print(String(format: "  %@ local (%.3f, %.3f) thickness px %d", label, l.u, l.v, entry.bottom - entry.top + 1))
            }
            // 最下点・最上点（同じ行に並ぶ列は u の平均で表す）。
            let lowestY = columns.values.map(\.bottom).max()!
            let highestY = columns.values.map(\.top).min()!
            func meanX(_ xs: [Int]) -> CGFloat { CGFloat(xs.reduce(0, +)) / CGFloat(xs.count) + 0.5 }
            let low = local(meanX(columns.filter { $0.value.bottom == lowestY }.map(\.key)), CGFloat(lowestY) + 1)
            let high = local(meanX(columns.filter { $0.value.top == highestY }.map(\.key)), CGFloat(highestY))
            print(String(format: "  lowest edge local (%.3f, %.3f) cv y %.4f | highest edge local (%.3f, %.3f) cv y %.4f",
                         low.u, low.v, reference.canvasNormalized(CGPoint(x: 0, y: CGFloat(lowestY) + 1)).y,
                         high.u, high.v, reference.canvasNormalized(CGPoint(x: 0, y: CGFloat(highestY))).y))
            print("  u      upper v  lower v  center v  thick(v)  | cv x    cv y_c   thick(cv)")
            for step in -10...10 {
                let u = CGFloat(step) / 10
                let nx = frame.center.x + side.inwardSign * u * frame.radii.width
                let x = Int((canvas.minX + nx * canvas.width).rounded(.down))
                guard let entry = columns[x] else {
                    print(String(format: "  %+.2f   -", u))
                    continue
                }
                let top = reference.canvasNormalized(CGPoint(x: 0, y: CGFloat(entry.top))).y
                let bottom = reference.canvasNormalized(CGPoint(x: 0, y: CGFloat(entry.bottom + 1))).y
                let upper = (top - frame.center.y) / frame.radii.height
                let lower = (bottom - frame.center.y) / frame.radii.height
                profile.rows[u] = (upper, lower)
                print(String(format: "  %+.2f   %6.3f   %6.3f   %6.3f    %6.3f   | %.4f  %.4f  %.4f",
                             u, upper, lower, (upper + lower) / 2, lower - upper, nx, (top + bottom) / 2, bottom - top))
            }
            result.arcs[side] = profile
        }

        let features = faceFeatures(bitmap: bitmap, tones: tones, screen: screen, excluding: arcs.map(\.bounds))
        if let nose = features.nose {
            describe("nose", nose.bounds, reference: reference)
            print("  nose color \(meanColor(nose.pixels, bitmap: bitmap))")
            result.features["nose"] = featureProfile(nose)
        }
        if let mouth = features.mouth {
            describe("mouth", mouth.bounds, reference: reference)
            print("  mouth color \(meanColor(mouth.pixels, bitmap: bitmap))")
            print("  mouth columns (cv x: y ranges in cv) " + columnProfile(mouth, reference: reference, samples: 15))
            result.features["mouth"] = featureProfile(mouth)
        }
        for (name, whisker) in features.whiskers {
            describe(name, whisker.bounds, reference: reference)
            print("  centerline (cv x, cv y, thickness px) " + columnProfile(whisker, reference: reference, samples: 9))
            result.features[name] = featureProfile(whisker)
        }
        return result
    }

    /// 外接の外周から `passable` な画素でたどり着けない、内側の `passable` な画素。
    private static func enclosedPixels(in box: CGRect, tones: ToneMap, passable: (ToneClass) -> Bool) -> [(Int, Int)] {
        let x0 = Int(box.minX) - 1, x1 = Int(box.maxX) + 1
        let y0 = Int(box.minY) - 1, y1 = Int(box.maxY) + 1
        let w = x1 - x0 + 1
        var reached = [Bool](repeating: false, count: w * (y1 - y0 + 1))
        var stack: [(Int, Int)] = []
        for x in x0...x1 { stack += [(x, y0), (x, y1)] }
        for y in y0...y1 { stack += [(x0, y), (x1, y)] }
        while let (x, y) = stack.popLast() {
            guard x >= x0, x <= x1, y >= y0, y <= y1 else { continue }
            let index = (y - y0) * w + (x - x0)
            guard !reached[index], passable(tones[x, y]) || x == x0 || x == x1 || y == y0 || y == y1 else { continue }
            reached[index] = true
            stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        }
        var result: [(Int, Int)] = []
        for y in y0...y1 {
            for x in x0...x1 where !reached[(y - y0) * w + (x - x0)] && passable(tones[x, y]) {
                result.append((x, y))
            }
        }
        return result
    }

    /// 列ごとの中心と太さ（縦方向の画素数）を、等間隔の列で出す。
    private static func columnProfile(_ component: Component, reference: ReferenceImage, samples: Int) -> String {
        var columns: [Int: [Int]] = [:]
        for (x, y) in component.pixels { columns[x, default: []].append(y) }
        let xs = columns.keys.sorted()
        guard let first = xs.first, let last = xs.last else { return "" }
        return (0..<samples).map { i -> String in
            let x = first + Int(Double(last - first) * Double(i) / Double(samples - 1))
            let ys = columns[x] ?? columns[xs.min { abs($0 - x) < abs($1 - x) }!]!
            let c = reference.canvasNormalized(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(ys.reduce(0, +)) / CGFloat(ys.count) + 0.5))
            let top = reference.canvasNormalized(CGPoint(x: 0, y: CGFloat(ys.min()!))).y
            let bottom = reference.canvasNormalized(CGPoint(x: 0, y: CGFloat(ys.max()! + 1))).y
            return String(format: "(%.4f, %.4f, %d | %.4f..%.4f)", c.x, c.y, ys.count, top, bottom)
        }.joined(separator: " ")
    }
}
