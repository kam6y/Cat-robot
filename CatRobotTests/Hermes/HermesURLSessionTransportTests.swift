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
