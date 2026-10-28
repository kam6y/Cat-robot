import FoundationModels
import XCTest
@testable import CatRobot

@MainActor
final class LookSessionLifetimeTests: XCTestCase {
    func testImageReplyDiscardsSessionAndNextTurnReceivesOnlyTextMemory() async throws {
        let imageClient = ImageFlagSessionClient(hasImage: true)
        let next = ScriptedSessionClient(chunks: ["次の返答"])
        let factory = StubSessionFactory(scripts: [imageClient, next])
        let store = InMemoryConversationMemoryStore()
        let service = makeClaudeService(factory, store: store)
        _ = try await collect(service.streamReply(to: "見て"))
        _ = try await collect(service.streamReply(to: "続けて"))
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(next.prompts, ["続けて"])
        XCTAssertTrue(sessions.last!.configuration.instructions.contains("利用者: 見て\n猫: 見えた内容"))
        let saved = await store.load()
        let snapshot = try XCTUnwrap(saved)
        XCTAssertEqual(snapshot.turns, [.init(prompt: "見て", response: "見えた内容"),
                                        .init(prompt: "続けて", response: "次の返答")])
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("attachment"))
        XCTAssertFalse(encoded.contains("image"))
    }

    func testTextOnlySessionStaysReusable() async throws {
        let client = ImageFlagSessionClient(hasImage: false)
        let factory = StubSessionFactory(scripts: [client])
        let service = makeClaudeService(factory)
        _ = try await collect(service.streamReply(to: "一回目"))
        _ = try await collect(service.streamReply(to: "二回目"))
        let count = await factory.sessions.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.inner.prompts, ["一回目", "二回目"])
    }

    func testCancelledReplyDuringImageInspectionCannotCommitTextOrReuseSession() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let image = ImageFlagSessionClient(hasImage: true, gate: gate)
        let next = ScriptedSessionClient(chunks: ["次"])
        let factory = StubSessionFactory(scripts: [image, next])
        let store = InMemoryConversationMemoryStore()
        let service = makeClaudeService(factory, store: store)
        let stream = try await service.streamReply(to: "取り消す")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered()
        reader.cancel()
        _ = await reader.result
        await gate.open()
        _ = try await collect(service.streamReply(to: "残す"))
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.map(\.prompt), ["残す"])
        let count = await factory.sessions.count
        XCTAssertEqual(count, 2)
    }

    func testLiveSessionInspectionFindsRealToolImage() async throws {
        let camera = ImmediateSnapshotCamera()
        let look = LookCoordinator(camera: camera, clock: SystemRobotClock())
        look.setVisible(true)
        let turn = MotionTurnID()
        look.beginTurn(turn)
        let session = makeLookSession(look)
        let client = LiveClaudeSessionClient(session: session)
        let before = await client.containsImageAttachments()
        XCTAssertFalse(before)
        _ = try await MotionTurnContext.$current.withValue(turn) {
            try await collect(client.snapshots(for: "見て"))
        }
        let after = await client.containsImageAttachments()
        XCTAssertTrue(after)
        XCTAssertEqual(lookToolImages(session.transcript).count, 1)
        look.reset()
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var result: [String] = []
        for try await item in stream { result.append(item) }
        return result
    }
}

private final class ImageFlagSessionClient: ConversationSessionClient {
    let inner = ScriptedSessionClient(chunks: ["見えた内容"])
    let hasImage: Bool
    let gate: ConversationTestGate?
    init(hasImage: Bool, gate: ConversationTestGate? = nil) { self.hasImage = hasImage; self.gate = gate }
    func prewarm() async {}
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> { await inner.snapshots(for: prompt) }
    func containsImageAttachments() async -> Bool {
        await gate?.wait()
        return hasImage
    }
}
