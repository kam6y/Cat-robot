import XCTest
import SwiftUI
@testable import CatRobot

final class ConversationAccessibilityTests: XCTestCase {
    func testCompletedReplyRemainsAvailableOnDemandAfterVoiceAndTypedTurns() {
        // 音声・文字とも speaking → thinking → listening/paused で完了する。
        // speaking → listening の自動アナウンスだけに頼らず、全文を後から読めること。
        for phase: ConversationPhase in [.idle, .listening, .paused, .failed(.cancelled)] {
            var state = ConversationViewState.speaking(caption: "最後まで読める猫の返事。")
            state.phase = phase
            XCTAssertEqual(state.accessibleReply, "最後まで読める猫の返事。", "\(phase)")
        }
    }

    func testReplyIsNotExposedWhileStreamingSleepingOrEmpty() {
        for phase: ConversationPhase in [.preparing, .classifying, .thinking, .speaking, .clarifying] {
            var state = ConversationViewState.speaking(caption: "まだ途中の返事")
            state.phase = phase
            XCTAssertNil(state.accessibleReply, "\(phase)")
        }
        var state = ConversationViewState.listening
        XCTAssertNil(state.accessibleReply)
        state.caption = "前の返事"
        state.inactivity = .sleeping
        XCTAssertNil(state.accessibleReply)
    }

    func testConversationPresentationRequestsVisibleSystemStatus() {
        XCTAssertFalse(ConversationPresentationPolicy.isStatusBarHidden)
    }

    func testPausedControlHasExplicitLabelAndValue() {
        let labels = ConversationAccessibility(phase: .paused)

        XCTAssertEqual(labels.listeningAction, "聞き取りを再開")
        XCTAssertEqual(labels.microphoneValue, "一時停止中")
    }

    func testClarificationIsAvailableWithoutMotion() {
        let labels = ConversationAccessibility(phase: .clarifying)

        XCTAssertEqual(labels.microphoneValue, "一時休止中")
    }

    func testProvisionalTranscriptChangeDoesNotAnnounce() {
        let oldState = ConversationViewState.listening
        var newState = oldState
        newState.provisionalTranscript = "ねこちゃん"

        XCTAssertNil(
            ConversationAnnouncementPolicy.announcement(from: oldState, to: newState)
        )
    }

    func testStreamedSpeakingCaptionDoesNotAnnounceRepeatedly() {
        let oldState = ConversationViewState.speaking(caption: "こん")
        let newState = ConversationViewState.speaking(caption: "こんにちは")

        XCTAssertNil(
            ConversationAnnouncementPolicy.announcement(from: oldState, to: newState)
        )
    }

    func testCompletedSpeakingAnnouncesFinalCaptionOnce() {
        let oldState = ConversationViewState.speaking(caption: "こんにちは")
        var newState = ConversationViewState.listening
        newState.caption = "こんにちは"

        XCTAssertEqual(
            ConversationAnnouncementPolicy.announcement(from: oldState, to: newState),
            "猫の返事。こんにちは"
        )
    }

    func testPausedSpeakingAnnouncesPausedActivityInsteadOfRetainedCaption() {
        let oldState = ConversationViewState.speaking(caption: "こんにちは")
        var newState = oldState
        newState.phase = .paused
        newState.activityStatus = "一時停止しています"

        XCTAssertEqual(
            ConversationAnnouncementPolicy.announcement(from: oldState, to: newState),
            "一時停止しています"
        )
    }

    func testNewErrorAnnouncementIncludesEveryRecoveryTitle() {
        let oldState = ConversationViewState.listening
        let newState = ConversationViewState.failed(
            error: .speechUnrecognized,
            message: "うまく聞き取れませんでした",
            recoveries: [
                .init(title: "もう一度", action: .retry),
                .init(title: "文字で話す", action: .showTypedInput)
            ]
        )

        XCTAssertEqual(
            ConversationAnnouncementPolicy.announcement(from: oldState, to: newState),
            "うまく聞き取れませんでした。利用できる操作。もう一度、文字で話す"
        )
    }

    func testUnchangedErrorDoesNotReplaceANewPhaseAnnouncement() {
        let recoveries = [
            ConversationRecovery(title: "もう一度", action: .retry)
        ]
        let oldState = ConversationViewState.failed(
            error: .speechUnrecognized,
            message: "うまく聞き取れませんでした",
            recoveries: recoveries
        )
        var newState = oldState
        newState.phase = .paused
        newState.activityStatus = "一時停止しています"

        XCTAssertEqual(
            ConversationAnnouncementPolicy.announcement(from: oldState, to: newState),
            "一時停止しています"
        )
    }

    func testOtherPhaseTransitionAnnouncesNewActivity() {
        XCTAssertEqual(
            ConversationAnnouncementPolicy.announcement(from: .listening, to: .thinking),
            "考えています"
        )
    }

    func testResumeStatesShareOneActionSemantic() {
        let resumePhases: [ConversationPhase] = [
            .idle,
            .paused,
            .failed(.cancelled)
        ]

        for phase in resumePhases {
            let labels = ConversationAccessibility(phase: phase)

            XCTAssertEqual(labels.listeningSemantic, .resume)
            XCTAssertEqual(labels.listeningAction, "聞き取りを再開")
            XCTAssertEqual(labels.listeningHint, "マイクの聞き取りを再開します")
        }
    }

    func testListeningUsesPauseActionSemantic() {
        let labels = ConversationAccessibility(phase: .listening)

        XCTAssertEqual(labels.listeningSemantic, .pause)
        XCTAssertEqual(labels.listeningAction, "聞き取りを一時停止")
        XCTAssertEqual(labels.listeningHint, "マイクの聞き取りを停止します")
    }

    func testAccessibilityTypedPanelUsesCompactHorizontalLayout() {
        XCTAssertEqual(
            TypedInputLayout.preferred(for: .accessibility1),
            .compactHorizontal
        )
        XCTAssertEqual(
            TypedInputLayout.preferred(for: .large),
            .standard
        )
    }

    func testSettingsSheetDeclaresItsControls() {
        XCTAssertEqual(ConversationSettingsIdentifier.allCases.map(\.rawValue),
                       ["sleepyMinutesStepper", "sleepingMinutesStepper", "cameraPermissionButton", "modelPicker", "effortPicker", "voicePresetPicker", "dailyTurnLimitStepper", "memoryFactsList", "deleteAllMemoryButton"])
    }
}
