import SwiftUI
import XCTest
import UIKit
@testable import FaceSizeTuner

@MainActor
final class FaceSizeTunerTests: XCTestCase {
    // Break caught: slider changes fail to persist, or restore uses a different scale.
    func testChosenScaleSurvivesRelaunchAndReset() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = FaceSizeTuningModel(defaults: defaults)
        model.setScale(0.735)
        XCTAssertEqual(model.scale, 0.735, accuracy: 0.000001)
        XCTAssertEqual(FaceSizeTuningModel(defaults: defaults).scale, 0.735, accuracy: 0.000001)
        model.reset()
        XCTAssertEqual(FaceSizeTuningModel(defaults: defaults).scale, 0.85, accuracy: 0.000001)
    }

    // Break caught: a floating-point slider value copies a rounded value unlike the actual preview.
    func testCopyValueUsesTheNormalizedPreviewScale() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = FaceSizeTuningModel(defaults: defaults)
        for (input, wanted, text) in [(0.734, 0.735, "0.735"), (0.501, 0.5, "0.500"), (0.999, 1.0, "1.000")] {
            model.setScale(input)
            XCTAssertEqual(model.scale, wanted, accuracy: 0.000001)
            let line = try XCTUnwrap(model.copyValue.split(separator: "\n").first { $0.hasPrefix("ConversationView.faceScale = ") })
            let numericValue = line.replacingOccurrences(of: "ConversationView.faceScale = ", with: "")
            XCTAssertEqual(numericValue, text)
            XCTAssertEqual(try XCTUnwrap(Double(numericValue)), wanted, accuracy: 0.000001)
        }
    }

    // Break caught: corrupted saved settings make the face disappear or become enormous.
    func testInvalidSavedValuesRecoverToVisibleSupportedSizes() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for (saved, wanted) in [(-1.0, 0.5), (7.0, 1.0), (Double.nan, 0.85), (Double.infinity, 0.85)] {
            defaults.set(saved, forKey: "faceScale")
            XCTAssertEqual(FaceSizeTuningModel(defaults: defaults).scale, wanted, accuracy: 0.000001)
        }
    }

    // Break caught: preview ignores the slider, scales only one axis, or anchors to a corner.
    func testPreviewScalesBothAxesAroundTheSameCenterForEveryExpression() throws {
        for expression in FaceExpression.allCases {
            let full = try visibleBounds(render(FaceSizePreview(scale: 0.85, expression: expression)))
            let smaller = try visibleBounds(render(FaceSizePreview(scale: 0.68, expression: expression)))
            XCTAssertEqual(smaller.width / full.width, 0.8, accuracy: 0.015, expression.rawValue)
            XCTAssertEqual(smaller.height / full.height, 0.8, accuracy: 0.015, expression.rawValue)
            XCTAssertEqual(smaller.minX, 437 + (full.minX - 437) * 0.8, accuracy: 2, expression.rawValue)
            XCTAssertEqual(smaller.minY, 201 + (full.minY - 201) * 0.8, accuracy: 2, expression.rawValue)
        }
    }


    // Break caught: visible controls do not update/copy the selected value, or full-screen mode traps the user.
    func testControlsAdjustCopyResetAndReturnFromFullScreenAtBothTextSizes() async throws {
        await enableAccessibilityRuntime()
        for (name, textSize) in [("standard", DynamicTypeSize.large), ("largest-text", .accessibility5)] {
            let (defaults, suite) = try isolatedDefaults()
            let model = FaceSizeTuningModel(defaults: defaults)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: FaceSizeTunerView(model: model)
                .environment(\.dynamicTypeSize, textSize).preferredColorScheme(.dark).statusBarHidden())
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
            window.windowLevel = .normal + 1
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            let oldClipboard = UIPasteboard.general.items
            defer {
                UIPasteboard.general.items = oldClipboard
                releaseWindow(window)
                defaults.removePersistentDomain(forName: suite)
            }
            try await waitForAccessibilityTree(in: host.view)
            for id in ["faceSizeSlider", "decreaseFaceSize", "increaseFaceSize", "resetFaceSize", "copyFaceSize", "hideTuningControls"] {
                let element = try XCTUnwrap(accessibilityElement(in: host.view, identifier: id), id)
                let frame = try accessibilityFrame(of: element, in: host.view)
                XCTAssertTrue(host.view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(name): \(id) is clipped: \(frame)")
            }

            let slider = try XCTUnwrap(findSlider(in: host.view))
            slider.setValue((slider.minimumValue + slider.maximumValue) / 2, animated: false)
            slider.sendActions(for: .valueChanged)
            let changed = try await waitUntil(settling: host.view) { abs(model.scale - 0.75) < 0.000001 }
            XCTAssertTrue(changed, "The middle of the slider selects 75%")
            try await activateAccessibilityElement(in: host.view, identifier: "decreaseFaceSize")
            XCTAssertEqual(model.scale, 0.745, accuracy: 0.000001)
            try await activateAccessibilityElement(in: host.view, identifier: "increaseFaceSize")
            XCTAssertEqual(model.scale, 0.75, accuracy: 0.000001)
            try await activateAccessibilityElement(in: host.view, identifier: "copyFaceSize")
            XCTAssertEqual(UIPasteboard.general.string, "顔サイズ: 75.0%\nConversationView.faceScale = 0.750")
            attachTuner(host.view, name: "tuner-\(name)-75-controls")

            try await activateAccessibilityElement(in: host.view, identifier: "hideTuningControls")
            let hidden = try await waitUntil(settling: host.view) {
                self.accessibilityElement(in: host.view, identifier: "faceSizeSlider") == nil
            }
            XCTAssertTrue(hidden)
            XCTAssertEqual(model.scale, 0.75, accuracy: 0.000001)
            attachTuner(host.view, name: "tuner-\(name)-75-fullscreen")
            try await activateAccessibilityElement(in: host.view, identifier: "showTuningControls")
            let restored = try await waitUntil(settling: host.view) {
                self.accessibilityElement(in: host.view, identifier: "faceSizeSlider") != nil
            }
            XCTAssertTrue(restored)
            XCTAssertEqual(model.scale, 0.75, accuracy: 0.000001)
            try await activateAccessibilityElement(in: host.view, identifier: "resetFaceSize")
            XCTAssertEqual(model.scale, 0.85, accuracy: 0.000001)
            attachTuner(host.view, name: "tuner-\(name)-85-reset")
        }
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let slider = findSlider(in: child) { return slider }
        }
        return nil
    }

    private func attachTuner(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: settleRendering(view.window ?? view))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "FaceSizeTunerTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: 874, height: 402))
        renderer.proposedSize = ProposedViewSize(width: 874, height: 402)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func visibleBounds(_ image: CGImage) throws -> CGRect {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if max(pixels[index], pixels[index + 1], pixels[index + 2]) > 24 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "The face must be visible")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
