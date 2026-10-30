import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

/// Runs the real ConversationView task/animation path with no microphone or robot.
@MainActor
final class CatFaceLifePresentationTests: XCTestCase {
    func testYawnCompletesIntoSleepy() async throws {
        let fixture = LiveFaceFixture()
        let (window, host) = try host(fixture)
        defer { releaseWindow(window) }
        try await Task.sleep(for: .milliseconds(250))
        fixture.state.inactivity = .sleepy
        try await Task.sleep(for: .milliseconds(2_600))
        XCTAssertGreaterThan(try lowerMouthCoralPixels(capture(host.view, name: "idle-life-complete-peak")), 200)
        try await Task.sleep(for: .milliseconds(2_200))
        XCTAssertEqual(try lowerMouthCoralPixels(capture(host.view, name: "idle-life-complete-sleepy")), 0)
    }

    func testVisibleSleepyTransitionShowsYawnAndSpeechClearsIt() async throws {
        let fixture = LiveFaceFixture()
        let (window, host) = try host(fixture)
        defer { releaseWindow(window) }
        try await Task.sleep(for: .milliseconds(250))
        fixture.state.inactivity = .sleepy
        try await Task.sleep(for: .milliseconds(2_600))
        let peak = capture(host.view, name: "idle-life-live-yawn")
        XCTAssertGreaterThan(try lowerMouthCoralPixels(peak), 200, "The live transition must display the large yawning mouth")
        fixture.state.phase = .speaking
        fixture.state.mouthPose = .closed
        try await Task.sleep(for: .milliseconds(400))
        let interrupted = capture(host.view, name: "idle-life-interrupted-speaking")
        XCTAssertEqual(try lowerMouthCoralPixels(interrupted), 0, "Speech owns the face immediately after its normal transition")
    }

    func testHiddenSleepyTransitionDoesNotReplayYawnOnReturn() async throws {
        let fixture = LiveFaceFixture()
        let (window, host) = try host(fixture)
        defer { releaseWindow(window) }
        try await Task.sleep(for: .milliseconds(200))
        fixture.visible = false
        try await Task.sleep(for: .milliseconds(100))
        fixture.state.inactivity = .sleepy
        try await Task.sleep(for: .milliseconds(100))
        fixture.visible = true
        try await Task.sleep(for: .milliseconds(2_600))
        let image = capture(host.view, name: "idle-life-settings-return")
        XCTAssertEqual(try lowerMouthCoralPixels(image), 0)
    }

    private func host(_ fixture: LiveFaceFixture) throws -> (UIWindow, UIHostingController<LiveFaceScene>) {
        let host = UIHostingController(rootView: LiveFaceScene(fixture: fixture))
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.backgroundColor = .black
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func capture(_ view: UIView, name: String) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func lowerMouthCoralPixels(_ image: UIImage) throws -> Int {
        let (pixels, width, height) = try XCTUnwrap(rgbaPixels(of: image))
        var count = 0
        // Lower middle excludes the coral nose in every ordinary preset.
        for y in Int(Double(height) * 0.70)..<Int(Double(height) * 0.93) {
            for x in Int(Double(width) * 0.35)..<Int(Double(width) * 0.65) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 180, g < 180, b < 180, r - g > 40 { count += 1 }
            }
        }
        return count
    }
}

@MainActor
private final class LiveFaceFixture: ObservableObject {
    @Published var state = ConversationViewState.listening
    @Published var visible = true
}

private struct LiveFaceScene: View {
    @ObservedObject var fixture: LiveFaceFixture
    var body: some View {
        ConversationView(state: fixture.state,
            actions: .init(toggleListening: {}, showTypedInput: {}, hideTypedInput: {},
                           updateTypedText: { _ in }, sendTypedText: {}, performRecovery: { _ in }),
            isFaceLifeVisible: fixture.visible)
            .environment(\.scenePhase, .active)
            .ignoresSafeArea()
    }
}
