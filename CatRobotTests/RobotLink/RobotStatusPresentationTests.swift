import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

final class RobotStatusPresentationTests: XCTestCase {
    func testProjectionShowsConnectionOnlyAndDoesNotBlockConversation() {
        for state in [RobotLinkState.unselected, .unavailable(.unauthorized), .unsupported, .suspended] {
            XCTAssertEqual(RobotStatusPresentation(snapshot: .init(state: state)).status, .disconnected)
        }
        for state in [RobotLinkState.connecting, .preparing, .reconnecting(.disconnected)] {
            XCTAssertEqual(RobotStatusPresentation(snapshot: .init(state: state)).status, .reconnecting)
        }
        let connected = RobotStatusPresentation(snapshot: .init(state: .connected,
            status: robotStatus(state: .returning, flags: [.returning])))
        XCTAssertEqual(connected.status, .connected)
        var view = ConversationViewState.listening
        view.robotStatus = .disconnected
        XCTAssertEqual(view.phase, .listening)
        XCTAssertTrue(view.allowsTypedSubmission)
        XCTAssertNil(view.errorMessage)
    }

    func testAngleNotificationsNeverCreateConnectionAnnouncements() {
        let old = RobotStatusPresentation(snapshot: .init(state: .connected, status: robotStatus()))
        let angle = RobotStatusPresentation(snapshot: .init(state: .connected, status: robotStatus(yaw: 123, pitch: -20)))
        XCTAssertEqual(old, angle)
        XCTAssertNil(RobotStatusPresentation.announcement(from: old.status, to: angle.status))
        XCTAssertEqual(RobotStatusPresentation.announcement(from: old.status, to: .disconnected), "首と未接続")
        XCTAssertEqual(RobotStatusPresentation.announcement(from: .disconnected, to: .reconnecting), "首を再接続中")
        XCTAssertNil(RobotStatusPresentation.announcement(from: .reconnecting, to: .reconnecting))
    }

    @MainActor
    func testFakeConversationConnectionHeaderInLandscapeAndMaximumType() async throws {
        for type in [DynamicTypeSize.large, .accessibility5] {
            var state = ConversationViewState.listening
            state.robotStatus = .reconnecting
            let actions = ConversationActions(toggleListening: {}, showTypedInput: {}, hideTypedInput: {},
                updateTypedText: { _ in }, sendTypedText: {}, performRecovery: { _ in })
            let view = ConversationView(state: state, actions: actions).environment(\.dynamicTypeSize, type)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
            attachment.name = "conversation-robot-header-\(type)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }
}
