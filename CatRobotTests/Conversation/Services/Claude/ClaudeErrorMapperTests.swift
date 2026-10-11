import ClaudeForFoundationModels
import Foundation
import FoundationModels
import Network
import XCTest
@testable import CatRobot

final class ClaudeErrorMapperTests: XCTestCase {
    func testAuthenticationErrorsBecomeAvailabilityFailures() {
        XCTAssertEqual(ClaudeErrorMapper.map(ClaudeError.missingCredential), .modelUnavailable(.claudeCredentialMissing))
        XCTAssertEqual(ClaudeErrorMapper.map(ClaudeError.attestationUnsupported), .modelUnavailable(.claudeAttestationUnsupported))
        XCTAssertEqual(ClaudeErrorMapper.map(ClaudeError.attestationFailed), .modelUnavailable(.claudeAttestationFailed))
        XCTAssertEqual(ClaudeErrorMapper.availability(ClaudeError.attestationFailed), .claudeAttestationFailed)
        XCTAssertEqual(ClaudeErrorMapper.availability(URLError(.notConnectedToInternet)), .claudeUnreachable)
    }

    func testTransientNetworkFailuresAreUnreachable() {
        XCTAssertEqual(ClaudeErrorMapper.map(URLError(.notConnectedToInternet)), .modelUnreachable)
        XCTAssertEqual(ClaudeErrorMapper.map(LanguageModelError.timeout(.init(debugDescription: "t"))), .modelUnreachable)
        XCTAssertEqual(ClaudeErrorMapper.map(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "r"))), .modelUnreachable)
    }

    func testContextRefusalAndCancellationKeepExistingSemantics() {
        XCTAssertEqual(ClaudeErrorMapper.map(LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: "c"))), .contextExceeded)
        XCTAssertEqual(ClaudeErrorMapper.map(LanguageModelError.refusal(.init(explanation: "e", debugDescription: "r"))), .refusal)
        XCTAssertEqual(ClaudeErrorMapper.map(LanguageModelError.guardrailViolation(.init(debugDescription: "g"))), .guardrailViolation)
        XCTAssertEqual(ClaudeErrorMapper.map(CancellationError()), .cancelled)
        XCTAssertEqual(ClaudeErrorMapper.map(ConversationServiceError.inputTooLong), .inputTooLong)
    }

    func testUnknownErrorsFallBackToGenerationFailure() {
        struct Odd: Error {}
        XCTAssertEqual(ClaudeErrorMapper.map(Odd()), .modelGenerationFailed)
    }

    func testFoundationMapperPassesServiceErrorsThrough() {
        XCTAssertEqual(FoundationModelErrorMapper.map(ConversationServiceError.modelUnreachable), .modelUnreachable)
    }

    // MARK: 端末内モデルへ切り替えてよい失敗（FR-LLM-4）

    func testOnlyUnreachableAndGenericGenerationFailuresAllowOnDeviceFallback() {
        let expectations: [(ConversationServiceError, Bool)] = [
            (.modelUnreachable, true),
            (.modelGenerationFailed, true),
            (.modelUnavailable(.claudeCredentialMissing), false),
            (.modelUnavailable(.claudeAttestationUnsupported), false),
            (.modelUnavailable(.claudeAttestationFailed), false),
            (.modelUnavailable(.claudeUnreachable), false),
            (.modelUnavailable(.deviceNotEligible), false),
            (.modelLocaleUnsupported, false),
            (.modelAssetsUnavailable, false),
            (.guardrailViolation, false),
            (.refusal, false),
            (.contextExceeded, false),
            (.inputTooLong, false),
            (.modelBusy, false),
            (.cancelled, false),
            (.microphoneDenied, false),
            (.speechAssetsUnavailable, false),
            (.speechLocaleUnsupported, false),
            (.speechUnrecognized, false),
            (.speechCaptureFailed, false),
            (.speechCaptureAlreadyRunning, false),
            (.speechVoiceUnavailable, false),
            (.speechSynthesisFailed, false),
            (.audioSessionFailed, false),
        ]
        for (error, allowed) in expectations {
            XCTAssertEqual(error.allowsOnDeviceFallback, allowed, "\(error)")
        }
    }

    // MARK: 実際のクライアント経路（127.0.0.1 の固定応答サーバ。外部ネットワークには出ない）

    /// 529/429 はパッケージが `LanguageModelError.rateLimited` に型付けする。500/502/503 はパッケージ内部の `APIError` のまま届き、
    /// 公開 API では種別を見分けられないので `.modelGenerationFailed` に写る。どちらも端末内モデルへの切り替え対象（FR-LLM-4）。
    func testServerSideFailuresFromTheRealClientAllowOnDeviceFallback() async throws {
        for status in [529, 429] {
            let error = try await failureFromStubbedClaude(status: status, body: Data())
            XCTAssertEqual(ClaudeErrorMapper.map(error), .modelUnreachable, "HTTP \(status)")
            XCTAssertTrue(ClaudeErrorMapper.map(error).allowsOnDeviceFallback, "HTTP \(status)")
        }
        let apiError = #"{"type":"error","error":{"type":"api_error","message":"internal"}}"#
        for (status, body) in [(500, ""), (500, apiError), (502, "<html>bad gateway</html>"), (503, "")] {
            let error = try await failureFromStubbedClaude(status: status, body: Data(body.utf8))
            let failure = ClaudeErrorMapper.map(error)
            XCTAssertEqual(failure, .modelGenerationFailed, "HTTP \(status) \(body)")
            XCTAssertTrue(failure.allowsOnDeviceFallback, "HTTP \(status) \(body)")
            XCTAssertEqual(ClaudeErrorMapper.availability(error), .claudeUnreachable, "HTTP \(status) \(body)")
        }
    }

    /// 認証・文脈超過はパッケージが型付けするので、意味を保ったまま切り替え対象外。400/403/404 は設定・権限・不正要求の失敗だが、
    /// 0.2.3 の公開 API では 5xx と区別できず、同じ `.modelGenerationFailed`（切り替え対象）になる（FR-LLM-4 に制約として明記）。
    func testClientSideFailuresFromTheRealClientKeepTheirSemantics() async throws {
        let unauthorized = try await failureFromStubbedClaude(status: 401, body: Data())
        XCTAssertEqual(ClaudeErrorMapper.map(unauthorized), .modelUnavailable(.claudeCredentialMissing))
        XCTAssertFalse(ClaudeErrorMapper.map(unauthorized).allowsOnDeviceFallback)
        XCTAssertEqual(ClaudeErrorMapper.availability(unauthorized), .claudeCredentialMissing)

        let tooLarge = try await failureFromStubbedClaude(status: 413, body: Data())
        XCTAssertEqual(ClaudeErrorMapper.map(tooLarge), .contextExceeded)
        XCTAssertFalse(ClaudeErrorMapper.map(tooLarge).allowsOnDeviceFallback)
        let contextMessage = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long for the context window"}}"#
        let context = try await failureFromStubbedClaude(status: 400, body: Data(contextMessage.utf8))
        XCTAssertEqual(ClaudeErrorMapper.map(context), .contextExceeded)

        let permission = #"{"type":"error","error":{"type":"permission_error","message":"no"}}"#
        let invalid = #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#
        for (status, body) in [(403, permission), (404, ""), (400, invalid)] {
            let error = try await failureFromStubbedClaude(status: status, body: Data(body.utf8))
            let failure = ClaudeErrorMapper.map(error)
            XCTAssertEqual(failure, .modelGenerationFailed, "HTTP \(status)")
            XCTAssertTrue(failure.allowsOnDeviceFallback, "HTTP \(status): 0.2.3 では 5xx と区別できない（既知の代償）")
        }
    }

    private func failureFromStubbedClaude(status: Int, body: Data) async throws -> any Error {
        let responder = try LoopbackHTTPResponder(status: status, body: body)
        let baseURL = try await responder.start()
        defer { responder.stop() }
        let model = ClaudeLanguageModel(name: .haiku5_5, auth: .apiKey("sk-test"), fallbacks: [], baseURL: baseURL, timeout: 5)
        let session = LanguageModelSession(model: model, instructions: "テスト")
        do {
            _ = try await session.respond(to: "hi")
            XCTFail("expected the stubbed HTTP \(status) to fail")
            return ConversationServiceError.modelGenerationFailed
        } catch {
            return error
        }
    }
}

/// 127.0.0.1 の空きポートで固定の HTTP 応答を返す最小サーバ。パッケージは独自の `URLSession` を作るため
/// `URLProtocol.registerClass` では差し替えられず、実経路を通すにはこれが要る。
final class LoopbackHTTPResponder: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPResponder")
    private let status: Int
    private let body: Data

    init(status: Int, body: Data) throws {
        self.status = status
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var data = buffered
            if let chunk { data.append(chunk) }
            if Self.requestIsComplete(data) || isComplete || error != nil {
                self.respond(on: connection)
            } else {
                self.receiveRequest(connection, buffered: data)
            }
        }
    }

    private static func requestIsComplete(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let length = header.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                return Int(value)
            } ?? 0
        return data.count - headerEnd.upperBound >= length
    }

    private func respond(on connection: NWConnection) {
        let head = "HTTP/1.1 \(status) Stub\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nrequest-id: stub\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            // 相手が読み終えて閉じるまで待ってから閉じる（送信直後の cancel で切れないように）。
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in connection.cancel() }
        })
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
