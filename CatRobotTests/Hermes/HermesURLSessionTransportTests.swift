import Foundation
import XCTest
@testable import CatRobot

/// 通常会話の transport: 標準 OS trust、redirect 非追従、https 以外の拒否。URLProtocol の stub でネットワークに触れない。
final class HermesURLSessionTransportTests: XCTestCase {
    private let endpoint = URL(string: "https://hermes.example.test/p/robot")!

    override func tearDown() {
        HermesStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeTransport() -> HermesURLSessionTransport {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [HermesStubURLProtocol.self]
        return HermesURLSessionTransport(sessionConfiguration: session)
    }

    func testServerTrustIsLeftToTheSystemEvaluation() {
        let transport = makeTransport()
        let space = URLProtectionSpace(host: "hermes.example.test", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: ChallengeSenderStub())
        let expectation = expectation(description: "challenge decision")
        transport.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: endpoint), didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling, "no custom anchor, pin or bypass in the normal client")
            XCTAssertNil(credential)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testRedirectsAreNeverFollowedSoTheKeyStaysWithItsOrigin() {
        let transport = makeTransport()
        let redirect = HTTPURLResponse(url: endpoint, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://elsewhere.invalid/"])!
        let expectation = expectation(description: "redirect decision")
        transport.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: endpoint), willPerformHTTPRedirection: redirect,
                             newRequest: URLRequest(url: URL(string: "https://elsewhere.invalid/")!)) { next in
            XCTAssertNil(next)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testRequestsKeepTheProfilePrefixAndReachTheSession() async throws {
        let recorder = RecordedURLRequests()
        HermesStubURLProtocol.install { request in recorder.append(request); return (200, [:], Data("{}".utf8)) }
        let response = try await makeTransport().send(HermesHTTPRequest(method: "GET", url: endpoint.appending(path: "v1/capabilities"),
                                                                        headers: ["Authorization": "Bearer k"], body: nil, timeout: 15))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(recorder.requests.first?.url, URL(string: "https://hermes.example.test/p/robot/v1/capabilities"))
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testStreamAcceptsExactlyOneMiB() async throws {
        let response = try await Self.streamedResponse(at: endpoint.appending(path: "exact"))
        XCTAssertEqual(response.body.count, 1_048_576)
    }

    func testStreamCancelsAnOversizedBodyBeforeEndOfResponse() async {
        let finished = expectation(description: "oversized body rejected without waiting for EOF")
        let stopped = expectation(description: "oversized transfer cancelled")
        HermesStreamingURLProtocol.observeStop(stopped)
        defer { HermesStreamingURLProtocol.observeStop(nil) }
        let url = endpoint.appending(path: "over")
        let task = Task {
            defer { finished.fulfill() }
            do {
                _ = try await Self.streamedResponse(at: url)
                XCTFail("the byte over the limit must be refused")
            } catch {
                XCTAssertEqual(error as? HermesClientError, .transport("response body exceeds 1 MiB"))
            }
        }
        await fulfillment(of: [finished, stopped], timeout: 2)
        task.cancel()
        await task.value
    }

    func testUnauthorizedHeadersCancelAnUnfinishedBody() async {
        await assertUnauthorizedBodyIsCancelled("unauthorized")
    }

    func testUnauthorizedHeadersTakePriorityOverAnOversizedBody() async {
        await assertUnauthorizedBodyIsCancelled("unauthorized-over")
    }

    private func assertUnauthorizedBodyIsCancelled(_ path: String) async {
        let finished = expectation(description: "401 classified without reading the body")
        let stopped = expectation(description: "unread body cancelled")
        HermesStreamingURLProtocol.observeStop(stopped)
        defer { HermesStreamingURLProtocol.observeStop(nil) }
        let url = endpoint.appending(path: path)
        let task = Task {
            defer { finished.fulfill() }
            do {
                let response = try await Self.streamedResponse(at: url)
                XCTAssertEqual(response.statusCode, 401)
                XCTAssertTrue(response.body.isEmpty)
            } catch {
                XCTFail("lost known 401: \(error)")
            }
        }
        await fulfillment(of: [finished, stopped], timeout: 1)
        task.cancel()
        await task.value
    }

    private static func streamedResponse(at url: URL) async throws -> HermesHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesStreamingURLProtocol.self]
        let transport = HermesURLSessionTransport(sessionConfiguration: configuration)
        return try await transport.send(HermesHTTPRequest(method: "GET", url: url,
                                                          headers: [:], body: nil, timeout: 5))
    }

    func testPlainHTTPIsRefusedBeforeAnythingIsSent() async {
        let recorder = RecordedURLRequests()
        HermesStubURLProtocol.install { request in recorder.append(request); return (200, [:], Data()) }
        do {
            _ = try await makeTransport().send(HermesHTTPRequest(method: "GET", url: URL(string: "http://hermes.example.test/v1/runs/x")!,
                                                                 headers: [:], body: nil, timeout: 15))
            XCTFail("plain http must never leave the device")
        } catch {
            XCTAssertEqual(error as? HermesClientError, .insecureEndpoint)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }
}


private final class HermesStreamingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped: XCTestExpectation?

    static func observeStop(_ expectation: XCTestExpectation?) {
        lock.withLock { stopped = expectation }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        let status = path.hasPrefix("unauthorized") ? 401 : 200
        let headers = status == 401 ? ["Content-Type": "application/json", "Content-Length": "2097152"] : nil
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard path != "unauthorized" else { return }
        let chunk = Data(repeating: 0, count: 64 * 1024)
        for _ in 0..<16 { client?.urlProtocol(self, didLoad: chunk) }
        if path == "over" || path == "unauthorized-over" {
            client?.urlProtocol(self, didLoad: Data([0]))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard request.url?.lastPathComponent != "exact" else { return }
        Self.lock.withLock {
            Self.stopped?.fulfill()
            Self.stopped = nil
        }
    }
}
