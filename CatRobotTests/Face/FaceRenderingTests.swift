import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

/// 顔の静止画を XCTest 添付として残す。見た目の合否は採用画像との目視比較で判断し、
/// 顔の描画・中央位置・黒背景と、眠りの Z が sleeping だけに出ることを確認する。
@MainActor
final class FaceRenderingTests: XCTestCase {
    func testEveryExpressionRendersOnBlackScreen() async throws {
        for expression in FaceExpression.allCases {
            try await capture(expression: expression, mouthPose: .closed)
        }
    }

    func testHeldExpressionsKeepEverySpeakingMouth() async throws {
        for expression in [FaceExpression.happy, .sorry, .sleepy] {
            for pose in CatFaceGeometry.mouthPoses {
                try await capture(expression: expression, mouthPose: pose)
            }
        }
    }

    func testSleepyBlinkNeverLosesEitherEyeBeforeTheClosedLidAppears() throws {
        // Sample the real renderer, including its lid mask and closed-eye opacity.
        // This catches a blank eye between the disappearing iris and the closed arc.
        for step in 0...20 {
            var appearance = CatFaceAppearance.sleepy
            appearance.leftEye.blink = CGFloat(step) / 20
            appearance.rightEye.blink = CGFloat(step) / 20
            let renderer = ImageRenderer(content: ZStack {
                Color.black
                CatFaceView(expression: .sleepy, mouthPose: .closed, reduceMotion: true, appearanceOverride: appearance)
            }.frame(width: 640, height: 360))
            renderer.proposedSize = ProposedViewSize(width: 640, height: 360)
            let image = try XCTUnwrap(renderer.cgImage)
            let (pixels, width, height) = try XCTUnwrap(rgbaPixels(of: UIImage(cgImage: image)))
            for side in CatFaceSide.allCases {
                let bounds = CatFaceGeometry.eye(side: side, appearance: appearance).outline.bounds
                var goldPixels = 0
                for y in Int(bounds.minY * CGFloat(height))...Int(bounds.maxY * CGFloat(height)) {
                    for x in Int(bounds.minX * CGFloat(width))...Int(bounds.maxX * CGFloat(width)) {
                        let i = (y * width + x) * 4
                        if pixels[i] > 80, pixels[i + 1] > 50, pixels[i + 2] < 100 { goldPixels += 1 }
                    }
                }
                XCTAssertGreaterThan(goldPixels, 100, "\(side), blink \(step)/20: eye disappears")
            }
        }
    }

    private func capture(expression: FaceExpression, mouthPose: MouthPose) async throws {
        // Mac のモック（scripts/face-render）と同じく、852×393 の矩形全体に 16:9 のキャンバスを高さ基準で置く。
        // Simulator の実画面（例: iPhone 18 Pro の横向き 874×402）の原点に 852×393 の窓を置くと、窓の安全領域は
        // 画面の安全領域との重なりになり、左右・下が非対称になる（左 62・右 40・下 12 前後）。すると顔は高さ 381 に
        // 縮み（97%）、中心が右へ 11pt・上へ 6pt ずれる。顔の描画を製品の安全領域から切り離して確かめるため、
        // この試験の土台では安全領域を無視し、「指定した矩形 = 顔を置く矩形 = キャプチャする矩形」にそろえる。
        let face = ZStack {
            Color.black
            CatFaceView(expression: expression, mouthPose: mouthPose, reduceMotion: true)
        }
        .ignoresSafeArea()
        let host = UIHostingController(rootView: face)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.backgroundColor = .black
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        let captureBounds = host.view.bounds
        let renderer = UIGraphicsImageRenderer(bounds: captureBounds)
        let image = renderer.image { _ in host.view.drawHierarchy(in: captureBounds, afterScreenUpdates: true) }
        let geometry = fixtureGeometry(window: window, host: host, captureBounds: captureBounds, image: image)
        window.isHidden = true

        let attachment = XCTAttachment(image: image)
        attachment.name = "face-\(expression.rawValue)-\(mouthPose)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let geometryAttachment = XCTAttachment(string: geometry)
        geometryAttachment.name = "face-\(expression.rawValue)-\(mouthPose)-geometry"
        geometryAttachment.lifetime = .keepAlways
        add(geometryAttachment)

        XCTAssertEqual(captureBounds.size, CGSize(width: 852, height: 393), geometry)
        let metrics = try XCTUnwrap(pixelMetrics(of: image))
        let visible = metrics.nonBlackFraction
        XCTAssertGreaterThan(visible, 0.02, "\(expression) \(mouthPose): the face is missing")
        XCTAssertLessThan(visible, 0.40, "\(expression) \(mouthPose): the screen should stay mostly black")
        // 鼻はキャンバスの中心 x = 0.5 にある。顔が矩形の左右中央に置かれていること（Mac のモックと同じ）。
        let noseCenter = try XCTUnwrap(metrics.noseCenterX, "\(expression) \(mouthPose): the nose is missing")
        XCTAssertEqual(noseCenter, 0.5, accuracy: 0.005, "\(expression) \(mouthPose): face is off center\n\(geometry)")
        // 眠りの Z（青）は sleeping だけに出て、目のまぶたの黒に隠れない。
        let sleepMarks = metrics.sleepMarkFraction
        if expression == .sleeping {
            XCTAssertGreaterThan(sleepMarks, 0.004, "sleeping \(mouthPose): the Zs are missing")
        } else {
            XCTAssertEqual(sleepMarks, 0, "\(expression) \(mouthPose): only sleeping shows the Zs")
        }
    }

    /// 窓・画面・ホストの寸法と安全領域、キャプチャの矩形を記録する（Mac のモックとの食い違いの調査用）。
    private func fixtureGeometry(window: UIWindow, host: UIViewController, captureBounds: CGRect, image: UIImage) -> String {
        let screen = window.windowScene?.screen ?? window.screen
        return [
            "window.frame \(window.frame) scene \(window.windowScene == nil ? "none" : "attached")",
            "screen.bounds \(screen.bounds) scale \(screen.scale)",
            "window.safeAreaInsets \(window.safeAreaInsets)",
            "host.view.frame \(host.view.frame) bounds \(host.view.bounds)",
            "host.view.safeAreaInsets \(host.view.safeAreaInsets)",
            "capture bounds \(captureBounds) image \(image.size) x\(image.scale)",
        ].joined(separator: "\n")
    }

    /// 1 回のデコードと全画素の走査で、見えている割合・鼻の重心・眠りの Z の割合を測る。
    private func pixelMetrics(of image: UIImage) -> (nonBlackFraction: Double, noseCenterX: Double?, sleepMarkFraction: Double)? {
        guard let (pixels, width, height) = rgbaPixels(of: image) else { return nil }
        var visible = 0
        var blue = 0
        var noseSum = 0.0
        var noseCount = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if max(r, g, b) > 24 {
                visible += 1
            }
            // 眠りの Z の青（#76BBFD、縁のにじみを含む）。ほかの部品の色は含まない。
            if b > 120, b - r > 60, b > g {
                blue += 1
            }
            // 鼻（コーラル色）の画素の重心の x。画素の中心を足す。
            if r > 200, (100...180).contains(g), (70...150).contains(b), r - g > 60 {
                noseSum += Double((index / 4) % width) + 0.5
                noseCount += 1
            }
        }
        let total = Double(width * height)
        let noseCenter = noseCount > 0 ? noseSum / Double(noseCount) / Double(width) : nil
        return (Double(visible) / total, noseCenter, Double(blue) / total)
    }
}
