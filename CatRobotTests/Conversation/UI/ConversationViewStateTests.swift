import XCTest
@testable import CatRobot

final class ConversationViewStateTests: XCTestCase {
    func testListeningCopySeparatesMicrophoneFromAssistantActivity() {
        let state = ConversationViewState.listening
        XCTAssertEqual(state.microphoneStatus, "端末上で聞き取り中")
        XCTAssertEqual(state.activityStatus, "話しかけてください")
    }

    func testSpeakingStillReportsCaptureAsTemporarilyPaused() {
        let state = ConversationViewState.speaking(caption: "こんにちは")
        XCTAssertEqual(state.microphoneStatus, "返事の間は聞き取りを休止")
        XCTAssertEqual(state.activityStatus, "話しています")
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

        actions.performTypedInput(.show)
        XCTAssertTrue(isPresented)

        actions.performTypedInput(.dismiss)
        XCTAssertFalse(isPresented)

        actions.performRecovery(.showTypedInput)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(recoveredActions, [.showTypedInput])
        XCTAssertEqual(showRequestCount, 1)

        actions.performTypedInput(.send)
        XCTAssertFalse(isPresented)
        XCTAssertEqual(submittedCount, 1)
    }
}
