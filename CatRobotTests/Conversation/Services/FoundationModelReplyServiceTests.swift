import Foundation
import XCTest
@testable import CatRobot

final class FoundationModelReplyServiceTests: XCTestCase {
    func testPrewarmThenStreamUsesOneStatefulClientAndForwardsCumulativeSnapshotsUnchanged() async throws {
        let client = FakeReplyModelClient(
            streams: [
                ["うん", "うん、いいよ。"],
                [" 次", " 次も聞かせて。 "],
            ]
        )
        let factory = FakeReplyClientFactory(queuedClients: [client])
        let service = FoundationModelReplyService(clientFactory: factory.make)

        await service.prewarm()

        let firstStream = try await service.streamReply(to: "いい？")
        let firstSnapshots = try await collect(firstStream)
        let secondStream = try await service.streamReply(to: "続けるね")
        let secondSnapshots = try await collect(secondStream)
        let prewarmCount = await client.prewarmCount
        let prompts = await client.prompts

        XCTAssertEqual(firstSnapshots, ["うん", "うん、いいよ。"])
        XCTAssertEqual(secondSnapshots, [" 次", " 次も聞かせて。 "])
        XCTAssertEqual(prewarmCount, 1)
        XCTAssertEqual(prompts, ["いい？", "続けるね"])
        XCTAssertEqual(factory.creationCount, 1)
    }

    func testResetReplacesClientAndPrewarmsReplacement() async {
        let factory = FakeReplyClientFactory()
        let service = FoundationModelReplyService(clientFactory: factory.make)

        await service.prewarm()
        await service.reset()

        let creationCount = factory.creationCount
        let clients = factory.clients
        XCTAssertEqual(creationCount, 2)
        guard clients.count == 2 else { return }
        let originalPrewarmCount = await clients[0].prewarmCount
        let replacementPrewarmCount = await clients[1].prewarmCount
        XCTAssertEqual(originalPrewarmCount, 1)
        XCTAssertEqual(replacementPrewarmCount, 1)
    }

    func testContextErrorIsReportedWithoutSilentlyRetryingPrompt() async {
        let client = FakeReplyModelClient(failure: .domain(.contextExceeded))
        let service = FoundationModelReplyService(clientFactory: { client })

        do {
            let stream = try await service.streamReply(to: "続き")
            _ = try await collect(stream)
            XCTFail("Expected context exhaustion to throw")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .contextExceeded)
        }

        let prompts = await client.prompts
        XCTAssertEqual(prompts, ["続き"])
    }

    func testUnexpectedClientFailureUsesFoundationModelErrorMapping() async {
        let client = FakeReplyModelClient(failure: .unexpected)
        let service = FoundationModelReplyService(clientFactory: { client })

        do {
            let stream = try await service.streamReply(to: "答えて")
            _ = try await collect(stream)
            XCTFail("Expected model generation to throw")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed)
        }
    }

    func testConcurrentReplyIsBusyUntilActiveStreamCompletesThenNextReplyCanStart() async throws {
        let client = FakeReplyModelClient(
            behaviors: [
                .waiting,
                .snapshots(["次の返事"]),
            ]
        )
        let service = FoundationModelReplyService(clientFactory: { client })

        let activeStream = try await service.streamReply(to: "最初")
        do {
            _ = try await service.streamReply(to: "重複")
            XCTFail("Expected a concurrent reply to be rejected")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelBusy)
        }

        await client.finishWaiting(with: ["返事"])
        let activeSnapshots = try await collect(activeStream)
        let nextStream = try await service.streamReply(to: "次")
        let nextSnapshots = try await collect(nextStream)
        let prompts = await client.prompts

        XCTAssertEqual(activeSnapshots, ["返事"])
        XCTAssertEqual(nextSnapshots, ["次の返事"])
        XCTAssertEqual(prompts, ["最初", "次"])
    }

    func testFailureClearsBusyStateForTheNextReply() async throws {
        let client = FakeReplyModelClient(
            behaviors: [
                .failure(.domain(.contextExceeded)),
                .snapshots(["新しい会話"]),
            ]
        )
        let service = FoundationModelReplyService(clientFactory: { client })

        do {
            let failedStream = try await service.streamReply(to: "長すぎる会話")
            _ = try await collect(failedStream)
            XCTFail("Expected context exhaustion to throw")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .contextExceeded)
        }

        let nextStream = try await service.streamReply(to: "リセット後")
        let snapshots = try await collect(nextStream)
        XCTAssertEqual(snapshots, ["新しい会話"])
    }

    func testCancellingConsumerCancelsClientStreamAndClearsBusyState() async throws {
        let client = FakeReplyModelClient(
            behaviors: [
                .waiting,
                .snapshots(["再開できた"]),
            ]
        )
        let service = FoundationModelReplyService(clientFactory: { client })
        let activeStream = try await service.streamReply(to: "待って")
        let consumer = Task {
            do {
                for try await _ in activeStream {}
            } catch {
                // The cancelled consumer only needs to release the active stream.
            }
        }

        await Task.yield()
        consumer.cancel()
        await consumer.value

        var cancellationReachedClient = false
        for _ in 0..<1_000 {
            let cancellationCount = await client.cancellationCount
            if cancellationCount == 1 {
                cancellationReachedClient = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(cancellationReachedClient)

        var resumedStream: AsyncThrowingStream<String, Error>?
        for _ in 0..<1_000 where resumedStream == nil {
            do {
                resumedStream = try await service.streamReply(to: "もう一度")
            } catch ConversationServiceError.modelBusy {
                await Task.yield()
            } catch {
                XCTFail("Unexpected error while waiting for cancellation cleanup: \(error)")
                break
            }
        }

        let stream = try XCTUnwrap(resumedStream)
        let snapshots = try await collect(stream)
        XCTAssertEqual(snapshots, ["再開できた"])
    }
}

private func collect(
    _ stream: AsyncThrowingStream<String, Error>
) async throws -> [String] {
    var snapshots: [String] = []
    for try await snapshot in stream {
        snapshots.append(snapshot)
    }
    return snapshots
}

private enum FakeReplyModelError: Error, Sendable {
    case unexpected
}

private enum FakeReplyFailure: Sendable {
    case domain(ConversationServiceError)
    case unexpected
}

private actor FakeReplyModelClient: ReplyModelClient {
    enum Behavior: Sendable {
        case snapshots([String])
        case failure(FakeReplyFailure)
        case waiting
    }

    private var behaviors: [Behavior]
    private var waitingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private(set) var prewarmCount = 0
    private(set) var prompts: [String] = []
    private(set) var cancellationCount = 0

    init(streams: [[String]]) {
        behaviors = streams.map(Behavior.snapshots)
    }

    init(failure: FakeReplyFailure) {
        behaviors = [.failure(failure)]
    }

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func prewarm() {
        prewarmCount += 1
    }

    func snapshots(for prompt: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        switch behaviors.removeFirst() {
        case .snapshots(let snapshots):
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        case .failure(.domain(let error)):
            continuation.finish(throwing: error)
        case .failure(.unexpected):
            continuation.finish(throwing: FakeReplyModelError.unexpected)
        case .waiting:
            waitingContinuation = continuation
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.recordCancellation() }
            }
        }

        return stream
    }

    func finishWaiting(with snapshots: [String] = []) {
        guard let continuation = waitingContinuation else { return }
        waitingContinuation = nil
        for snapshot in snapshots {
            continuation.yield(snapshot)
        }
        continuation.finish()
    }

    private func recordCancellation() {
        cancellationCount += 1
        waitingContinuation = nil
    }
}

private final class FakeReplyClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedClients: [FakeReplyModelClient]
    private var storedClients: [FakeReplyModelClient] = []

    init(queuedClients: [FakeReplyModelClient] = []) {
        self.queuedClients = queuedClients
    }

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedClients.count
    }

    var clients: [FakeReplyModelClient] {
        lock.lock()
        defer { lock.unlock() }
        return storedClients
    }

    func make() -> any ReplyModelClient {
        lock.lock()
        let client: FakeReplyModelClient
        if queuedClients.isEmpty {
            client = FakeReplyModelClient(streams: [])
        } else {
            client = queuedClients.removeFirst()
        }
        storedClients.append(client)
        lock.unlock()
        return client
    }
}
