import SwiftUI
import UIKit
import XCTest
@testable import CatRobot

/// Fixed render fixtures complement behavioral tests. Insets below are simulated,
/// not a measurement of a particular device or a substitute for keyboard/device QA.
@MainActor
final class FaceConversationPresentationTests: XCTestCase {
    private let longCaption = "今日はいい天気だね。窓から見える景色について、ゆっくり話そう。お昼には何を食べたの？楽しかったことも、気になったことも、ここで聞かせてね。最後までちゃんと聞いているよ。"

    func testListeningChipSitsAtTopLeadingAndClearsWhenSpeaking() async throws {
        for insets in [Self.leftIslandInsets, Self.rightIslandInsets] {
            try await renderConversation(.listening, name: "listening-chip-left-\(Int(insets.left))", insets: insets) { view in
                let chip = try XCTUnwrap(accessibilityElement(in: view, identifier: "statusChip.listening"))
                let frame = try accessibilityFrame(of: chip, in: view)
                XCTAssertEqual(frame.minX, insets.left + 16, accuracy: 1)
                XCTAssertEqual(frame.minY, insets.top + 10, accuracy: 1)
                XCTAssertTrue(view.bounds.contains(frame))
                let menu = try XCTUnwrap(accessibilityElement(in: view, identifier: "conversationSettings"))
                XCTAssertFalse(frame.intersects(try accessibilityFrame(of: menu, in: view)))
                try assertFaceFillsEightyPercentBox(in: view, insets: insets)
            }
        }
        try await renderConversation(.speaking(caption: "こんにちは"), name: "listening-chip-cleared") { view in
            XCTAssertNil(accessibilityElement(in: view, identifier: "statusChip.listening"))
        }
    }

    func testLookChipShowsAndClears() async throws {
        var state = ConversationViewState.thinking
        state.caption = "机の上のものを確認するね。"
        state.heldExpression = .happy
        state.isLooking = true
        try await renderConversation(state, name: "look-visible") { view in
            XCTAssertNotNil(accessibilityElement(in: view, identifier: ConversationStatusChip.looking.accessibilityIdentifier))
        }
        try await renderConversation(state, name: "look-maximum-type", typeSize: .accessibility5) { view in
            XCTAssertNotNil(accessibilityElement(in: view, identifier: ConversationStatusChip.looking.accessibilityIdentifier))
        }
        state.isLooking = false
        try await renderConversation(state, name: "look-restored") { view in
            XCTAssertNil(accessibilityElement(in: view, identifier: ConversationStatusChip.looking.accessibilityIdentifier))
            XCTAssertNil(accessibilityElement(in: view, label: "机の上のものを確認するね。"), "返事は字幕として描かない")
        }
    }

    func testSettingsCategoriesRender() async throws {
        let fixture = SettingsFixture(authorization: .authorized)
        await fixture.connectRobot()
        defer { fixture.tearDown() }
        // 左右を入れ替えた設定は描かない。アプリは前面カメラが左の横向きだけに対応し（Info.plist は LandscapeRight のみ）、
        // Dynamic Island が右に来る配置は起こらない。
        for category in SettingsCategory.allCases {
            let (window, host, insets) = try await hostInScene(fixture.view(category).environment(\.dynamicTypeSize, .large))
            try await scrollThroughDetail(host.view, name: "settings-\(category.rawValue)", sidebarInsets: insets)
            releaseWindow(window)
        }
    }

    func testSettingsNavigationSwitchesCategoriesAndReviewsOnboarding() async throws {
        let fixture = SettingsFixture(authorization: .authorized)
        await fixture.connectRobot()
        defer { fixture.tearDown() }
        let (window, host, _) = try await hostInScene(fixture.view(.conversation).environment(\.dynamicTypeSize, .large))
        defer { releaseWindow(window) }
        // 「すべて削除」は Form の行の中にあり、この fixture では行の識別子が要素の木に出ない（描画では表示されている）。
        // VoiceOver が読む名前で探す。
        let deleteAll = "すべて削除"
        try await waitForAccessibilityTree(in: host.view)
        XCTAssertNotNil(accessibilityElement(in: host.view, identifier: ConversationSettingsIdentifier.voicePresetPicker.rawValue),
                        "開いたときは「会話」を選ぶ")
        XCTAssertNil(accessibilityElement(in: host.view, label: deleteAll))
        try await activateAccessibilityElement(in: host.view, identifier: SettingsCategory.memory.accessibilityIdentifier)
        let deleteAllButton = try await reachableAccessibilityElement(in: host.view, label: deleteAll,
                                                                      scrollingIn: detailScrollView(in: host.view))
        XCTAssertNotNil(deleteAllButton, "Selecting 記憶 must replace the detail column with the memory list and すべて削除")
        try capture(host.view, size: host.view.bounds.size, name: "settings-selected-memory")

        try await activateAccessibilityElement(in: host.view, identifier: SettingsCategory.about.accessibilityIdentifier)
        let showsAbout = try await waitUntil(settling: host.view) { self.accessibilityElement(in: host.view, label: "送るもの・保存するもの") != nil }
        XCTAssertTrue(showsAbout, "Selecting このアプリについて must replace the detail column")
        try await activateAccessibilityElement(in: host.view, label: "はじめの説明をもう一度見る", scrollingIn: detailScrollView(in: host.view))
        let presented = try await waitUntil(settling: host.view) { host.presentedViewController?.isBeingPresented == false }
        let sheet = try XCTUnwrap(presented ? host.presentedViewController : nil, "The onboarding review must open as a sheet")
        XCTAssertNotNil(sheet.view.window, "The review sheet must be attached to the window, not only rendered on its own")
        try capture(sheet.view, size: sheet.view.bounds.size, name: "settings-onboarding-review")
        let showsClose = try await waitUntil(settling: sheet.view) { self.accessibilityElement(in: sheet.view, label: "閉じる") != nil }
        XCTAssertTrue(showsClose, "The review sheet offers 閉じる")
        XCTAssertNil(accessibilityElement(in: sheet.view, label: "会話を始める"), "見直しでは会話を始めない")
        try await activateAccessibilityElement(in: sheet.view, label: "閉じる")
        let dismissed = try await waitUntil(settling: host.view) { host.presentedViewController == nil }
        XCTAssertTrue(dismissed, "閉じる must dismiss the review sheet and keep settings open")
        XCTAssertNotNil(accessibilityElement(in: host.view, label: "はじめの説明をもう一度見る"))
    }

    func testSettingsAtAccessibilitySizeGoesFromListToDetail() async throws {
        let fixture = SettingsFixture(authorization: .denied)
        await fixture.connectRobot()
        defer { fixture.tearDown() }
        let (window, host, _) = try await hostInScene(fixture.view(.conversation).environment(\.dynamicTypeSize, .accessibility5))
        defer { releaseWindow(window) }
        try capture(host.view, size: host.view.bounds.size, name: "settings-maximum-type-list")
        for category in [SettingsCategory.conversation, .cameraAndTracking, .robot] {
            let navigation = try XCTUnwrap(navigationController(in: host))
            XCTAssertEqual(navigation.viewControllers.count, 1, "\(category)")
            try await activateAccessibilityElement(in: host.view, identifier: category.accessibilityIdentifier,
                                                   scrollingIn: firstScrollView(in: host.view))
            let pushed = try await waitForNavigation(navigation, toShow: 2, in: host.view)
            XCTAssertTrue(pushed, "\(category) detail must be pushed from the list")
            let showsBar = try await waitUntil(settling: host.view) { !navigation.isNavigationBarHidden }
            XCTAssertTrue(showsBar, "\(category) detail needs a back button")
            try await scrollThroughDetail(host.view, name: "settings-maximum-type-\(category.rawValue)", sidebarInsets: nil)
            navigation.popViewController(animated: false)
            let popped = try await waitForNavigation(navigation, toShow: 1, in: host.view)
            XCTAssertTrue(popped)
        }
    }

    func testCameraPaneAuthorizationStatesRender() async throws {
        let states: [(FaceCameraAuthorization, String)] = [(.notDetermined, "not-determined"), (.denied, "denied"), (.authorized, "authorized")]
        for (authorization, name) in states {
            let fixture = SettingsFixture(authorization: authorization)
            let (window, host, insets) = try await hostInScene(fixture.view(.cameraAndTracking).environment(\.dynamicTypeSize, .large))
            try await scrollThroughDetail(host.view, name: "settings-camera-\(name)", sidebarInsets: insets)
            releaseWindow(window)
            fixture.tearDown()
        }
    }

    func testConversationShowsOnlyTheFaceAndNeededChips() async throws {
        var listening = ConversationViewState.listening
        listening.caption = "前の返事"
        try await renderConversation(listening, name: "normal") { view in
            try assertFaceFillsEightyPercentBox(in: view, insets: Self.leftIslandInsets)
            XCTAssertNotNil(accessibilityElement(in: view, identifier: "statusChip.listening"))
            XCTAssertNil(accessibilityElement(in: view, label: "前の返事"), "返事は字幕として描かない")
            try assertCatOffersReply("前の返事", in: view)
        }
        try await renderConversation(listening, name: "normal-flipped", insets: Self.rightIslandInsets) { view in
            try assertFaceFillsEightyPercentBox(in: view, insets: Self.rightIslandInsets)
        }

        var long = ConversationViewState.speaking(caption: longCaption)
        long.mouthPose = .closed
        try await renderConversation(long, name: "speaking-long") { view in
            XCTAssertNil(accessibilityElement(in: view, label: longCaption), "長い返事も描かない")
            XCTAssertNil(accessibilityElement(in: view, identifier: "conversationCaption"))
            try assertFaceFillsEightyPercentBox(in: view, insets: Self.leftIslandInsets)
            try assertCatOffersReply(nil, in: view, "話している間は途中の返事を持たせない")
        }
        var provisional = ConversationViewState.listening
        provisional.provisionalTranscript = "ねこちゃん、今日はどんなことがあったか教えて"
        try await renderConversation(provisional, name: "provisional") { view in
            XCTAssertNil(accessibilityElement(in: view, label: provisional.provisionalTranscript), "聞き取り途中の文字は描かない")
        }

        var tapPaused = ConversationViewState.idle
        tapPaused.phase = .paused
        tapPaused.isAwaitingTapToResume = true
        tapPaused.caption = longCaption
        try await renderConversation(tapPaused, name: "user-paused") { view in
            XCTAssertNotNil(accessibilityElement(in: view, identifier: ConversationStatusChip.paused.accessibilityIdentifier))
            XCTAssertNotNil(accessibilityElement(in: view, label: "一時停止中・猫をタップで再開"))
            XCTAssertNil(accessibilityElement(in: view, label: longCaption), "一時停止中も返事は描かない")
            try assertCatOffersReply(longCaption, in: view, "文字で話した返事の後の一時停止でも全文を読める")
        }
        var systemPaused = tapPaused
        systemPaused.isAwaitingTapToResume = false
        try await renderConversation(systemPaused, name: "system-paused") { view in
            assertNoChips(in: view)
        }

        var allChips = ConversationViewState.thinking
        allChips.isLooking = true
        allChips.isRobotReconnecting = true
        allChips.isFaceTrackingPausedForHeat = true
        try await renderConversation(allChips, name: "chips-all") { view in
            try assertChips([.looking, .robotReconnecting, .trackingPausedForHeat], clearTheMenuIn: view, insets: Self.leftIslandInsets)
        }
        try await renderConversation(allChips, name: "largest-standard-type-chips", typeSize: .xxxLarge) { view in
            try assertChips([.looking, .robotReconnecting, .trackingPausedForHeat], clearTheMenuIn: view, insets: Self.leftIslandInsets)
        }

        var notice = ConversationViewState.listening
        notice.memoryNotice = "新しい会話を始めました"
        try await renderConversation(notice, name: "notice") { view in
            let element = try XCTUnwrap(accessibilityElement(in: view, identifier: "memoryNotice"))
            let frame = try accessibilityFrame(of: element, in: view)
            XCTAssertEqual(frame.maxY, view.bounds.height - 18, accuracy: 1, "お知らせは下から18pt")
            XCTAssertEqual(frame.midX, Self.leftIslandInsets.left + (view.bounds.width - Self.leftIslandInsets.left - Self.leftIslandInsets.right) / 2,
                           accuracy: 1)
        }

        var sleeping = ConversationViewState.idle
        sleeping.phase = .paused
        sleeping.inactivity = .sleeping
        sleeping.caption = longCaption
        sleeping.isAwaitingTapToResume = true
        try await renderConversation(sleeping, name: "sleeping") { view in
            XCTAssertNotNil(accessibilityElement(in: view, identifier: ConversationStatusChip.sleeping.accessibilityIdentifier))
            XCTAssertNil(accessibilityElement(in: view, identifier: ConversationStatusChip.paused.accessibilityIdentifier))
            try assertCatOffersReply(nil, in: view, "待機中は返事を持たせない")
        }

        var typed = long
        typed.showsTypedInput = true
        typed.typedText = "送信前の下書き"
        try await renderConversation(typed, name: "typed")
        var unsaved = long
        unsaved.memoryState = .unsaved
        try await renderConversation(unsaved, name: "unsaved")
        var restore = ConversationViewState.idle
        restore.memoryState = .restoreFailed(.readFailed)
        try await renderConversation(restore, name: "restore")
        let failed = ConversationViewState.failed(error: .speechUnrecognized,
            message: "うまく聞き取れませんでした。もう一度話しかけるか、文字で入力してください。",
            recoveries: [.init(title: "もう一度", action: .retry), .init(title: "文字で話す", action: .showTypedInput)])
        try await renderConversation(failed, name: "failed")
        try await renderConversation(long, name: "maximum-type", typeSize: .accessibility5)
        try await renderConversation(typed, name: "maximum-type-typed", typeSize: .accessibility5)
        try await renderConversation(failed, name: "maximum-type-error", typeSize: .accessibility5)
        try await renderConversation(long, name: "high-contrast", highContrast: true)
        // Reduced height models the available viewport; actual keyboard avoidance is device QA.
        try await renderConversation(typed, name: "typed-short-viewport", height: 240)

        for expression in FaceExpression.allCases {
            var expressionState = ConversationViewState.speaking(caption: "こんにちは。今日はどんなことを話そうか？")
            expressionState.heldExpression = expression
            expressionState.mouthPose = .closed
            try await renderConversation(expressionState, name: "expression-" + expression.rawValue)
        }
    }

    /// 文字入力中に一時停止・首の再接続・熱の3つのチップが重なる最悪の組み合わせ。最大の標準文字と、
    /// キーボードで狭くなった高さ（240pt）でも、チップは入力欄と「…」に重ならない。
    func testTypedInputKeepsChipsClearOfTheEditorInAShortViewport() async throws {
        var state = ConversationViewState.idle
        state.phase = .paused
        state.isAwaitingTapToResume = true
        state.caption = longCaption
        state.showsTypedInput = true
        state.typedText = "送信前の下書き"
        state.isRobotReconnecting = true
        state.isFaceTrackingPausedForHeat = true
        let chips: [ConversationStatusChip] = [.paused, .robotReconnecting, .trackingPausedForHeat]
        XCTAssertEqual(state.statusChips, chips)
        try await renderConversation(state, name: "typed-paused-chips-largest-standard-type-short-viewport",
                                     typeSize: .xxxLarge, height: 240) { view in
            try assertChips(chips, clearTheMenuIn: view, insets: Self.leftIslandInsets)
            let editor = try XCTUnwrap(accessibilityElement(in: view, label: "文字で話しかける"), "the typed input is reachable")
            let editorFrame = try accessibilityFrame(of: editor, in: view)
            let title = try XCTUnwrap(accessibilityElement(in: view, label: "文字入力"), "the input card title is reachable")
            let close = try XCTUnwrap(accessibilityElement(in: view, label: "文字入力を閉じる"))
            let titleFrame = try accessibilityFrame(of: title, in: view)
            let closeFrame = try accessibilityFrame(of: close, in: view)
            let inputTop = min(editorFrame.minY, titleFrame.minY, closeFrame.minY)
            XCTAssertTrue(view.bounds.contains(editorFrame), "the editor stays in the viewport")
            XCTAssertTrue(view.bounds.contains(closeFrame), "the close button stays in the viewport")
            // スクロール内容の AX frame は画面外も含むので、上側のスクロール領域で実際に見える部分を測る。
            // 入力欄自身の UIScrollView はカードより下にあるため対象に含めない。
            let contentViewport = allScrollViews(in: view).map { $0.convert($0.bounds, to: view) }
                .first { $0.minY < inputTop && $0.maxY <= inputTop && $0.width > view.bounds.width / 2 }
            for chip in chips {
                let element = try XCTUnwrap(accessibilityElement(in: view, identifier: chip.accessibilityIdentifier), "\(chip)")
                let frame = try accessibilityFrame(of: element, in: view)
                let visible = contentViewport.map { frame.intersection($0) } ?? frame
                if !visible.isNull {
                    XCTAssertLessThanOrEqual(visible.maxY, inputTop, "\(chip) must stay above the entire input card, including its title and close button: \(visible) / inputTop=\(inputTop)")
                }
            }
        }
    }

    func testTypedInputUsesTheRemainingHeightForTheFaceAtStandardSize() async throws {
        var state = ConversationViewState.listening
        state.showsTypedInput = true
        state.typedText = "送信前の下書き"
        var faceHeights: [CGFloat] = []
        for height: CGFloat in [393, 493] {
            try await renderConversation(state, name: "typed-face-size-\(Int(height))", height: height) { view in
                let cat = try XCTUnwrap(accessibilityElement(in: view, identifier: "catListeningToggle"))
                let frame = try accessibilityFrame(of: cat, in: view)
                let chip = try XCTUnwrap(accessibilityElement(in: view, identifier: "statusChip.listening"))
                let chipFrame = try accessibilityFrame(of: chip, in: view)
                let close = try XCTUnwrap(accessibilityElement(in: view, label: "文字入力を閉じる"))
                let inputTop = try accessibilityFrame(of: close, in: view).minY
                XCTAssertGreaterThanOrEqual(frame.minY, chipFrame.maxY)
                XCTAssertLessThanOrEqual(frame.maxY, inputTop)
                faceHeights.append(frame.height)
            }
        }
        // Giving the non-scrolling layout 100pt more room grows the face by 100pt,
        // rather than leaving it at the compact fallback size above the input.
        XCTAssertEqual(faceHeights[1] - faceHeights[0], 100, accuracy: 1)
    }

    private final class TypedEditingState: ObservableObject {
        @Published var value: ConversationViewState
        init() {
            var value = ConversationViewState.idle
            value.phase = .paused
            value.isAwaitingTapToResume = true
            value.showsTypedInput = true
            value.typedText = "送信前の下書き"
            self.value = value
        }
    }

    private struct TypedEditingFixture: View {
        @ObservedObject var model: TypedEditingState
        var onSend: () -> Void = {}
        var body: some View {
            ConversationView(state: model.value, actions: .init(
                toggleListening: {}, showTypedInput: {}, hideTypedInput: {},
                updateTypedText: { model.value.typedText = $0 }, sendTypedText: onSend, performRecovery: { _ in }))
                .environment(\.dynamicTypeSize, .xxxLarge)
                .environment(\.scenePhase, .inactive)
        }
    }

    private func editor(in view: UIView) -> UIView? {
        func candidates(_ node: UIView) -> [UIView] {
            (node is any UITextInput ? [node] : []) + node.subviews.flatMap { candidates($0) }
        }
        let all = candidates(view)
        let visible = all.filter { node in
            let frame = node.convert(node.bounds, to: view)
            guard node.window != nil, !node.isHidden, node.alpha > 0, !frame.isEmpty,
                  view.bounds.contains(frame),
                  let hit = view.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) else { return false }
            return hit === node || hit.isDescendant(of: node)
        }
        XCTAssertEqual(visible.count, 1, "Exactly one editable field is visible and hittable")
        return visible.first
    }

    /// キーボードや警告で利用可能な高さが変わっても、編集中の入力欄・カーソルを作り直さない。
    func testTypedEditorKeepsItsIdentityWhenViewportAndWarningsChange() async throws {
        let model = TypedEditingState()
        // 大きな高さで非スクロール候補を確実に選び、狭い候補との実際の切り替えを検証する。
        let (window, host) = try await hostInWindow(TypedEditingFixture(model: model), insets: Self.leftIslandInsets,
                                                    size: CGSize(width: 852, height: 800))
        defer { releaseWindow(window) }
        let original = try XCTUnwrap(editor(in: host.view), "A UIKit text input must be present")
        let input = try XCTUnwrap(original as? any UITextInput)
        try capture(host.view, size: host.view.bounds.size, name: "typed-editing-before")
        let caret = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 2))
        input.selectedTextRange = input.textRange(from: caret, to: caret)
        model.value.isRobotReconnecting = true
        model.value.isFaceTrackingPausedForHeat = true
        for height: CGFloat in [240, 393] {
            window.frame.size.height = height
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            try await Task.sleep(for: .milliseconds(200))
            settleRendering(host.view)
            XCTAssertEqual(host.view.bounds.height, height)
            XCTAssertEqual(window.bounds.height, height)
            for chip in [ConversationStatusChip.paused, .robotReconnecting, .trackingPausedForHeat] {
                XCTAssertNotNil(accessibilityElement(in: host.view, identifier: chip.accessibilityIdentifier))
            }
            let current = try XCTUnwrap(editor(in: host.view))
            try capture(host.view, size: host.view.bounds.size, name: "typed-editing-height-\(Int(height))")
            XCTAssertTrue(current === original, "Changing height to \(height) must not recreate the active text field")
            let selection = try XCTUnwrap((current as? any UITextInput)?.selectedTextRange)
            let currentInput = try XCTUnwrap(current as? any UITextInput)
            XCTAssertEqual(currentInput.offset(from: currentInput.beginningOfDocument, to: selection.start), 2,
                           "Changing height must preserve the caret")
            XCTAssertEqual(model.value.typedText, "送信前の下書き")
        }
    }

    /// 非同期のエラーや記憶カードが現れたり消えたりしても、編集中の選択範囲を失わない。
    func testTypedEditorKeepsItsSelectionAcrossErrorAndMemoryCards() async throws {
        let model = TypedEditingState()
        model.value.phase = .listening
        model.value.memoryState = .ready
        let (window, host) = try await hostInWindow(TypedEditingFixture(model: model), insets: Self.leftIslandInsets)
        defer { releaseWindow(window) }
        let original = try XCTUnwrap(editor(in: host.view))
        let changes: [(String, String?, ConversationMemoryState)] = [
            ("error-appears", "聞き取りを続けられませんでした", .ready),
            ("error-clears", nil, .ready),
            ("memory-warning-appears", nil, .unsaved),
            ("memory-warning-clears", nil, .ready)
        ]
        for (name, error, memory) in changes {
            let before = try XCTUnwrap(editor(in: host.view) as? any UITextInput)
            let start = try XCTUnwrap(before.position(from: before.beginningOfDocument, offset: 2))
            let end = try XCTUnwrap(before.position(from: before.beginningOfDocument, offset: 4))
            before.selectedTextRange = before.textRange(from: start, to: end)
            model.value.errorMessage = error
            model.value.memoryState = memory
            try await Task.sleep(for: .milliseconds(200))
            settleRendering(host.view)
            let current = try XCTUnwrap(editor(in: host.view))
            let input = try XCTUnwrap(current as? any UITextInput)
            let selection = try XCTUnwrap(input.selectedTextRange)
            XCTAssertTrue(current === original, "\(name) must preserve the active editor")
            XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.start), 2, "\(name)")
            XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.end), 4, "\(name)")
            XCTAssertEqual(model.value.typedText, "送信前の下書き")
            try capture(host.view, size: host.view.bounds.size, name: "typed-card-\(name)")
        }
    }

    func testSendingFromAnErrorKeepsTheEditorUnfocusedWhenTheErrorClears() async throws {
        let model = TypedEditingState()
        model.value.phase = .failed(.speechCaptureFailed)
        model.value.errorMessage = "聞き取りを続けられませんでした"
        var sendCount = 0
        let fixture = TypedEditingFixture(model: model, onSend: {
            sendCount += 1
            model.value.errorMessage = nil
            model.value.phase = .preparing
            model.value.typedText = ""
        })
        let (window, host, _) = try await hostInScene(fixture)
        defer { releaseWindow(window) }
        let original = try XCTUnwrap(editor(in: host.view))
        let focused = try await waitUntil(settling: host.view) { original.isFirstResponder }
        XCTAssertTrue(focused, "The editor must begin focused to exercise Send's focus dismissal")
        try await activateAccessibilityElement(in: host.view, label: "文字を送信")
        let sent = try await waitUntil(settling: host.view) { sendCount == 1 }
        XCTAssertTrue(sent)
        try await Task.sleep(for: .milliseconds(300))
        settleRendering(host.view)
        let current = try XCTUnwrap(editor(in: host.view))
        XCTAssertTrue(current === original, "Clearing the error on Send must keep the same editor")
        XCTAssertFalse(current.isFirstResponder, "Send must dismiss focus without a replacement input taking it back")
        XCTAssertEqual(model.value.typedText, "")
        try capture(host.view, size: host.view.bounds.size, name: "typed-error-send-focus")
    }

    /// 無活動の段階の描画: sleepy の listening、sleeping の paused（字幕・下書きは隠れ、「待機中・タップで起こす」のチップだけが出る）。
    func testInactivityFixturesRender() async throws {
        var sleepyListening = ConversationViewState.listening
        sleepyListening.inactivity = .sleepy
        try await renderConversation(sleepyListening, name: "inactivity-sleepy-listening") { view in
            XCTAssertNotNil(accessibilityElement(in: view, identifier: "statusChip.listening"))
        }

        var sleeping = ConversationViewState.idle
        sleeping.phase = .paused
        sleeping.inactivity = .sleeping
        sleeping.caption = longCaption
        var sleepingTyped = sleeping
        sleepingTyped.showsTypedInput = true
        sleepingTyped.typedText = "送信前の下書き"
        try await renderConversation(sleepingTyped, name: "inactivity-sleeping-typed") { view in
            XCTAssertNotNil(accessibilityElement(in: view, identifier: ConversationStatusChip.sleeping.accessibilityIdentifier))
        }
        try await renderConversation(sleeping, name: "inactivity-sleeping-maximum-type", typeSize: .accessibility5)
        try await renderConversation(sleepingTyped, name: "inactivity-sleeping-typed-maximum-type", typeSize: .accessibility5)
    }

    /// 最初の画面は標準の文字サイズなら横向き1画面に収まり、縦スクロールを使わない。
    func testOnboardingFitsWithoutScrollingAtStandardSize() async throws {
        let (window, host) = try await hostInWindow(OnboardingView(onStart: {}).environment(\.dynamicTypeSize, .large),
                                                    insets: Self.leftIslandInsets)
        defer { releaseWindow(window) }
        try capture(host.view, size: host.view.bounds.size, name: "onboarding-standard")
        if let scroll = firstScrollView(in: host.view) {
            let visibleHeight = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
            XCTAssertLessThanOrEqual(scroll.contentSize.height, visibleHeight + 0.5,
                                     "Onboarding needs vertical scrolling at the standard size")
        }
    }

    /// アクセシビリティ用の大きい文字では1列になり、末尾までスクロールできる。
    func testOnboardingScrollsAtAccessibilitySize() async throws {
        let (window, host) = try await hostInWindow(OnboardingView(onStart: {}).environment(\.dynamicTypeSize, .accessibility5),
                                                    insets: Self.leftIslandInsets)
        defer { releaseWindow(window) }
        let scroll = try XCTUnwrap(firstScrollView(in: host.view))
        XCTAssertTrue(scroll.isScrollEnabled)
        try capture(host.view, size: host.view.bounds.size, name: "onboarding-maximum-type")
        let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        host.view.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
        try capture(host.view, size: host.view.bounds.size, name: "onboarding-maximum-type-scrolled")
    }

    /// UIView の模擬 inset は SwiftUI 内で実際の scene の値に置き換わるため、
    /// fixture はコンテナ由来の safe area を無効にし、SwiftUI の公開 API で左右・下の領域を与える。
    private static let leftIslandInsets = UIEdgeInsets(top: 0, left: 62, bottom: 11, right: 40)
    private static let rightIslandInsets = UIEdgeInsets(top: 0, left: 40, bottom: 11, right: 62)

    private final class MeasuredSafeArea {
        var insets: EdgeInsets?
    }

    private func hostInWindow<V: View>(_ view: V, insets: UIEdgeInsets,
                                       size: CGSize = CGSize(width: 852, height: 393)) async throws -> (UIWindow, UIHostingController<AnyView>) {
        await enableAccessibilityRuntime()
        let measurement = MeasuredSafeArea()
        let fixture = view
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measurement.insets = proxy.safeAreaInsets }
                        .onChange(of: proxy.safeAreaInsets) { _, value in measurement.insets = value }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: insets.left) }
            .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: insets.right) }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: insets.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: insets.bottom) }
        let host = UIHostingController(rootView: AnyView(fixture))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.backgroundColor = .black
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        settleRendering(host.view)
        let measured = try XCTUnwrap(measurement.insets, "SwiftUI must measure the declared safe area")
        XCTAssertEqual(measured.leading, insets.left)
        XCTAssertEqual(measured.trailing, insets.right)
        XCTAssertEqual(measured.top, insets.top)
        XCTAssertEqual(measured.bottom, insets.bottom)
        return (window, host)
    }

    /// 設定は UIKit の NavigationStack を含み、その中の画面は UIKit から実際の scene の safe area を受け取るので、
    /// 模擬の inset を与えられない。シートも scene の無いウィンドウには載らない。そこでアプリの scene に載せた
    /// ウィンドウで、実際の寸法と safe area のまま描き、期待値もその safe area から求める。
    private func hostInScene<V: View>(_ view: V) async throws -> (UIWindow, UIHostingController<V>, UIEdgeInsets) {
        await enableAccessibilityRuntime()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first,
                                  "The test host must provide a window scene")
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        // テストのホストのアプリ自身の画面より前に出す。
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.backgroundColor = .black
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        settleRendering(host.view)
        let insets = host.view.safeAreaInsets
        print("FIXTURE_SCENE size=\(window.bounds.size) safeArea=\(insets)")
        XCTAssertGreaterThan(window.bounds.width, window.bounds.height, "The app runs in landscape only")
        return (window, host, insets)
    }

    /// 設定の fixture が共有する依存。首は接続済み、記憶は3件。
    @MainActor
    private final class SettingsFixture {
        let defaultsName: String
        let harness: RobotLinkHarness
        let robot: RobotSettingsModel
        let camera: ConversationCamera
        let face: FaceTrackingCoordinator
        let memory: LongTermMemoryViewModel
        let voiceSettings: SpeechVoiceSettings
        let modelSettings: ConversationModelSettings
        let idleSettings: ConversationIdleSettings

        init(authorization: FaceCameraAuthorization) {
            let defaultsName = "settings-fixture-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            let harness = RobotLinkHarness()
            self.defaultsName = defaultsName
            self.harness = harness
            robot = RobotSettingsModel(link: harness.link, preferences: harness.preferences, clock: harness.clock)
            camera = ConversationCamera(source: FakeFaceCaptureSource(authorization: authorization), clock: ManualRobotClock())
            face = FaceTrackingCoordinator(source: FakeFaceCaptureSource(authorization: authorization), link: harness.link,
                                           clock: harness.clock, preferences: harness.preferences, motion: MotionControllerSpy())
            let facts = [
                LongTermFact(id: UUID(), category: .preference, text: "甘いものが好きで、特にどら焼きをよく食べる", createdAt: Date(timeIntervalSince1970: 1)),
                LongTermFact(id: UUID(), category: .person, text: "妹のさくらは春に大学へ入学した", createdAt: Date(timeIntervalSince1970: 2)),
                LongTermFact(id: UUID(), category: .event, text: "週末は公園で写真を撮る予定", createdAt: Date(timeIntervalSince1970: 3))
            ]
            memory = LongTermMemoryViewModel(memory: LongTermMemoryManager(store: InMemoryLongTermMemoryStore(facts: facts)))
            voiceSettings = SpeechVoiceSettings(defaults: defaults)
            modelSettings = ConversationModelSettings(defaults: defaults)
            idleSettings = ConversationIdleSettings(defaults: defaults)
        }

        func connectRobot() async { await harness.connectReady() }

        func view(_ category: SettingsCategory) -> ConversationSettingsView {
            ConversationSettingsView(voiceSettings: voiceSettings, modelSettings: modelSettings, memory: memory,
                                     usage: ConversationUsageSpy(), idleSettings: idleSettings, robotSettings: robot,
                                     faceTracking: face, camera: camera, initialCategory: category,
                                     onDeleteAll: {}, onDone: {})
        }

        func tearDown() {
            camera.shutdown()
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
    }

    /// 詳細（右列）の Form を末尾まで送り、各ページを撮る。2列のときは左列 220pt の右にあることも確かめる。
    private func scrollThroughDetail(_ view: UIView, name: String, sidebarInsets: UIEdgeInsets?) async throws {
        // 標準文字では左列はスクロールしないので、最も右にあるスクロールが詳細になる。
        let scroll = try XCTUnwrap(detailScrollView(in: view), "\(name) has no scrollable detail")
        XCTAssertTrue(scroll.isScrollEnabled)
        try capture(view, size: view.bounds.size, name: name)
        if let sidebarInsets {
            // 描画が落ち着いた後の画素で測る。左列は左 safe area から 220pt、詳細のグループは詳細の列の中で左右均等。
            XCTAssertEqual(scroll.convert(scroll.bounds, to: view).minX, sidebarInsets.left + 220, accuracy: 0.5,
                           "\(name): the detail column starts right after the 220pt category column")
            let edges = try XCTUnwrap(settingsColumnEdges(in: view, insets: sidebarInsets),
                                      "\(name): the selected category row or the first group was not found")
            XCTAssertEqual(edges.rowMinX, sidebarInsets.left, accuracy: 1, "\(name): the category column starts at the safe area")
            XCTAssertEqual(edges.rowMaxX, sidebarInsets.left + 220, accuracy: 1, "\(name): the category column is 220pt wide")
            let detailMinX = sidebarInsets.left + 220, safeMaxX = view.bounds.width - sidebarInsets.right
            XCTAssertEqual(edges.groupMinX - detailMinX, safeMaxX - edges.groupMaxX, accuracy: 1,
                           "\(name): the detail groups sit evenly between the category column and the right safe area")
            XCTAssertLessThan(edges.groupMinX - detailMinX, 40, "\(name): the detail is not inset twice")
        }
        // Form estimates off-screen cell heights. Recompute its extent after each scroll.
        var offset: CGFloat = 0
        var stableBottomPasses = 0
        for index in 0..<40 {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(150))
            view.layoutIfNeeded()
            let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            if abs(offset - bottom) < 1 {
                stableBottomPasses += 1
                if stableBottomPasses == 2 { break }
            } else {
                stableBottomPasses = 0
                if index > 0 { try capture(view, size: view.bounds.size, name: "\(name)-page-\(index)") }
            }
            offset = min(bottom, offset + max(1, scroll.bounds.height * 0.75))
        }
        XCTAssertEqual(stableBottomPasses, 2, "\(name) did not reach a stable bottom")
        try capture(view, size: view.bounds.size, name: name + "-bottom")
    }

    /// 設定の2列を画素で測る（scale 1）。選ばれているカテゴリ行（#2C2C2E）の左右端と、詳細の最初のグループ（#1C1C1E）の左右端。
    private func settingsColumnEdges(in view: UIView, insets: UIEdgeInsets)
        -> (rowMinX: CGFloat, rowMaxX: CGFloat, groupMinX: CGFloat, groupMaxX: CGFloat)? {
        guard let cgImage = settleRendering(view).cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func matches(_ x: Int, _ y: Int, _ target: (Int, Int, Int)) -> Bool {
            let i = (y * width + x) * 4
            return abs(Int(pixels[i]) - target.0) <= 7 && abs(Int(pixels[i + 1]) - target.1) <= 7 && abs(Int(pixels[i + 2]) - target.2) <= 7
        }
        /// probeX の縦の並びで target 色が続く最初の帯の中で、上端から offset の y。帯が短すぎれば nil。
        func bandY(probeX: Int, target: (Int, Int, Int), offset: Int) -> Int? {
            guard let top = (0..<height).first(where: { y in (y..<min(height, y + 30)).allSatisfy { matches(probeX, $0, target) } })
            else { return nil }
            return top + offset
        }
        let rowColor = (44, 44, 46), groupColor = (28, 28, 30)
        let rowProbe = Int(insets.left) + 200
        let detailMinX = insets.left + 220
        let groupProbe = Int(detailMinX + 32)
        guard let rowY = bandY(probeX: rowProbe, target: rowColor, offset: 15),
              let groupY = bandY(probeX: groupProbe, target: groupColor, offset: 23) else { return nil }
        // 文字で背景色が途切れても、選択行の左右の端まで測る。
        let rowRange = Int(insets.left)..<Int(insets.left + 220)
        guard let rowMin = rowRange.first(where: { matches($0, rowY, rowColor) }),
              let rowMax = rowRange.last(where: { matches($0, rowY, rowColor) }) else { return nil }
        // グループの中の文字で途切れないよう、左右それぞれ外側から内側へ探す。
        let safeMaxX = Int(view.bounds.width - insets.right)
        guard let groupMinX = (Int(detailMinX)..<safeMaxX).first(where: { matches($0, groupY, groupColor) }),
              let groupMaxX = (Int(detailMinX)..<safeMaxX).last(where: { matches($0, groupY, groupColor) }) else { return nil }
        return (CGFloat(rowMin), CGFloat(rowMax + 1), CGFloat(groupMinX), CGFloat(groupMaxX + 1))
    }

    /// 会話画面を擬似 safe area のウィンドウに置いて撮る。スクロールする配置は末尾も撮る。
    private func renderConversation(_ state: ConversationViewState, name: String, typeSize: DynamicTypeSize = .large,
                                    insets: UIEdgeInsets = FaceConversationPresentationTests.leftIslandInsets,
                                    highContrast: Bool = false, height: CGFloat = 393,
                                    inspect: (UIView) throws -> Void = { _ in }) async throws {
        let view = ConversationView(state: state, actions: .init(
            toggleListening: {}, showTypedInput: {}, hideTypedInput: {}, updateTypedText: { _ in },
            sendTypedText: {}, performRecovery: { _ in }))
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.scenePhase, .inactive)
        let (window, host) = try await hostInWindow(view, insets: insets, size: CGSize(width: 852, height: height))
        defer { releaseWindow(window) }
        if highContrast {
            host.traitOverrides.accessibilityContrast = .high
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        try capture(host.view, size: host.view.bounds.size, name: name)
        try await waitForAccessibilityTree(in: host.view)
        try inspect(host.view)
        if let scroll = firstScrollView(in: host.view), scroll.contentSize.height > scroll.bounds.height {
            XCTAssertTrue(scroll.isScrollEnabled)
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            host.view.layoutIfNeeded()
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
            try capture(host.view, size: host.view.bounds.size, name: name + "-scrolled")
        }
    }

    /// 顔の枠は全画面の80%で、safe area の水平中央・画面の垂直中央にある。猫の絵は縦横比を保ってその枠に収まる。
    private func assertFaceFillsEightyPercentBox(in view: UIView, insets: UIEdgeInsets,
                                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let face = try XCTUnwrap(accessibilityElement(in: view, identifier: "catListeningToggle"), file: file, line: line)
        let frame = try accessibilityFrame(of: face, in: view)
        let box = CGSize(width: view.bounds.width * 0.80, height: view.bounds.height * 0.80)
        XCTAssertEqual(frame.midX, insets.left + (view.bounds.width - insets.left - insets.right) / 2, accuracy: 1,
                       "the face is centered in the safe area", file: file, line: line)
        XCTAssertEqual(frame.midY, view.bounds.midY, accuracy: 1, "the face is centered on the screen", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.width, box.width + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.height, box.height + 1, file: file, line: line)
        XCTAssertTrue(abs(frame.width - box.width) < 1 || abs(frame.height - box.height) < 1,
                      "the face fills the 80% box along one axis: \(frame) in \(box)", file: file, line: line)
    }

    /// 猫（一時停止・再開のボタン）が、最後の返事を VoiceOver の「その他のコンテンツ」（猫の返事）として持つ。nil は持たないこと。
    private func assertCatOffersReply(_ reply: String?, in view: UIView, _ message: String = "",
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let cat = try XCTUnwrap(accessibilityElement(in: view, identifier: "catListeningToggle"), file: file, line: line)
        XCTAssertEqual(accessibilityCustomContent(of: cat), reply.map { ["猫の返事=\($0)"] } ?? [], message, file: file, line: line)
    }

    private func assertNoChips(in view: UIView, file: StaticString = #filePath, line: UInt = #line) {
        for chip in ConversationStatusChip.allCases {
            XCTAssertNil(accessibilityElement(in: view, identifier: chip.accessibilityIdentifier), "\(chip)", file: file, line: line)
        }
    }

    /// チップは左safe area + 16pt から並び、「…」ボタンに重ならない（最大の標準文字では折り返す）。
    private func assertChips(_ chips: [ConversationStatusChip], clearTheMenuIn view: UIView, insets: UIEdgeInsets,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let menu = try XCTUnwrap(accessibilityElement(in: view, identifier: "conversationSettings"), file: file, line: line)
        let menuFrame = try accessibilityFrame(of: menu, in: view)
        for chip in chips {
            let element = try XCTUnwrap(accessibilityElement(in: view, identifier: chip.accessibilityIdentifier), "\(chip)",
                                        file: file, line: line)
            let frame = try accessibilityFrame(of: element, in: view)
            XCTAssertFalse(frame.intersects(menuFrame), "\(chip) overlaps the … button: \(frame) / \(menuFrame)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, insets.left + 16 - 1, "\(chip)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, view.bounds.width - insets.right, "\(chip)", file: file, line: line)
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func capture(_ view: UIView, size: CGSize, name: String) throws {
        let image = settleRendering(view)
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("face-presentation-fixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        print("FACE_PRESENTATION_ARTIFACT: \(directory.path)/\(name).png")
    }
}
