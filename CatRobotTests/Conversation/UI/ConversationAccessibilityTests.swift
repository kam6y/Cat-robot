import XCTest
import SwiftUI
@testable import CatRobot

final class ConversationAccessibilityTests: XCTestCase {
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
        XCTAssertEqual(labels.assistantStatus, "聞き返しています")
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
            XCTAssertEqual(labels.listeningSymbol, "mic.fill")
            XCTAssertEqual(labels.listeningHint, "マイクの聞き取りを再開します")
        }
    }

    func testListeningUsesPauseActionSemantic() {
        let labels = ConversationAccessibility(phase: .listening)

        XCTAssertEqual(labels.listeningSemantic, .pause)
        XCTAssertEqual(labels.listeningAction, "聞き取りを一時停止")
        XCTAssertEqual(labels.listeningSymbol, "pause.fill")
        XCTAssertEqual(labels.listeningHint, "マイクの聞き取りを停止します")
    }

    func testAccessibilityDynamicTypePrefersStackedLowerControls() {
        XCTAssertEqual(
            ConversationLowerControlsLayout.preferred(
                for: .accessibility1,
                showsTypedInput: false
            ),
            .stacked
        )
        XCTAssertEqual(
            ConversationLowerControlsLayout.preferred(
                for: .large,
                showsTypedInput: false
            ),
            .horizontalFirst
        )
    }

    func testAccessibilityTypedInputUsesCompactFixedControls() {
        XCTAssertEqual(
            ConversationLowerControlsLayout.preferred(
                for: .accessibility1,
                showsTypedInput: true
            ),
            .compactHorizontal
        )
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

    func testKeyboardOrAccessibilityOverflowKeepsPrimaryControlsFixed() {
        XCTAssertEqual(
            ConversationVerticalLayout.preferred(
                for: .large,
                showsTypedInput: true
            ),
            .scrollableContentWithFixedControls
        )
        XCTAssertEqual(
            ConversationVerticalLayout.preferred(
                for: .accessibility1,
                showsTypedInput: false
            ),
            .scrollableContentWithFixedControls
        )
        XCTAssertEqual(
            ConversationVerticalLayout.preferred(
                for: .large,
                showsTypedInput: false
            ),
            .standard
        )
    }
}
