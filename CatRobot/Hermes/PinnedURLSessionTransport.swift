#if DEBUG
import Foundation

/// 契約 r3 §2.3 の本番 transport。probe 専用で、ConversationComposition からは参照しない。
/// pin + hostname + 期限で server trust を判定し、redirect は追わず、本文は 1 MiB まで。
final class PinnedURLSessionTransport: NSObject, HermesTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBodyBytes = 1_048_576

    private let policy: HermesServerTrustPolicy
    private let session: URLSession

    init(configuration: HermesProbeConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        policy = HermesServerTrustPolicy(pins: configuration.pins, host: configuration.endpoint.host ?? "")
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: sessionConfiguration)
        super.init()
    }

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw HermesProbeError.insecureEndpoint }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: self)
        } catch {
            throw HermesProbeError.transport(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw HermesProbeError.transport("non-HTTP response") }
        guard data.count <= Self.maximumBodyBytes else { throw HermesProbeError.transport("response body exceeds 1 MiB") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return HermesHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    /// URL・本文・鍵を含めない短い説明。
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 3xx はそのまま応答として返し、新しい場所へは決して要求しない。
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Basic 等は既定処理に任せ、401 を観測できるようにする（資格情報は渡さない）。
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust, policy.evaluate(trust) == .accepted else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
#endif
