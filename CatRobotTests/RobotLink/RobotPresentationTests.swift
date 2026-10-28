import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

@MainActor
final class RobotPresentationTests: XCTestCase {
    /// 校正の左列の項目。設定の `settingsCategory.*` と同じ形の識別子で、上から順に並ぶ。
    private static let calibrationCategories = ["calibrationCategory.offsets", "calibrationCategory.direction", "calibrationCategory.movement"]
    /// 各項目にだけある操作部品。
    private static let categoryControls = ["calibrationCategory.offsets": "左右のずれ",
                                           "calibrationCategory.direction": "左右を反転",
                                           "calibrationCategory.movement": "ハードをゆっくり左端へ"]
    /// 各項目の先頭の操作部品。開いた直後にスクロールせず見えているべきもの。
    private static let firstControls = ["calibrationCategory.offsets": "左右のずれ",
                                        "calibrationCategory.direction": "左右を反転",
                                        "calibrationCategory.movement": "正面を向かせる"]
    private static let stopLabel = "ハードの動作を停止"
    private static let backLabel = "ロボットの設定へ戻る"
    private static let categoriesBackLabel = "調整項目へ戻る"
    private static let saveLabel = "中立・回転方向をロボットに保存"
    private static let restoreLabel = "中立・回転方向の変更を戻す"

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
        for size in [DynamicTypeSize.large, .accessibility5] {
            // 顔追尾の向きは「カメラと顔追尾」へ移ったので、校正画面にはロボットへ保存する値だけが残る。
            try await capture(NavigationStack { RobotCalibrationView(session: session, onClose: { _ in }) },
                              name: "calibration-\(size)", size: size)
            try await capture(NavigationStack { RobotConnectionView(model: model) },
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

    private func presentedController(in controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController { return presented }
        return controller.children.lazy.compactMap { self.presentedController(in: $0) }.first
    }

    private final class SettingsTextSize: ObservableObject {
        @Published var value: DynamicTypeSize = .large
    }

    private struct SettingsTextSizeFixture: View {
        let settings: ConversationSettingsView
        @ObservedObject var size: SettingsTextSize
        var body: some View { settings.environment(\.dynamicTypeSize, size.value) }
    }

    /// 設定シートの上に開いた校正。
    private struct CalibrationSheet {
        let harness: RobotLinkHarness
        let model: RobotSettingsModel
        let session: RobotCalibrationSession
        let host: UIViewController
        let navigation: UINavigationController
        let textSize: SettingsTextSize
        let window: UIWindow
        let defaults: UserDefaults
        let defaultsName: String
        /// 開く前の設定で「ロボット」の行があった位置。標準文字では左列の行。
        let settingsRowFrame: CGRect
        /// 校正の画面が積まれた深さ。標準文字では2、大きい文字では設定も一覧からロボットの詳細へ進むので3。
        let calibrationDepth: Int
        var view: UIView { host.view }
    }

    /// 設定シートを「ロボット」で開き、利用者と同じく「ロボット」の入口から校正へ進む。
    /// 押し込みが済み、校正の値を読み終えて編集できるところで返す。後片付けは release(_:)。
    private func openCalibrationInSettings(textSize initialSize: DynamicTypeSize = .large) async throws -> CalibrationSheet {
        await enableAccessibilityRuntime()
        let h = RobotLinkHarness()
        await h.connectReady()
        let model = RobotSettingsModel(link: h.link, preferences: h.preferences, clock: h.clock)
        let defaultsName = "calibration-sheet-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let view = ConversationSettingsView(voiceSettings: SpeechVoiceSettings(defaults: defaults),
            modelSettings: ConversationModelSettings(defaults: defaults),
            memory: LongTermMemoryViewModel(memory: LongTermMemoryManager(store: InMemoryLongTermMemoryStore())),
            usage: ConversationUsageSpy(), idleSettings: ConversationIdleSettings(defaults: defaults),
            robotSettings: model, initialCategory: .robot, onDeleteAll: {}, onDone: {})
        let textSize = SettingsTextSize()
        textSize.value = initialSize
        let host = UIHostingController(rootView: SettingsTextSizeFixture(settings: view, size: textSize))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        do {
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let navigation = try XCTUnwrap(navigationController(in: host), "Settings must keep a single navigation stack")
            XCTAssertEqual(navigation.viewControllers.count, 1)
            let foundSettingsRow = try await reachableAccessibilityElement(in: host.view,
                identifier: SettingsCategory.robot.accessibilityIdentifier,
                scrollingIn: initialSize.isAccessibilitySize ? detailScrollView(in: host.view) : nil)
            let settingsRow = try XCTUnwrap(foundSettingsRow)
            let settingsRowFrame = try accessibilityFrame(of: settingsRow.element, in: host.view)
            var depth = 2
            if initialSize.isAccessibilitySize {
                // 大きい文字では設定も一覧から詳細へ進むので、「ロボット」の行を押してから入口を探す。
                try await activateAccessibilityElement(in: host.view, identifier: SettingsCategory.robot.accessibilityIdentifier,
                                                       scrollingIn: detailScrollView(in: host.view))
                let robot = try await waitForNavigation(navigation, toShow: 2, in: host.view)
                XCTAssertTrue(robot, "The robot settings open as a detail at large type")
                depth = 3
            }

            // 校正の入口は右列（大きい文字ではロボットの詳細）の下にあるので、利用者と同じく送ってから押す。
            let detail = detailScrollView(in: host.view)
            try await activateAccessibilityElement(in: host.view, label: "中立と回転方向を調整", scrollingIn: detail)
            let opened = try await waitUntil { model.calibration != nil }
            XCTAssertTrue(opened, "The robot column must open calibration")
            await h.drain()
            h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, 1])))
            await h.drain()
            h.transport.emit(.value(attempt: h.attempt, characteristic: .limits, data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
            await h.drain()
            let pushed = try await waitForNavigation(navigation, toShow: depth, in: host.view)
            XCTAssertTrue(pushed, "Calibration must be pushed over the whole settings sheet, not inside the detail column")
            let top = try XCTUnwrap(navigation.topViewController)
            XCTAssertEqual(top.view.convert(top.view.bounds, to: host.view).width, host.view.bounds.width, accuracy: 1)
            XCTAssertTrue(top.navigationItem.hidesBackButton, "Leaving calibration goes through the guarded Back, not the system Back")
            let showsBar = try await waitUntil(settling: host.view) { !navigation.isNavigationBarHidden }
            XCTAssertTrue(showsBar, "Calibration needs its own stop and back buttons")
            let coversColumns = try await waitUntil(settling: host.view) {
                self.accessibilityElement(in: host.view, identifier: SettingsCategory.conversation.accessibilityIdentifier) == nil
            }
            XCTAssertTrue(coversColumns, "The category column must not stay reachable during calibration")
            let session = try XCTUnwrap(model.calibration)
            let editable = try await waitUntil { session.canEdit }
            XCTAssertTrue(editable, "The fixture finishes reading calibration")
            return CalibrationSheet(harness: h, model: model, session: session, host: host, navigation: navigation,
                                    textSize: textSize, window: window, defaults: defaults, defaultsName: defaultsName,
                                    settingsRowFrame: settingsRowFrame, calibrationDepth: depth)
        } catch {
            model.calibration?.cancel()
            model.disconnect()
            releaseWindow(window)
            defaults.removePersistentDomain(forName: defaultsName)
            throw error
        }
    }

    /// 途中で throw した試験でも、fixture が始めた校正と接続を終わらせてから片付ける（閉じ済みなら何もしない）。
    private func release(_ sheet: CalibrationSheet) {
        sheet.session.cancel()
        sheet.model.disconnect()
        releaseWindow(sheet.window)
        sheet.defaults.removePersistentDomain(forName: sheet.defaultsName)
    }

    /// この fixture は保存の確認応答を返さないので、切断してから閉じる。
    private func closeCalibration(_ sheet: CalibrationSheet) async {
        sheet.model.disconnect()
        await sheet.harness.drain()
        await sheet.model.closeCalibration(.restore)
    }

    private func changeTextSize(_ sheet: CalibrationSheet, to size: DynamicTypeSize) async throws {
        sheet.textSize.value = size
        try await Task.sleep(for: .milliseconds(300))
        settleRendering(sheet.view)
    }

    /// 未保存のまま「ロボットの設定へ戻る」を押すと確認が出る。確かめた後は「そのまま編集」で取り消す。
    private func expectExitConfirmation(_ sheet: CalibrationSheet, name: String,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let host = sheet.host
        try await activateAccessibilityElement(in: host.view, label: Self.backLabel, file: file, line: line)
        let presented = try await waitUntil(settling: host.view) { self.presentedController(in: host)?.isBeingPresented == false }
        let dialog = try XCTUnwrap(presented ? presentedController(in: host) : nil, "Back must ask before discarding unsaved changes",
                                   file: file, line: line)
        XCTAssertNotNil(dialog.view.window, file: file, line: line)
        XCTAssertTrue(sheet.model.calibration === sheet.session, file: file, line: line)
        XCTAssertEqual(sheet.navigation.viewControllers.count, sheet.calibrationDepth, file: file, line: line)
        attach(dialog.view, name: name)
        if accessibilityElement(in: dialog.view, label: "そのまま編集") != nil {
            try await activateAccessibilityElement(in: dialog.view, label: "そのまま編集", file: file, line: line)
        } else {
            // A popover omits the cancel button. VoiceOver's escape gesture dismisses it.
            var responder: UIView? = dialog.view
            var escaped = false
            while let view = responder, !escaped {
                escaped = view.accessibilityPerformEscape()
                responder = view.superview
            }
            XCTAssertTrue(escaped, "The confirmation popover must support cancellation", file: file, line: line)
        }
        let cancelled = try await waitUntil(settling: host.view) { self.presentedController(in: host) == nil }
        XCTAssertTrue(cancelled, file: file, line: line)
        XCTAssertTrue(sheet.model.calibration === sheet.session, "Cancelling Back must preserve calibration", file: file, line: line)
        XCTAssertEqual(sheet.navigation.viewControllers.count, sheet.calibrationDepth, file: file, line: line)
    }

    /// 中立を少しずらした未保存の値をプレビューする。
    private func previewUnsavedOffset(_ session: RobotCalibrationSession) throws -> RobotCalibrationValues {
        let draft = try XCTUnwrap(session.draft)
        let changed = RobotCalibrationValues(yawOffsetDeci: draft.yawOffsetDeci + 10,
                                             pitchOffsetDeci: draft.pitchOffsetDeci, invert: draft.invert)
        session.preview(changed)
        XCTAssertTrue(session.hasNewChanges)
        return changed
    }

    private func isSelected(in view: UIView, identifier: String) -> Bool {
        guard let element = accessibilityElement(in: view, identifier: identifier) else { return false }
        let traits = element.responds(to: NSSelectorFromString("accessibilityTraitsBlock")) ? element.accessibilityTraitsBlock : nil
        return (traits?() ?? element.accessibilityTraits).contains(.selected)
    }

    private func accessibilityValue(of element: NSObject) -> String? {
        let value = element.responds(to: NSSelectorFromString("accessibilityValueBlock")) ? element.accessibilityValueBlock : nil
        return value?() ?? element.accessibilityValue
    }

    func testCalibrationCoversWholeSettingsSheetAndReturnsToTheColumns() async throws {
        let sheet = try await openCalibrationInSettings()
        defer { release(sheet) }
        let host = sheet.host, navigation = sheet.navigation, model = sheet.model
        attach(host.view, name: "settings-calibration")

        let activeSession = sheet.session
        for size in [DynamicTypeSize.accessibility5, .large] {
            try await changeTextSize(sheet, to: size)
            XCTAssertTrue(model.calibration === activeSession, "Changing text size must keep the active calibration session")
            XCTAssertEqual(navigation.viewControllers.count, 2, "Changing text size must not pop calibration")
            XCTAssertNotNil(accessibilityElement(in: host.view, label: Self.stopLabel), "The app's Stop control must remain reachable")
            XCTAssertNotNil(accessibilityElement(in: host.view, label: Self.backLabel), "The app's guarded Back control must remain reachable")
            attach(host.view, name: "settings-calibration-text-size-\(size)")

            _ = try previewUnsavedOffset(activeSession)
            try await expectExitConfirmation(sheet, name: "settings-calibration-confirmation-\(size)")
        }

        await closeCalibration(sheet)
        XCTAssertNil(model.calibration)
        let returned = try await waitForNavigation(navigation, toShow: 1, in: host.view)
        XCTAssertTrue(returned, "Closing calibration returns to the settings columns")
        let showsColumns = try await waitUntil(settling: host.view) {
            self.accessibilityElement(in: host.view, identifier: SettingsCategory.robot.accessibilityIdentifier) != nil
        }
        XCTAssertTrue(showsColumns, "The category column is reachable again after calibration")
        attach(host.view, name: "settings-calibration-returned")
    }

    func testCalibrationCategoriesUseSettingsColumnAndKeepDraft() async throws {
        let sheet = try await openCalibrationInSettings()
        defer { release(sheet) }
        let view = sheet.view, session = sheet.session

        // 左列は設定の左列と同じ位置・幅に、上から中立の調整・回転方向・動作確認の順で並ぶ。初期は中立の調整。
        var rows: [CGRect] = []
        for id in Self.calibrationCategories {
            let found = try await reachableAccessibilityElement(in: view, identifier: id)
            let row = try XCTUnwrap(found, "\(id) must be in the left column")
            rows.append(try accessibilityFrame(of: row.element, in: view))
        }
        XCTAssertEqual(rows[0].minX, sheet.settingsRowFrame.minX, accuracy: 1, "Calibration categories sit where the settings categories do")
        XCTAssertEqual(rows[0].width, sheet.settingsRowFrame.width, accuracy: 1, "Calibration categories use the settings column width")
        XCTAssertLessThan(rows[0].midY, rows[1].midY)
        XCTAssertLessThan(rows[1].midY, rows[2].midY)
        XCTAssertTrue(isSelected(in: view, identifier: Self.calibrationCategories[0]), "Calibration opens on the offsets")

        let changed = try previewUnsavedOffset(session)
        for id in Self.calibrationCategories + [Self.calibrationCategories[0]] {
            try await activateAccessibilityElement(in: view, identifier: id)
            let selected = try await waitUntil(settling: view) { self.isSelected(in: view, identifier: id) }
            XCTAssertTrue(selected, "\(id) becomes the selected category")
            let control = try XCTUnwrap(Self.categoryControls[id])
            let shown = try await reachableAccessibilityElement(in: view, label: control, scrollingIn: self.detailScrollView(in: view))
            XCTAssertNotNil(shown, "\(id) shows \(control)")
            let others = Self.categoryControls.filter { $0.key != id }.map(\.value)
            let onlyOwn = try await waitUntil(settling: view) { others.allSatisfy { self.accessibilityElement(in: view, label: $0) == nil } }
            XCTAssertTrue(onlyOwn, "\(id) shows only its own controls")
            // 保存状態・保存・戻す・停止・戻るは、どの項目でもスクロールせずに画面内にある。
            for label in [session.saveStateText, Self.saveLabel, Self.restoreLabel, Self.stopLabel, Self.backLabel] {
                let element = try XCTUnwrap(accessibilityElement(in: view, label: label), "\(label) stays reachable in \(id)")
                XCTAssertTrue(view.bounds.contains(try accessibilityFrame(of: element, in: view)), "\(label) stays on screen in \(id)")
            }
            XCTAssertEqual(session.draft, changed, "Switching categories keeps the draft")
            XCTAssertTrue(sheet.model.calibration === session, "Switching categories keeps the calibration session")
            XCTAssertEqual(sheet.navigation.viewControllers.count, sheet.calibrationDepth, "Switching categories stays on the calibration screen")
            attach(view, name: "calibration-category-\(id)")
        }
        // 中立の調整へ戻ると、プレビュー中の値が表示に残っている。
        let slider = try XCTUnwrap(accessibilityElement(in: view, label: "左右のずれ"))
        XCTAssertEqual(accessibilityValue(of: slider), "1.0度")
        await closeCalibration(sheet)
    }

    func testCalibrationTextSizeRoundTripKeepsSessionDraftAndCategory() async throws {
        let sheet = try await openCalibrationInSettings()
        defer { release(sheet) }
        let view = sheet.view, session = sheet.session, movement = Self.calibrationCategories[2]
        try await activateAccessibilityElement(in: view, identifier: movement)
        let selected = try await waitUntil(settling: view) { self.isSelected(in: view, identifier: movement) }
        XCTAssertTrue(selected)
        let changed = try previewUnsavedOffset(session)

        // 大きい文字では項目の一覧になる。自動では詳細へ進まない。
        try await changeTextSize(sheet, to: .accessibility5)
        XCTAssertTrue(sheet.model.calibration === session)
        XCTAssertEqual(sheet.navigation.viewControllers.count, sheet.calibrationDepth, "Entering large type must not push a category detail")
        for id in Self.calibrationCategories {
            let listed = try await reachableAccessibilityElement(in: view, identifier: id, scrollingIn: self.detailScrollView(in: view))
            XCTAssertNotNil(listed, "\(id) is listed at large type")
        }
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.stopLabel))
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.backLabel))
        let save = try await reachableAccessibilityElement(in: view, label: Self.saveLabel, scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(save, "The calibration list keeps saving reachable")
        attach(view, name: "calibration-large-type-list")

        try await changeTextSize(sheet, to: .large)
        let restored = try await waitUntil(settling: view) { self.isSelected(in: view, identifier: movement) }
        XCTAssertTrue(restored, "Returning to standard type keeps the selected category")
        let control = try await reachableAccessibilityElement(in: view, label: try XCTUnwrap(Self.categoryControls[movement]),
                                                              scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(control)
        XCTAssertTrue(sheet.model.calibration === session, "Changing text size must keep the calibration session")
        XCTAssertEqual(session.draft, changed, "Changing text size must keep the draft")
        XCTAssertEqual(sheet.navigation.viewControllers.count, sheet.calibrationDepth)
        attach(view, name: "calibration-text-size-returned")
        await closeCalibration(sheet)
    }

    func testLargeTypeCalibrationDetailKeepsStopAndGuardedExit() async throws {
        let sheet = try await openCalibrationInSettings()
        defer { release(sheet) }
        let view = sheet.view, session = sheet.session, direction = Self.calibrationCategories[1]
        let changed = try previewUnsavedOffset(session)
        try await changeTextSize(sheet, to: .accessibility5)

        try await activateAccessibilityElement(in: view, identifier: direction, scrollingIn: self.detailScrollView(in: view))
        let pushed = try await waitForNavigation(sheet.navigation, toShow: sheet.calibrationDepth + 1, in: view)
        XCTAssertTrue(pushed, "Large type opens the category as a detail")
        let control = try await reachableAccessibilityElement(in: view, label: try XCTUnwrap(Self.categoryControls[direction]),
                                                              scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(control)
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.stopLabel), "Stop stays reachable in the detail")
        // システムの戻るは長押しで設定まで一度に戻れて、未保存の確認を通らない。詳細では出さず、項目の一覧へ戻るボタンだけを置く。
        XCTAssertTrue(sheet.navigation.topViewController?.navigationItem.hidesBackButton == true,
                      "The detail must not offer the system Back and its history menu")
        XCTAssertNil(accessibilityElement(in: view, label: Self.backLabel), "Leaving calibration goes through the guarded list")
        let save = try await reachableAccessibilityElement(in: view, label: Self.saveLabel, scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(save, "The detail keeps saving reachable")
        XCTAssertTrue(sheet.model.calibration === session)
        attach(view, name: "calibration-large-type-detail")

        try await activateAccessibilityElement(in: view, label: Self.categoriesBackLabel)
        let returned = try await waitForNavigation(sheet.navigation, toShow: sheet.calibrationDepth, in: view)
        XCTAssertTrue(returned, "The detail returns to the calibration list")
        XCTAssertTrue(sheet.model.calibration === session, "Returning from the detail keeps the calibration session")
        XCTAssertEqual(session.draft, changed, "Returning from the detail keeps the draft")
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.stopLabel))
        try await expectExitConfirmation(sheet, name: "calibration-large-type-confirmation")

        // 詳細を開いたまま標準の文字へ戻すと、2列に戻ってその項目を選ぶ。
        try await activateAccessibilityElement(in: view, identifier: direction, scrollingIn: self.detailScrollView(in: view))
        let reopened = try await waitForNavigation(sheet.navigation, toShow: sheet.calibrationDepth + 1, in: view)
        XCTAssertTrue(reopened)
        try await changeTextSize(sheet, to: .large)
        let folded = try await waitForNavigation(sheet.navigation, toShow: sheet.calibrationDepth, in: view)
        XCTAssertTrue(folded, "Returning to standard type folds the detail back into the columns")
        let selected = try await waitUntil(settling: view) { self.isSelected(in: view, identifier: direction) }
        XCTAssertTrue(selected, "The columns select the category that was open")
        XCTAssertTrue(sheet.model.calibration === session)
        XCTAssertEqual(session.draft, changed)
        await closeCalibration(sheet)
    }

    /// 最初から大きい文字: 設定の一覧 → ロボットの詳細 → 校正の一覧 → 項目の詳細と積み、一覧へ戻ってから確認付きで抜ける。
    func testLargeTypeSettingsOpenCalibrationDetailAndKeepGuardedExit() async throws {
        let sheet = try await openCalibrationInSettings(textSize: .accessibility5)
        defer { release(sheet) }
        let view = sheet.view, session = sheet.session, depth = sheet.calibrationDepth, direction = Self.calibrationCategories[1]
        XCTAssertEqual(depth, 3, "Large type reaches calibration through the robot settings detail")
        for id in Self.calibrationCategories {
            let listed = try await reachableAccessibilityElement(in: view, identifier: id, scrollingIn: self.detailScrollView(in: view))
            XCTAssertNotNil(listed, "\(id) is listed at large type")
        }
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.stopLabel))
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.backLabel))
        let listSave = try await reachableAccessibilityElement(in: view, label: Self.saveLabel, scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(listSave, "The calibration list keeps saving reachable")
        attach(view, name: "calibration-large-type-root")

        let changed = try previewUnsavedOffset(session)
        try await activateAccessibilityElement(in: view, identifier: direction, scrollingIn: self.detailScrollView(in: view))
        let pushed = try await waitForNavigation(sheet.navigation, toShow: depth + 1, in: view)
        XCTAssertTrue(pushed, "The category opens as a detail over the calibration list")
        let control = try await reachableAccessibilityElement(in: view, label: try XCTUnwrap(Self.categoryControls[direction]),
                                                              scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(control)
        XCTAssertNotNil(accessibilityElement(in: view, label: Self.stopLabel), "Stop stays reachable in the detail")
        XCTAssertTrue(sheet.navigation.topViewController?.navigationItem.hidesBackButton == true,
                      "The detail must not offer the system Back and its history menu")
        XCTAssertNil(accessibilityElement(in: view, label: Self.backLabel), "Leaving calibration goes through the guarded list")
        let detailSave = try await reachableAccessibilityElement(in: view, label: Self.saveLabel, scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(detailSave, "The detail keeps saving reachable")
        XCTAssertTrue(sheet.model.calibration === session)
        attach(view, name: "calibration-large-type-start-detail")

        try await activateAccessibilityElement(in: view, label: Self.categoriesBackLabel)
        let returned = try await waitForNavigation(sheet.navigation, toShow: depth, in: view)
        XCTAssertTrue(returned, "The detail returns to the calibration list")
        XCTAssertTrue(sheet.model.calibration === session, "Returning from the detail keeps the calibration session")
        XCTAssertEqual(session.draft, changed, "Returning from the detail keeps the draft")
        try await expectExitConfirmation(sheet, name: "calibration-large-type-start-confirmation")

        // 閉じるとロボットの詳細へ戻り、入口をもう一度押せる。
        await closeCalibration(sheet)
        XCTAssertNil(sheet.model.calibration)
        let robot = try await waitForNavigation(sheet.navigation, toShow: depth - 1, in: view)
        XCTAssertTrue(robot, "Closing calibration returns to the robot settings detail")
        let entry = try await reachableAccessibilityElement(in: view, label: "中立と回転方向を調整", scrollingIn: self.detailScrollView(in: view))
        XCTAssertNotNil(entry, "The calibration entry is reachable again")
        attach(view, name: "calibration-large-type-start-returned")
    }

    func testLargestStandardTypeKeepsCalibrationFormAndSaveControlsOnScreen() async throws {
        let sheet = try await openCalibrationInSettings()
        defer { release(sheet) }
        let view = sheet.view, session = sheet.session
        try await changeTextSize(sheet, to: .xxxLarge)
        // 状態文が最も長くなる切断の状態で確かめる。
        sheet.model.disconnect()
        await sheet.harness.drain()
        XCTAssertEqual(session.phase, .failed(.disconnected))
        XCTAssertEqual(sheet.navigation.viewControllers.count, sheet.calibrationDepth)

        for id in Self.calibrationCategories {
            try await activateAccessibilityElement(in: view, identifier: id)
            let selected = try await waitUntil(settling: view) { self.isSelected(in: view, identifier: id) }
            XCTAssertTrue(selected, "\(id) becomes the selected category")
            let foundStatus = try await reachableAccessibilityElement(in: view, label: session.saveStateText)
            let status = try XCTUnwrap(foundStatus, "The save state stays reachable in \(id)")
            let statusFrame = try accessibilityFrame(of: status.element, in: view)
            XCTAssertTrue(view.bounds.contains(statusFrame), "The save state stays on screen in \(id)")
            for label in [Self.saveLabel, Self.restoreLabel, Self.stopLabel, Self.backLabel] {
                let element = try XCTUnwrap(accessibilityElement(in: view, label: label), "\(label) stays reachable in \(id)")
                XCTAssertTrue(view.bounds.contains(try accessibilityFrame(of: element, in: view)), "\(label) stays on screen in \(id)")
            }
            // 保存の領域が右列を埋めず、項目の最初の操作がスクロールせずに見えている。
            let controlLabel = try XCTUnwrap(Self.firstControls[id])
            let control = try XCTUnwrap(accessibilityElement(in: view, label: controlLabel), "\(controlLabel) is visible without scrolling in \(id)")
            let controlFrame = try accessibilityFrame(of: control, in: view)
            XCTAssertTrue(view.bounds.contains(controlFrame), "\(controlLabel) stays on screen in \(id)")
            XCTAssertLessThanOrEqual(controlFrame.maxY, statusFrame.minY + 1, "The save area must not cover \(controlLabel) in \(id)")
            attach(view, name: "calibration-xxxLarge-disconnected-\(id)")
        }
        await sheet.model.closeCalibration(.restore)
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
        // 校正の2列では左列もスクロールになりうるので、右列（最も右のスクロール）を送る。
        if let scroll = detailScrollView(in: host.view) {
            if name.hasPrefix("calibration-") || (name.hasPrefix("connection-") && size.isAccessibilitySize) {
                let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                for (index, offset) in stride(from: CGFloat(0), through: bottom, by: max(1, scroll.bounds.height * 0.8)).enumerated() {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    attach(host.view, name: "\(name)-page-\(index)")
                }
            }
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            attach(host.view, name: "\(name)-bottom")
        } else { XCTFail("Settings must remain scrollable") }
        releaseWindow(window)
    }

    private func attach(_ view: UIView, name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let attachment = XCTAttachment(image: renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) })
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
