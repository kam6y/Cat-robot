import XCTest
@testable import CatRobot

final class ConversationViewStateTests: XCTestCase {

    func testOnlyListeningShowsAMicrophoneChipDuringOrdinaryConversation() {
        for phase in [ConversationPhase.idle, .preparing, .listening, .thinking, .speaking, .clarifying, .paused] {
            var state = ConversationViewState.listening
            state.phase = phase
            state.caption = "前の返事"
            state.provisionalTranscript = "ねこちゃん"
            XCTAssertEqual(state.statusChips.map(\.title), phase == .listening ? ["聞き取り中"] : [], "\(phase)")
            XCTAssertEqual(state.faceOpacity, 1, "\(phase)")
        }
    }

    func testListeningChipFollowsCaptureAndSuppressesBlockedOrSleepingStates() {
        var state = ConversationViewState.listening
        state.inactivity = .sleepy
        XCTAssertEqual(state.statusChips.map(\.title), ["聞き取り中"])
        state.inactivity = .sleeping
        XCTAssertEqual(state.statusChips.map(\.title), ["待機中・タップで起こす"])
        state.inactivity = .awake
        for memory in [ConversationMemoryState.forgetting, .forgetFailed(.deleteFailed), .restoreFailed(.readFailed)] {
            state.memoryState = memory
            XCTAssertEqual(state.statusChips, [])
        }
        state.memoryState = .unsaved
        state.isRobotReconnecting = true
        XCTAssertEqual(state.statusChips.map(\.title), ["聞き取り中", "ハードを再接続中"])
        state.memoryState = .ready
        state.isRobotReconnecting = false
        for phase in [ConversationPhase.thinking, .speaking, .paused, .failed(.modelBusy), .listening] {
            state.phase = phase
            XCTAssertEqual(state.statusChips.map(\.title), phase == .listening ? ["聞き取り中"] : [])
        }
    }

    func testUserPauseChipNeedsTapPauseThatCanResume() {
        var state = ConversationViewState.idle
        state.phase = .paused
        XCTAssertEqual(state.statusChips, [])
        state.isAwaitingTapToResume = true
        XCTAssertEqual(state.statusChips, [.paused])
        XCTAssertEqual(state.statusChips.map(\.title), ["一時停止中・猫をタップで再開"])
        XCTAssertEqual(state.faceOpacity, 0.5)
        state.memoryState = .unsaved
        XCTAssertTrue(state.showsTapToResume, "保存再試行の通知は猫の再開を妨げない")
        for memory in [ConversationMemoryState.forgetting, .forgetFailed(.deleteFailed), .restoreFailed(.readFailed)] {
            state.memoryState = memory
            XCTAssertEqual(state.statusChips, [], "\(memory)")
            XCTAssertEqual(state.faceOpacity, 1, "\(memory)")
        }
        state.memoryState = .ready
        state.phase = .thinking
        XCTAssertFalse(state.showsTapToResume, "タップ停止後の文字への返答中は一時停止を表示しない")
        XCTAssertEqual(state.faceOpacity, 1)
    }

    func testSleepingSuppressesPauseAndLookButKeepsWarnings() {
        var state = ConversationViewState.idle
        state.phase = .paused
        state.isAwaitingTapToResume = true
        state.isLooking = true
        state.isRobotReconnecting = true
        state.isFaceTrackingPausedForHeat = true
        state.inactivity = .sleeping
        XCTAssertEqual(state.statusChips, [.sleeping, .robotReconnecting, .trackingPausedForHeat])
        XCTAssertEqual(state.statusChips.first?.title, "待機中・タップで起こす")
        XCTAssertEqual(state.faceOpacity, 1)
    }

    func testStatusChipOrderAndCopy() {
        var state = ConversationViewState.thinking
        state.isLooking = true
        state.isRobotReconnecting = true
        state.isFaceTrackingPausedForHeat = true
        XCTAssertEqual(state.statusChips, [.looking, .robotReconnecting, .trackingPausedForHeat])
        XCTAssertEqual(state.statusChips.map(\.title), ["見ています", "ハードを再接続中", "熱のため顔追尾を一時停止"])
        XCTAssertEqual(state.statusChips.map(\.isWarning), [false, true, true])
        XCTAssertEqual(state.statusChips.map(\.accessibilityIdentifier),
                       ["statusChip.looking", "statusChip.robotReconnecting", "statusChip.trackingPausedForHeat"])
    }

    func testHeldExpressionReturnsToLatestPhaseWhenCleared() {
        var state = ConversationViewState.thinking
        XCTAssertEqual(state.faceExpression, .thinking)
        state.heldExpression = .happy
        XCTAssertEqual(state.faceExpression, .happy)
        state.phase = .listening
        XCTAssertEqual(state.faceExpression, .happy)
        state.heldExpression = nil
        XCTAssertEqual(state.faceExpression, .listening)
    }

    func testListeningAsksTheUserToSpeak() {
        let state = ConversationViewState.listening
        XCTAssertEqual(state.activityStatus, "話しかけてください")
    }

    func testSpeakingReportsTheReplyActivity() {
        let state = ConversationViewState.speaking(caption: "こんにちは")
        XCTAssertEqual(state.activityStatus, "話しています")
    }

    func testClarifyingShowsTheFixedQuestionWhileCaptureIsPaused() {
        let state = ConversationViewState.clarifying

        XCTAssertEqual(state.caption, "今の、ぼくに言った？")
        XCTAssertEqual(state.activityStatus, "聞き返しています")
    }

    func testEnteringAPhaseKeepsTheCaptionAndUnsentInput() {
        var state = ConversationViewState.listening
        state.caption = "前の返事"
        state.typedText = "下書き"
        state.provisionalTranscript = "聞き取り中の文"
        state.errorMessage = "失敗"
        state.recoveries = [ConversationRecovery(title: "もう一度", action: .retry)]

        state.enter(.thinking)

        XCTAssertEqual(state.caption, "前の返事")
        XCTAssertEqual(state.typedText, "下書き")
        XCTAssertEqual(state.provisionalTranscript, "聞き取り中の文")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.recoveries, [])
        XCTAssertEqual(state.activityStatus, "考えています")
    }

    func testTypedSubmissionAvailabilityMatchesConversationPhase() {
        let cases: [(ConversationPhase, Bool)] = [
            (.idle, true),
            (.preparing, false),
            (.listening, true),
            (.classifying, false),
            (.clarifying, true),
            (.thinking, false),
            (.speaking, false),
            (.paused, true),
            (.failed(.modelBusy), true)
        ]

        for (phase, expected) in cases {
            var state = ConversationViewState.idle
            state.phase = phase
            XCTAssertEqual(state.allowsTypedSubmission, expected, "Unexpected availability for \(phase)")
        }
    }

    func testTypedInputSendAvailabilityDistinguishesBusyEmptyAndReady() {
        XCTAssertEqual(
            TypedInputSendAvailability(text: "質問", isSubmissionAllowed: false),
            .busy
        )
        XCTAssertEqual(
            TypedInputSendAvailability(text: "  \n", isSubmissionAllowed: true),
            .empty
        )
        XCTAssertEqual(
            TypedInputSendAvailability(text: "質問", isSubmissionAllowed: true),
            .ready
        )
        XCTAssertEqual(TypedInputSendAvailability.busy.accessibilityValue, "猫の返事が終わると送信できます")
        XCTAssertEqual(TypedInputSendAvailability.empty.accessibilityValue, "入力が必要です")
        XCTAssertEqual(TypedInputSendAvailability.ready.accessibilityValue, "送信できます")
    }

    func testFailureCarriesAVisibleNextAction() {
        let state = ConversationViewState.failed(
            error: .modelGenerationFailed,
            message: "準備が必要です",
            recoveries: [.init(title: "もう一度確認", action: .retry)]
        )
        XCTAssertEqual(state.errorMessage, "準備が必要です")
        XCTAssertEqual(state.recoveries.map(\.action), [.retry])
    }

    func testFailurePreservesTheProvidedServiceError() {
        let state = ConversationViewState.failed(
            error: .microphoneDenied,
            message: "マイクへのアクセスを許可してください",
            recoveries: [.init(title: "設定を開く", action: .openSettings)]
        )

        XCTAssertEqual(state.phase, .failed(.microphoneDenied))
    }

    func testTypedInputActionsRoundTripThroughParentPresentationState() {
        var isPresented = false
        var showRequestCount = 0
        var submittedCount = 0
        var recoveredActions: [ConversationRecoveryAction] = []
        let actions = ConversationActions(
            toggleListening: {},
            showTypedInput: {
                showRequestCount += 1
                isPresented = true
            },
            hideTypedInput: { isPresented = false },
            updateTypedText: { _ in },
            sendTypedText: { submittedCount += 1 },
            performRecovery: { action in
                recoveredActions.append(action)
                if action == .showTypedInput {
                    isPresented = true
                }
            }
        )

        actions.showTypedInput()
        XCTAssertTrue(isPresented)

        actions.hideTypedInput()
        XCTAssertFalse(isPresented)

        actions.performRecovery(.showTypedInput)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(recoveredActions, [.showTypedInput])
        XCTAssertEqual(showRequestCount, 1)

        actions.sendTypedText()
        XCTAssertTrue(isPresented)
        XCTAssertEqual(submittedCount, 1)
    }

    func testSpeechMouthSequenceOpensWideOnFirstWordAndCyclesWithoutRepeatingStart() {
        var sequence = SpeechMouthPoseSequence()
        XCTAssertEqual(sequence.nextWordPose(), .wide)
        XCTAssertEqual(sequence.nextWordPose(), .medium)
        XCTAssertEqual(sequence.nextWordPose(), .small)
        XCTAssertEqual(sequence.nextWordPose(), .wide)
    }
}
