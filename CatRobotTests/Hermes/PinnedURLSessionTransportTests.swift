import Foundation
import XCTest
@testable import CatRobot

/// 契約 r3 §2.3: 本番 transport の wire 変換、redirect 非追従、challenge の fail-closed、本文上限、https 以外の拒否。
/// TLS そのものは HermesServerTrustPolicyTests が担い、ここでは URLProtocol の stub でネットワークに触れない。
final class PinnedURLSessionTransportTests: XCTestCase {
    private let endpoint = URL(string: "https://192.168.0.202:18644")!

    override func tearDown() {
        HermesStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeTransport() throws -> PinnedURLSessionTransport {
        let configuration = try HermesProbeConfiguration(endpoint: endpoint, pins: ["00"], deviceID: "sim-1")
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [HermesStubURLProtocol.self]
        return PinnedURLSessionTransport(configuration: configuration, sessionConfiguration: session)
    }

    func testRequestMethodURLHeadersBodyAndTimeoutReachTheSession() async throws {
        let recorder = RecordedURLRequests()
        HermesStubURLProtocol.install { request in
            recorder.append(request)
            return (202, ["Content-Type": "application/json"], Data(#"{"ok":true}"#.utf8))
        }
        let transport = try makeTransport()
        let request = HermesHTTPRequest(method: "POST", url: endpoint.appending(path: "v1/runs"),
                                        headers: ["Authorization": "Bearer k", "Content-Type": "application/json", "Idempotency-Key": "abc"],
                                        body: Data(#"{"input":"x"}"#.utf8), timeout: 15)
        let response = try await transport.send(request)

        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url, URL(string: "https://192.168.0.202:18644/v1/runs"))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Idempotency-Key"), "abc")
        XCTAssertEqual(sent.bodyBytes, Data(#"{"input":"x"}"#.utf8))
        XCTAssertEqual(sent.timeoutInterval, 15)
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
    }

    func testNon2xxResponsesAreReturnedNotThrown() async throws {
        HermesStubURLProtocol.install { _ in (503, [:], Data("{}".utf8)) }
        let transport = try makeTransport()
        let response = try await transport.send(HermesHTTPRequest(method: "GET", url: endpoint.appending(path: "v1/capabilities"),
                                                                  headers: [:], body: nil, timeout: 15))
        XCTAssertEqual(response.statusCode, 503, "status mapping is the client's job, not the transport's")
    }

    func testRedirectResponsesAreNeverFollowed() throws {
        let transport = try makeTransport()
        let task = URLSession.shared.dataTask(with: endpoint)
        let redirect = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 302, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Location": "https://attacker.invalid/"]))
        let expectation = expectation(description: "redirect decision")
        transport.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                             newRequest: URLRequest(url: URL(string: "https://attacker.invalid/")!)) { next in
            XCTAssertNil(next, "the 3xx is handed back as the response; the new location is never requested")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testServerTrustChallengeWithoutATrustObjectIsCancelled() throws {
        let transport = try makeTransport()
        let challenge = makeChallenge(method: NSURLAuthenticationMethodServerTrust)
        let expectation = expectation(description: "challenge decision")
        transport.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: endpoint), didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testOtherAuthenticationMethodsUseDefaultHandlingSoA401StaysObservable() throws {
        let transport = try makeTransport()
        let challenge = makeChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let expectation = expectation(description: "challenge decision")
        transport.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: endpoint), didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling)
            XCTAssertNil(credential)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testBodiesOverOneMebibyteAreRejected() async throws {
        HermesStubURLProtocol.install { _ in (200, [:], Data(count: 1_048_577)) }
        let transport = try makeTransport()
        let request = HermesHTTPRequest(method: "GET", url: endpoint.appending(path: "v1/capabilities"), headers: [:], body: nil, timeout: 15)
        do {
            _ = try await transport.send(request)
            XCTFail("1 MiB + 1 byte must be refused")
        } catch {
            guard case .transport = (error as? HermesProbeError) else { return XCTFail("unexpected error \(error)") }
        }
        HermesStubURLProtocol.install { _ in (200, [:], Data(count: 1_048_576)) }
        let response = try await transport.send(request)
        XCTAssertEqual(response.body.count, 1_048_576, "exactly 1 MiB is still accepted")
    }

    func testHTTPURLsAreRefusedBeforeAnythingIsSent() async throws {
        let recorder = RecordedURLRequests()
        HermesStubURLProtocol.install { request in recorder.append(request); return (200, [:], Data()) }
        let transport = try makeTransport()
        do {
            _ = try await transport.send(HermesHTTPRequest(method: "GET", url: URL(string: "http://192.168.0.202:18644/v1/capabilities")!,
                                                           headers: [:], body: nil, timeout: 15))
            XCTFail("plain http must never leave the device")
        } catch {
            XCTAssertEqual(error as? HermesProbeError, .insecureEndpoint)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    // MARK: - helpers

    private func makeChallenge(method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "192.168.0.202", port: 18644, protocol: "https", realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                          failureResponse: nil, error: nil, sender: ChallengeSenderStub())
    }
}

// MARK: - Test doubles

/// 自前の URLSession に差し込む stub。SDK の経路とは違い、probe の transport は sessionConfiguration を受け取るので差し替えられる。
final class HermesStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    private static func currentHandler() -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler(), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RecordedURLRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; storage.append(request) }
}

final class ChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

extension URLRequest {
    /// URLProtocol に届く request は body が stream に移されていることがある。
    var bodyBytes: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
