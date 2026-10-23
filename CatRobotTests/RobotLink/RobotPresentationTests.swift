import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

@MainActor
final class RobotPresentationTests: XCTestCase {
    func testConnectionDistinguishesPermissionAuthenticationAndFirmwareRecovery() {
        XCTAssertNotEqual(RobotConnectionPresentation(snapshot: .init(state: .unavailable(.unauthorized))).message,
                          RobotConnectionPresentation(snapshot: .init(state: .reconnecting(.authenticationFailed))).message)
        let returning = RobotConnectionPresentation(snapshot: .init(state: .connected,
            status: robotStatus(state: .returning, flags: [.link, .returning])))
        XCTAssertTrue(returning.message.contains("復帰"))
        XCTAssertFalse(returning.canCalibrate)
    }

    func testCalibrationSavedLabelRequiresVerifiedEntryAndUnchangedDraft() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let session = RobotCalibrationSession(link: h.link, clock: h.clock)
        let opening = Task { try await session.begin() }
        await h.drain()
        XCTAssertFalse(session.saveStateText.contains("保存済み"))
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, 1])))
        await h.drain()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .limits, data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
        try await opening.value
        XCTAssertEqual(session.saveStateText, "ロボットに保存済み")
        session.preview(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2))
        XCTAssertEqual(session.saveStateText, "未保存の変更があります")
        session.cancel()
    }

    func testFakeCalibrationLandscapeAndMaximumTypeRender() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let session = RobotCalibrationSession(link: h.link, clock: h.clock)
        let opening = Task { try await session.begin() }
        await h.drain()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, 1])))
        await h.drain()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .limits, data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
        try await opening.value
        let model = RobotSettingsModel(link: h.link, preferences: h.preferences, clock: h.clock)
        let face = FaceTrackingCoordinator(source: FakeFaceCaptureSource(), link: h.link,
            clock: h.clock, preferences: h.preferences, motion: MotionControllerSpy())
        for size in [DynamicTypeSize.large, .accessibility5] {
            try await capture(NavigationStack { RobotCalibrationView(session: session, onClose: { _ in }) },
                              name: "calibration-\(size)", size: size)
            try await capture(NavigationStack { RobotConnectionView(model: model, faceTracking: face) },
                              name: "connection-\(size)", size: size)
        }
        let waiting = RobotLinkHarness()
        await waiting.beginGatt()
        let waitingModel = RobotSettingsModel(link: waiting.link, preferences: waiting.preferences, clock: waiting.clock)
        for size in [DynamicTypeSize.large, .accessibility5] {
            try await capture(NavigationStack { RobotConnectionView(model: waitingModel) },
                              name: "pending-connection-\(size)", size: size)
        }
        session.cancel()
    }
    private func capture<V: View>(_ view: V, name: String, size: DynamicTypeSize) async throws {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(host.view.bounds.width, host.view.bounds.height)
        attach(host.view, name: "\(name)-top")
        if let scroll = scrollView(in: host.view) {
            if name.hasPrefix("connection-"), size.isAccessibilitySize {
                let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                for (index, offset) in stride(from: CGFloat(0), through: bottom, by: max(1, scroll.bounds.height * 0.8)).enumerated() {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    attach(host.view, name: "\(name)-page-\(index)")
                }
            }
            if name.hasPrefix("pending-connection"), size.isAccessibilitySize {
                scroll.setContentOffset(CGPoint(x: 0, y: 220), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                attach(host.view, name: "\(name)-cancel-control")
            }
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            attach(host.view, name: "\(name)-bottom")
        } else { XCTFail("Settings must remain scrollable") }
        window.isHidden = true
    }

    private func attach(_ view: UIView, name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let attachment = XCTAttachment(image: renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) })
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

}
