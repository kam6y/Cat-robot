import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

/// 顔の静止画を XCTest 添付として残す。見た目の合否は採用画像との目視比較で判断し、
/// ここでは「顔が描かれている」「画面の大部分は黒」だけを確認する。
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

    private func capture(expression: FaceExpression, mouthPose: MouthPose) async throws {
        // Mac のモック（scripts/face-render）と同じく、852×393 の矩形全体に 16:9 のキャンバスを高さ基準で置く。
        // Simulator の実画面（例: iPhone 18 Pro の横向き 874×402）の原点に 852×393 の窓を置くと、窓の安全領域は
        // 画面の安全領域との重なりになり、左右・下が非対称になる（左 62・右 40・下 12 前後）。すると顔は高さ 381 に
        // 縮み（97%）、中心が右へ 11pt・上へ 6pt ずれる。顔の描画を製品の安全領域から切り離して確かめるため、
        // この試験の土台では安全領域を無視し、「指定した矩形 = 顔を置く矩形 = キャプチャする矩形」にそろえる。
        let face = ZStack {
            Color.black
            CatFaceView(expression: expression, mouthPose: mouthPose, reduceMotion: true, isAnimating: false)
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
        let visible = try XCTUnwrap(nonBlackFraction(of: image))
        XCTAssertGreaterThan(visible, 0.02, "\(expression) \(mouthPose): the face is missing")
        XCTAssertLessThan(visible, 0.40, "\(expression) \(mouthPose): the screen should stay mostly black")
        // 鼻はキャンバスの中心 x = 0.5 にある。顔が矩形の左右中央に置かれていること（Mac のモックと同じ）。
        let noseCenter = try XCTUnwrap(noseCenterX(of: image), "\(expression) \(mouthPose): the nose is missing")
        XCTAssertEqual(noseCenter, 0.5, accuracy: 0.005, "\(expression) \(mouthPose): face is off center\n\(geometry)")
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

    /// 鼻（コーラル色）の画素の重心の x（画像の幅に対する比）。
    private func noseCenterX(of image: UIImage) -> Double? {
        guard let (pixels, width, height) = rgbaPixels(of: image) else { return nil }
        var sum = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                if r > 200, (100...180).contains(g), (70...150).contains(b), r - g > 60 {
                    sum += Double(x) + 0.5
                    count += 1
                }
            }
        }
        return count > 0 ? sum / Double(count) / Double(width) : nil
    }

    /// 最大チャンネルが 24 を超える画素の割合。
    private func nonBlackFraction(of image: UIImage) -> Double? {
        guard let (pixels, width, height) = rgbaPixels(of: image) else { return nil }
        var visible = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
        where max(pixels[index], pixels[index + 1], pixels[index + 2]) > 24 {
            visible += 1
        }
        return Double(visible) / Double(width * height)
    }

    /// sRGB の RGBA8 画素と幅・高さ。
    private func rgbaPixels(of image: UIImage) -> ([UInt8], Int, Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
