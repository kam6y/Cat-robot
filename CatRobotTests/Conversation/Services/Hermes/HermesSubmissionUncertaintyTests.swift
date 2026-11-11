import Foundation
import XCTest
@testable import CatRobot

final class HermesSubmissionUncertaintyTests: XCTestCase {
    func testARefusedRetryDoesNotProveTheEarlierLostSubmissionWasNeverAccepted() async throws {
        let server = FakeHermesServer(runs: [.transportFailure, .json(503, #"{"error":{"code":"runtime_draining"}}"#)])
        let records = InMemoryHermesSessionRecordStore()
        let connection = HermesConnection(endpoint: URL(string: "https://hermes.test")!, credential: HermesCredential(apiKey: "test-only"))
        let service = HermesConversationService(connection: { connection }, transport: server, records: records,
                                               clock: SteppingHermesClock(), timing: .init(pollInterval: .seconds(1),
                                                                                         turnDeadline: .seconds(5), submitRetryDelay: .seconds(1)))
        do {
            for try await _ in try await service.streamReply(to: "ねえ") {}
            XCTFail("the reply was not received")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, true, "the 503 describes the retry, not the lost original receipt")
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.body, posts.last?.body)
        XCTAssertEqual(posts.first?.headers["Idempotency-Key"], posts.last?.headers["Idempotency-Key"])
    }
}
