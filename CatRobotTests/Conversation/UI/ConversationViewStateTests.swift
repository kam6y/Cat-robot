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
}
