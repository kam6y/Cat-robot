import CoreGraphics
import Foundation
import SwiftUI

/// `render --round N` の出力を作る。
@MainActor
enum FaceRender {
    static let canvasPoints = CGSize(width: 640, height: 360)     // ×2 = 1280×720
    static let screenPoints = ReferenceImage.deviceScreen         // ×2 = 1704×786
    static let heldMouthExpressions: [FaceExpression] = [.happy, .sorry, .sleepy, .speaking]

    /// レビューに渡した round は固定する。既にファイルがある round へは `--overwrite` なしでは書かない。
    static func run(round: Int, root: String, overwrite: Bool) throws -> [String] {
        let directory = try roundDirectory(under: "\(root)/docs/design/face-expression-2026-10-26",
                                           round: round, overwrite: overwrite)
        return try run(directory: directory, root: root, screenScale: 2)
    }

    /// sleeping の round: 下書き sleeping-draft.png との比較画像を docs/design/sleeping-2026-10-26/renders/round-N/ へ出す。
    static func runSleeping(round: Int, root: String, overwrite: Bool) throws -> [String] {
        let directory = try roundDirectory(under: "\(root)/\(Measurement.sleepingDirectory)", round: round, overwrite: overwrite)
        let output = ImageWriter(directory: directory)
        let canvas = canvasImage(.sleeping, .closed)
        try output.save(canvas, "canvas-sleeping-closed.png")
        try output.save(canvasImage(.sleepy, .closed), "canvas-sleepy-closed.png")
        try output.save(screenImage(.sleeping, .closed), "screen-sleeping.png")
        try output.save(screenImage(.sleeping, .closed, scale: 3), "screen3x-sleeping.png")

        // 下書きは 16:9 の全面がキャンバス。1280×720 に縮めて上下に並べ、50% で重ね、画素差の絶対値も出す。
        let draft = try Bitmap(contentsOf: "\(root)/\(Measurement.sleepingDraftPath)")
        let width = canvas.width
        let height = canvas.height
        let scaledDraft = scaled(draft.makeImage(), width: width, height: height)
        try output.save(scaledDraft, "draft-1280x720.png")
        try saveComparison(reference: scaledDraft, rendered: canvas, suffix: "sleeping", to: output)
        try output.save(diffImage(scaledDraft, canvas), "diff-sleeping.png")
        print("render: sleeping color-class IoU draft(1280x720) vs rendered (Y arc, C cream, P nose): "
              + agreementSummary(reference: scaledDraft, rendered: canvas))

        try output.save(render(GalleryView(), size: GalleryView.size, scale: 2), "gallery.png")
        return output.written
    }

    /// あくびの参考（docs/design/idle-cat-life-2026-10-30/yawn-reference.png。16:9 の全面がキャンバス）。
    static let yawnReferencePath = "docs/design/idle-cat-life-2026-10-30/yawn-reference.png"

    /// あくび（`CatFaceAppearance.yawning`）の試し描き: 峰のキャンバス 1280×720 と画面モック、yawn 0.25/0.5/0.75（目は閉じたまま）、
    /// neutral から峰への補間（AnimationVector の線形補間）の途中、参考を 1280×720 に縮めたもの、上下比較・50% 重ね・画素差。
    static func runYawn(directory: String, root: String) throws -> [String] {
        let output = ImageWriter(directory: directory)
        let peak = canvasImage(appearance: .yawning)
        try output.save(peak, "canvas-yawning-closed.png")
        try output.save(screenImage(appearance: .yawning), "screen-yawning.png")
        for amount in [0.25, 0.5, 0.75] {
            var partial = CatFaceAppearance.yawning
            partial.yawn = amount
            try output.save(canvasImage(appearance: partial), "canvas-yawning-\(Int(amount * 100)).png")
            try output.save(canvasImage(appearance: CatFaceAppearance.neutral.interpolated(toward: .yawning, fraction: amount)),
                            "canvas-yawn-from-neutral-\(Int(amount * 100)).png")
        }
        // 片目ずつのまばたき（Eye.blink）の見え方: 閉じきる直前から sleeping と同じ金色の弧が出る。
        for amount in [0.5, 0.8, 0.9, 1.0] {
            var blinking = CatFaceAppearance.neutral
            blinking.leftEye.blink = amount
            blinking.rightEye.blink = amount
            try output.save(canvasImage(appearance: blinking), "canvas-blink-neutral-\(Int(amount * 100)).png")
        }

        let reference = try Bitmap(contentsOf: "\(root)/\(yawnReferencePath)")
        let scaledReference = scaled(reference.makeImage(), width: peak.width, height: peak.height)
        try output.save(scaledReference, "yawn-reference-1280x720.png")
        try saveComparison(reference: scaledReference, rendered: peak, suffix: "yawning", to: output)
        try output.save(diffImage(scaledReference, peak), "diff-yawning.png")
        print("yawn: color-class IoU reference(1280x720) vs rendered (Y gold arcs, C cream outline/fangs/whiskers, P nose and tongue, I mouth inside): "
              + agreementSummary(reference: scaledReference, rendered: peak))
        return output.written
    }

    /// 画素差の絶対値を 2 倍にした画像（同じ大きさの二つの画像）。
    static func diffImage(_ first: CGImage, _ second: CGImage) -> CGImage {
        let a = Bitmap(image: first)
        let b = Bitmap(image: second)
        var diff = Bitmap(width: first.width, height: first.height)
        for index in stride(from: 0, to: diff.pixels.count, by: 4) {
            for channel in 0..<3 {
                diff.pixels[index + channel] = UInt8(min(255, abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])) * 2))
            }
            diff.pixels[index + 3] = 255
        }
        return diff.makeImage()
    }

    /// 試し描き用。round ではない任意のディレクトリ（作業用の場所）へ同じ画像を出す。screenScale は画面モックの倍率。
    static func preview(directory: String, root: String, screenScale: CGFloat) throws -> [String] {
        try run(directory: directory, root: root, screenScale: screenScale)
    }

    private static func run(directory: String, root: String, screenScale: CGFloat) throws -> [String] {
        let output = ImageWriter(directory: directory)

        // (a) キャンバス単体 1280×720
        for expression in FaceExpression.allCases {
            try output.save(canvasImage(expression, .closed), "canvas-\(expression.rawValue)-closed.png")
        }
        for expression in heldMouthExpressions {
            for pose in CatFaceGeometry.mouthPoses where pose != .closed {
                try output.save(canvasImage(expression, pose), "canvas-\(expression.rawValue)-\(pose).png")
            }
        }

        // (b) 画面モック 1704×786
        var screens: [FaceExpression: CGImage] = [:]
        for expression in FaceExpression.allCases {
            let image = screenImage(expression, .closed, scale: screenScale)
            screens[expression] = image
            try output.save(image, "screen-\(expression.rawValue).png")
        }

        // (b′) 3 倍の画面モック 2556×1179（iOS Simulator キャプチャと同じ倍率で細い帯を確かめる）
        for expression in [FaceExpression.neutral, .happy] {
            try output.save(screenImage(expression, .closed, scale: 3), "screen3x-\(expression.rawValue).png")
        }

        // (c) 採用画像との比較と 50% 重ね
        let references = "\(root)/docs/design/face-expression-2026-10-26"
        for (name, expression) in [("neutral", FaceExpression.neutral), ("happy", .happy)] {
            let reference = try ReferenceImage(name: name, path: "\(references)/\(name)-b.png")
            let referenceScreen = reference.bitmap.cropped(to: reference.deviceRect)
            let mock = screens[expression]!
            try saveComparison(reference: referenceScreen, rendered: mock, suffix: name, to: output)
            let scaledReference = scaled(referenceScreen, width: mock.width, height: mock.height)
            print("render: \(name) color-class IoU vs reference (Y bright, O lit inner, M cap, D deep, W highlight, C cream, P nose): "
                  + agreementSummary(reference: scaledReference, rendered: mock))
        }

        // (d) 全表情の一覧（3 列）
        try output.save(render(GalleryView(), size: GalleryView.size, scale: 2), "gallery.png")
        return output.written
    }

    /// `design/renders/round-N/`。レビューに渡した round は固定する: 既にファイルがある round へは `--overwrite` なしでは書かない。
    private static func roundDirectory(under design: String, round: Int, overwrite: Bool) throws -> String {
        let directory = "\(design)/renders/round-\(round)"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        if !existing.isEmpty && !overwrite {
            throw HarnessError("round-\(round) already has \(existing.count) files; use the next round number "
                               + "(or --overwrite only for a round that has not been handed to review)")
        }
        return directory
    }

    /// 参照（上）と描画（下）を灰色の線で区切って縦に並べた `compare-<suffix>.png` と、50% で重ねた `overlay-<suffix>.png`。
    /// 参照は描画と同じ大きさに縮めて置く。
    private static func saveComparison(reference: CGImage, rendered: CGImage, suffix: String, to output: ImageWriter) throws {
        let width = rendered.width
        let height = rendered.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        try output.save(compose(width: width, height: height * 2) { context in
            drawImage(reference, in: full, context: context)
            drawImage(rendered, in: CGRect(x: 0, y: height, width: width, height: height), context: context)
            context.setFillColor(CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 1, width: width, height: 2))
        }, "compare-\(suffix).png")
        try output.save(compose(width: width, height: height) { context in
            drawImage(reference, in: full, context: context)
            drawImage(rendered, in: full, context: context, alpha: 0.5)
        }, "overlay-\(suffix).png")
    }

    /// 画像を width×height に縮めた（または広げた）コピー。色分類の IoU は同じ大きさの画像どうしで取る。
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        compose(width: width, height: height) { context in
            drawImage(image, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        }
    }

    /// 色分類ごとの IoU を "Y 0.968, C 0.873, …" の形にする。
    static func agreementSummary(reference: CGImage, rendered: CGImage) -> String {
        toneAgreement(reference: reference, rendered: rendered)
            .map { String(format: "%@ %.3f", $0.0.rawValue, $0.1) }.joined(separator: ", ")
    }

    /// 1 つの出力先ディレクトリへ PNG を書き、書いたパスを順に覚える。
    private final class ImageWriter {
        let directory: String
        private(set) var written: [String] = []
        init(directory: String) { self.directory = directory }
        func save(_ image: CGImage, _ name: String) throws {
            let path = "\(directory)/\(name)"
            try writePNG(image, to: path)
            written.append(path)
        }
    }

    static func canvasImage(_ expression: FaceExpression, _ pose: MouthPose) -> CGImage {
        render(FaceOnBlack(expression: expression, mouthPose: pose), size: canvasPoints, scale: 2)
    }

    static func canvasImage(appearance: CatFaceAppearance) -> CGImage {
        render(FaceOnBlack(appearance: appearance, mouthPose: .closed), size: canvasPoints, scale: 2)
    }

    static func screenImage(_ expression: FaceExpression, _ pose: MouthPose, scale: CGFloat = 2) -> CGImage {
        render(FaceOnBlack(expression: expression, mouthPose: pose), size: screenPoints, scale: scale)
    }

    static func screenImage(appearance: CatFaceAppearance, scale: CGFloat = 2) -> CGImage {
        render(FaceOnBlack(appearance: appearance, mouthPose: .closed), size: screenPoints, scale: scale)
    }

    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat) -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else { fatalError("ImageRenderer failed") }
        return image
    }
}

/// 純黒の上に 16:9 キャンバスを高さ基準で等比・中央に置く（実機と同じ配置）。
/// プリセット以外の姿（あくびの峰など）は CatFaceView の appearanceOverride で渡す（CatFaceCanvas を直接置くと
/// 配置は同じでも curious の 410 画素が ±1 だけ変わったので、製品と同じ CatFaceView を通す）。
private struct FaceOnBlack: View {
    var expression: FaceExpression = .neutral
    var appearance: CatFaceAppearance? = nil
    let mouthPose: MouthPose

    var body: some View {
        ZStack {
            Color.black
            CatFaceView(expression: expression, mouthPose: mouthPose, reduceMotion: true, appearanceOverride: appearance)
        }
    }
}

private struct GalleryView: View {
    static let cell = CGSize(width: 426, height: 196.5)
    static let gap: CGFloat = 4
    static let rowCount = (FaceExpression.allCases.count + 2) / 3
    static let size = CGSize(width: cell.width * 3 + gap * 4, height: cell.height * CGFloat(rowCount) + gap * CGFloat(rowCount + 1))

    var body: some View {
        let rows = stride(from: 0, to: FaceExpression.allCases.count, by: 3).map {
            Array(FaceExpression.allCases[$0..<min($0 + 3, FaceExpression.allCases.count)])
        }
        VStack(spacing: Self.gap) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(rows[row], id: \.self) { expression in
                        ZStack(alignment: .topLeading) {
                            FaceOnBlack(expression: expression, mouthPose: .closed)
                            Text(expression.rawValue)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(white: 0.55))
                                .padding(6)
                        }
                        .frame(width: Self.cell.width, height: Self.cell.height)
                    }
                }
            }
        }
        .padding(Self.gap)
        .background(Color(white: 0.25))
    }
}
