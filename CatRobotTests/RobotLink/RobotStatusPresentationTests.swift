import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

final class RobotConnectionStatusTests: XCTestCase {

    func testReconnectIndicatorLatchesThroughRetriesUntilConnected() {
        var indicator = RobotReconnectIndicator()
        let device = RobotDevice(id: UUID(), name: "首A", rssi: nil)
        let steps: [(RobotLinkState, Bool)] = [
            (.connecting, false), (.preparing, false), (.connected, false),
            (.reconnecting(.timedOut), true), (.connecting, true), (.preparing, true),
            (.reconnecting(.timedOut), true), (.connected, false),
            (.reconnecting(.disconnected), true), (.suspended, false), (.connecting, false)
        ]
        for (state, expected) in steps {
            indicator.update(.init(state: state, device: device))
            XCTAssertEqual(indicator.isVisible, expected, "\(state)")
        }
        for state in [RobotLinkState.unselected, .searching, .unsupported, .unavailable(.poweredOff)] {
            indicator.update(.init(state: .reconnecting(.disconnected), device: device))
            indicator.update(.init(state: state, device: device))
            XCTAssertFalse(indicator.isVisible, "\(state)")
        }
    }

    func testInitialConnectionRetriesStayHiddenUntilTheDeviceHasConnected() {
        var indicator = RobotReconnectIndicator()
        let device = RobotDevice(id: UUID(), name: "保存済みの首", rssi: nil)
        let steps: [(RobotLinkState, Bool)] = [
            (.connecting, false), (.preparing, false), (.reconnecting(.timedOut), false),
            (.connecting, false), (.reconnecting(.timedOut), false), (.connected, false),
            (.reconnecting(.disconnected), true), (.connecting, true), (.suspended, false),
            (.connecting, false), (.reconnecting(.timedOut), true), (.unselected, false),
            (.reconnecting(.timedOut), false)
        ]
        for (state, expected) in steps {
            indicator.update(.init(state: state, device: device))
            XCTAssertEqual(indicator.isVisible, expected, "\(state)")
        }
    }

    func testReconnectIndicatorResetsWhenTheDeviceChanges() {
        var indicator = RobotReconnectIndicator()
        let first = RobotDevice(id: UUID(), name: "首A", rssi: nil)
        let second = RobotDevice(id: UUID(), name: "首B", rssi: nil)
        indicator.update(.init(state: .connected, device: first))
        indicator.update(.init(state: .reconnecting(.timedOut), device: first))
        XCTAssertTrue(indicator.isVisible)
        indicator.update(.init(state: .connecting, device: second))
        XCTAssertFalse(indicator.isVisible, "前の首の再接続表示を新しい接続先に持ち越さない")
        indicator.update(.init(state: .preparing, device: second))
        XCTAssertFalse(indicator.isVisible)
        indicator.update(.init(state: .reconnecting(.disconnected), device: second))
        XCTAssertFalse(indicator.isVisible)
        indicator.update(.init(state: .connected, device: second))
        indicator.update(.init(state: .reconnecting(.disconnected), device: second))
        XCTAssertTrue(indicator.isVisible)
        indicator.update(.init(state: .unselected))
        XCTAssertFalse(indicator.isVisible)
    }

    func testAngleAndSignalUpdatesDoNotChangeReconnectPresentation() {
        let id = UUID()
        var indicator = RobotReconnectIndicator()
        indicator.update(.init(state: .connected, device: .init(id: id, name: "首", rssi: -40),
                               status: robotStatus(yaw: 0, pitch: 0)))
        let initial = indicator
        indicator.update(.init(state: .connected, device: .init(id: id, name: "首", rssi: -60),
                               status: robotStatus(yaw: 120, pitch: -30)))
        XCTAssertEqual(indicator, initial, "角度やRSSIで会話の表示更新を増やさない")
    }

    func testProjectionShowsConnectionOnlyAndDoesNotBlockConversation() {
        for state in [RobotLinkState.unselected, .unavailable(.unauthorized), .unsupported, .suspended] {
            XCTAssertEqual(RobotConnectionStatus(snapshot: .init(state: state)), .disconnected)
        }
        for state in [RobotLinkState.connecting, .preparing, .reconnecting(.disconnected)] {
            XCTAssertEqual(RobotConnectionStatus(snapshot: .init(state: state)), .reconnecting)
        }
        let connected = RobotConnectionStatus(snapshot: .init(state: .connected,
            status: robotStatus(state: .returning, flags: [.returning])))
        XCTAssertEqual(connected, .connected)
        var view = ConversationViewState.listening
        view.robotStatus = .disconnected
        XCTAssertEqual(view.phase, .listening)
        XCTAssertTrue(view.allowsTypedSubmission)
        XCTAssertNil(view.errorMessage)
    }

    func testAngleNotificationsNeverCreateConnectionAnnouncements() {
        let old = RobotConnectionStatus(snapshot: .init(state: .connected, status: robotStatus()))
        let angle = RobotConnectionStatus(snapshot: .init(state: .connected, status: robotStatus(yaw: 123, pitch: -20)))
        XCTAssertEqual(old, angle)
        XCTAssertNil(announcement(from: old, to: angle))
        XCTAssertEqual(announcement(from: old, to: .disconnected), "ハードと未接続")
        XCTAssertEqual(announcement(from: .disconnected, to: .reconnecting), "ハードを再接続中")
        XCTAssertNil(announcement(from: .reconnecting, to: .reconnecting))
    }

    /// The connection announcement is the last rule of the shared policy; nothing else changes between the states.
    private func announcement(from old: RobotConnectionStatus?, to new: RobotConnectionStatus?) -> String? {
        var oldState = ConversationViewState.listening, newState = ConversationViewState.listening
        oldState.robotStatus = old
        newState.robotStatus = new
        return ConversationAnnouncementPolicy.announcement(from: oldState, to: newState)
    }

    @MainActor
    func testFakeConversationConnectionHeaderInLandscapeAndMaximumType() async throws {
        for type in [DynamicTypeSize.large, .accessibility5] {
            var state = ConversationViewState.listening
            state.robotStatus = .reconnecting
            state.isRobotReconnecting = true
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
