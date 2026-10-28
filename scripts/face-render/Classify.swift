import CoreGraphics
import Foundation

/// 顔の画素の色分類。採用画像の 4 色の虹彩（実測の平均色）と、白・クリーム・コーラル・黒。
enum ToneClass: String, CaseIterable {
    case black = "K"
    case brightIris = "Y"   // 明るい黄
    case litInner = "O"     // 内側の層の明るいオレンジ
    case cap = "M"          // 上の陰（中間の琥珀）
    case deep = "D"         // 濃い琥珀
    case white = "W"        // ハイライト
    case cream = "C"        // 口・ひげ・四つ星
    case coral = "P"        // 鼻
    case other = "."

    static let prototypes: [(ToneClass, Double, Double, Double)] = [
        (.black, 8, 6, 4), (.brightIris, 253, 205, 63), (.litInner, 241, 152, 35), (.cap, 218, 138, 25),
        (.deep, 193, 108, 17), (.white, 252, 251, 249), (.cream, 249, 234, 204), (.coral, 252, 138, 106),
    ]

    /// 最も近い代表色。どれからも遠い（縁のにじみ等）なら .other。
    static func classify(_ r: Double, _ g: Double, _ b: Double) -> ToneClass {
        var best = ToneClass.other
        var bestDistance = Double.infinity
        for (tone, pr, pg, pb) in prototypes {
            let distance = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
            if distance < bestDistance {
                bestDistance = distance
                best = tone
            }
        }
        return bestDistance > 2_500 ? .other : best
    }

    var isIris: Bool { [.brightIris, .litInner, .cap, .deep].contains(self) }
}

/// 画素ごとの分類結果。
struct ToneMap {
    let width: Int
    let height: Int
    var tones: [ToneClass]

    init(bitmap: Bitmap, region: CGRect? = nil) {
        width = bitmap.width
        height = bitmap.height
        tones = [ToneClass](repeating: .black, count: width * height)
        let area = (region ?? CGRect(x: 0, y: 0, width: width, height: height)).integral
        for y in max(0, Int(area.minY))..<min(height, Int(area.maxY)) {
            for x in max(0, Int(area.minX))..<min(width, Int(area.maxX)) {
                let c = bitmap.rgb(x, y)
                tones[y * width + x] = ToneClass.classify(c.r, c.g, c.b)
            }
        }
    }

    subscript(x: Int, y: Int) -> ToneClass { tones[y * width + x] }
}

/// 連結成分（8 近傍）。
struct Component {
    var pixels: [(Int, Int)] = []
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

    var count: Int { pixels.count }
    var bounds: CGRect { CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) }
    var centroid: CGPoint {
        let sx = pixels.reduce(0) { $0 + Double($1.0) }
        let sy = pixels.reduce(0) { $0 + Double($1.1) }
        return CGPoint(x: sx / Double(count) + 0.5, y: sy / Double(count) + 0.5)
    }

    mutating func add(_ x: Int, _ y: Int) {
        pixels.append((x, y))
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}

func components(width: Int, height: Int, region: CGRect, minimumCount: Int = 1,
                where include: (Int, Int) -> Bool) -> [Component] {
    let area = region.integral
    let x0 = max(0, Int(area.minX)), x1 = min(width, Int(area.maxX))
    let y0 = max(0, Int(area.minY)), y1 = min(height, Int(area.maxY))
    var visited = [Bool](repeating: false, count: width * height)
    var result: [Component] = []
    for y in y0..<y1 {
        for x in x0..<x1 where !visited[y * width + x] && include(x, y) {
            var component = Component()
            var stack = [(x, y)]
            visited[y * width + x] = true
            while let (cx, cy) = stack.popLast() {
                component.add(cx, cy)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= x0, nx < x1, ny >= y0, ny < y1, !visited[ny * width + nx], include(nx, ny) else { continue }
                        visited[ny * width + nx] = true
                        stack.append((nx, ny))
                    }
                }
            }
            if component.count >= minimumCount { result.append(component) }
        }
    }
    return result.sorted { $0.count > $1.count }
}

/// 参照と描画を同じ大きさの画像として色分類し、分類ごとの IoU を返す。
func toneAgreement(reference: CGImage, rendered: CGImage) -> [(ToneClass, Double)] {
    let a = ToneMap(bitmap: Bitmap(image: reference))
    let b = ToneMap(bitmap: Bitmap(image: rendered))
    return ToneClass.allCases.filter { $0 != .black && $0 != .other }.map { tone in
        var intersection = 0
        var union = 0
        for index in a.tones.indices {
            let inA = a.tones[index] == tone
            let inB = b.tones[index] == tone
            if inA && inB { intersection += 1 }
            if inA || inB { union += 1 }
        }
        return (tone, union == 0 ? 1 : Double(intersection) / Double(union))
    }
}
