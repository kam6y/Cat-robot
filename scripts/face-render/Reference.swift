import CoreGraphics
import Foundation

/// 採用画像（neutral-b / happy-b）と、その中の画面矩形・顔キャンバスへの対応。
///
/// 対応の決め方（visual-comparison.md に同じ式を記録）:
/// - 画面矩形 = 画像中央付近の黒い矩形の外接（ベゼルの黒を含む）。
/// - 実機の画面 852×393 へは「高さ基準の等比」で写す。参照の画面は約 2.4:1 で実機 (2.17:1) より横長なので、
///   左右の黒い余白（カメラ島を含む）を中央基準で切り落とす。目や曲線の形は歪めない。
/// - 16:9 キャンバスは実機画面の高さいっぱい・中央寄せなので、参照画像では
///   幅 = 画面高さ × 16/9、中心 = 画面矩形の中心 の矩形になる。
struct ReferenceImage {
    let name: String
    let bitmap: Bitmap
    let screen: CGRect

    init(name: String, path: String) throws {
        self.name = name
        bitmap = try Bitmap(contentsOf: path)
        screen = try detectScreen(in: bitmap)
    }

    /// ハーネスが描いた画面モック（画像全体が画面）。採用画像と同じ計測にかけるために使う。
    init(name: String, rendered image: CGImage) {
        self.name = name
        bitmap = Bitmap(image: image)
        screen = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    static let deviceScreen = CGSize(width: 852, height: 393)

    /// 実機の画面 852×393 に当たる参照画像の矩形。
    var deviceRect: CGRect {
        let width = screen.height * Self.deviceScreen.width / Self.deviceScreen.height
        return CGRect(x: screen.midX - width / 2, y: screen.minY, width: width, height: screen.height)
    }

    /// 顔の 16:9 キャンバスに当たる参照画像の矩形。
    var canvasRect: CGRect {
        let width = screen.height * 16 / 9
        return CGRect(x: screen.midX - width / 2, y: screen.minY, width: width, height: screen.height)
    }

    func screenNormalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - screen.minX) / screen.width, y: (point.y - screen.minY) / screen.height)
    }

    func canvasNormalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - canvasRect.minX) / canvasRect.width, y: (point.y - canvasRect.minY) / canvasRect.height)
    }
}

/// 黒い画面矩形の外接を、角の丸みを避けた中央の行・列から外側→内側へ走査して求める。
func detectScreen(in bitmap: Bitmap) throws -> CGRect {
    func isBlack(_ x: Int, _ y: Int) -> Bool {
        let c = bitmap.rgb(x, y)
        return max(c.r, c.g, c.b) < 30
    }
    let run = 12
    func blackRun(_ points: (Int) -> (Int, Int)) -> Bool {
        (0..<run).allSatisfy { offset in
            let (x, y) = points(offset)
            return x >= 0 && y >= 0 && x < bitmap.width && y < bitmap.height && isBlack(x, y)
        }
    }
    func median(_ values: [Int]) throws -> Int {
        guard !values.isEmpty else { throw HarnessError("画面矩形を検出できません") }
        return values.sorted()[values.count / 2]
    }

    let rows = stride(from: bitmap.height * 45 / 100, to: bitmap.height * 55 / 100, by: 4)
    var lefts: [Int] = []
    var rights: [Int] = []
    for y in rows {
        if let x = (0..<bitmap.width / 2).first(where: { x in blackRun { (x + $0, y) } }) { lefts.append(x) }
        if let x = stride(from: bitmap.width - 1, to: bitmap.width / 2, by: -1)
            .first(where: { x in blackRun { (x - $0, y) } }) { rights.append(x) }
    }
    let columns = [20, 22, 25, 75, 78, 80].map { bitmap.width * $0 / 100 }
    var tops: [Int] = []
    var bottoms: [Int] = []
    for x in columns {
        if let y = (0..<bitmap.height / 2).first(where: { y in blackRun { (x, y + $0) } }) { tops.append(y) }
        if let y = stride(from: bitmap.height - 1, to: bitmap.height / 2, by: -1)
            .first(where: { y in blackRun { (x, y - $0) } }) { bottoms.append(y) }
    }
    let left = try median(lefts)
    let right = try median(rights)
    let top = try median(tops)
    let bottom = try median(bottoms)
    return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
}
