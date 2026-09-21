import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class GemmaAppDeviceTests: XCTestCase {
    func testLiveGemmaClassificationTypedConversationSpeechAndResume() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Gemma app integration requires a physical iPhone.")
#else
        guard ProcessInfo.processInfo.environment["GEMMA_APP_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Run the GemmaAppDeviceTests scheme explicitly.")
        }
        executionTimeAllowance = 600
        let dependencies = ConversationDependencies.live()
        XCTAssertTrue(dependencies.reply is GemmaConversationService)
        XCTAssertTrue(dependencies.classifier is GemmaConversationService)
        XCTAssertTrue(dependencies.modelAvailability is GemmaConversationService)
        let availability = await dependencies.modelAvailability.availability()
        XCTAssertEqual(availability, .available)
        guard availability == .available else { return }
        var records: [[String: Any]] = []
        for (input, expected) in [("猫ちゃん、あなたは何が好き？", AddressTarget.addressed),
                                  ("お母さん、明日のお弁当を作ってください。", .notAddressed),
                                  ("佐藤先生、この問題を教えてください。", .notAddressed),
                                  ("独り言だけど、今日は疲れたな。", .notAddressed),
                                  ("AIのあなたに教えてほしい。猫は何時間寝るの？", .addressed),
                                  ("明日は晴れるかな。", .ambiguous)] {
            let result = try await dependencies.classifier.classify(input)
            records.append(["kind": "classification", "input": input, "result": String(describing: result)])
            XCTAssertEqual(result, expected)
        }
        let viewModel = ConversationViewModel(dependencies: dependencies)
        for prompt in ["私の好きな飲み物は麦茶です。覚えてね。", "訂正です。私が好きなのはほうじ茶です。", "私の好きな飲み物は何？"] {
            let start = ProcessInfo.processInfo.systemUptime
            viewModel.showTypedInput()
            await viewModel.submitTypedText(prompt)
            let state = viewModel.viewState
            records.append(["kind": "typed-with-real-speech", "input": prompt, "caption": state.caption,
                            "phase": String(describing: state.phase),
                            "completionSeconds": ProcessInfo.processInfo.systemUptime - start])
            XCTAssertNil(state.errorMessage, state.errorMessage ?? "")
            XCTAssertFalse(state.caption.isEmpty)
            XCTAssertNotEqual(state.phase, .speaking, "submit must wait for actual speech completion")
        }
        XCTAssertTrue(viewModel.viewState.caption.contains("ほうじ茶"), viewModel.viewState.caption)
        await viewModel.sceneBecameInactive()
        XCTAssertEqual(viewModel.viewState.phase, .paused)
        viewModel.showTypedInput()
        await viewModel.submitTypedText("おかえり、と短く言って。")
        XCTAssertNil(viewModel.viewState.errorMessage)
        XCTAssertTrue(viewModel.viewState.caption.contains("おかえり"))
        records.append(["kind": "resume", "caption": viewModel.viewState.caption])
        let previousCaption = viewModel.viewState.caption
        viewModel.showTypedInput()
        let interrupted = Task {
            await viewModel.submitTypedText(String(repeating: "The garden has green leaves. ", count: 100)
                                           + "猫の長い冒険物語を書いて。")
        }
        // Wait for the real ViewModel to enter generation, then pause during prefill.
        while viewModel.viewState.phase != .thinking { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        await viewModel.sceneBecameInactive()
        await interrupted.value
        XCTAssertEqual(viewModel.viewState.phase, .paused)
        viewModel.showTypedInput()
        await viewModel.submitTypedText("ただいま、と短く言って。")
        XCTAssertNil(viewModel.viewState.errorMessage)
        XCTAssertTrue(viewModel.viewState.caption.contains("ただいま"))
        XCTAssertNotEqual(viewModel.viewState.caption, previousCaption)
        records.append(["kind": "pause-during-generation-and-immediate-resume", "caption": viewModel.viewState.caption])
        await viewModel.shutdown()

        // Cancel a real native stream, drain it via reset, and prove another turn works.
        let stream = try await dependencies.reply.streamReply(to: "猫の冒険物語を長く書いて。")
        let reader = Task {
            for try await _ in stream { throw CancellationError() }
        }
        // After the first snapshot, explicit reset owns cancellation/draining.
        _ = try? await reader.value
        await dependencies.reply.reset()
        var resumed = ""
        for try await snapshot in try await dependencies.reply.streamReply(to: "ひとことで挨拶して。") {
            resumed = snapshot
        }
        XCTAssertFalse(resumed.isEmpty)
        records.append(["kind": "reset-after-partial-stream", "caption": resumed])
        await dependencies.reply.reset()

        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let output = support.appendingPathComponent("GemmaAppDeviceTest", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["runtime": "LiteRT-LM 0.17.1", "records": records],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("results.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Gemma app integration on iPhone"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }
}
