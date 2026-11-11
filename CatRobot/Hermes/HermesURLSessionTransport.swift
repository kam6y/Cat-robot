import Foundation

/// 通常会話の transport。server trust は標準の OS 検証（hostname・期限・信頼済みの CA）に任せる。
/// redirect は追わず（3xx はそのまま応答として返す）、本文は 1 MiB まで、cookie・cache を使わず、https 以外は送らない。
class HermesURLSessionTransport: NSObject, HermesTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBodyBytes = 1_048_576

    private let session: URLSession

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: sessionConfiguration)
        super.init()
    }

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw HermesClientError.insecureEndpoint }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: self)
        } catch {
            throw HermesClientError.transport(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw HermesClientError.transport("non-HTTP response") }
        guard data.count <= Self.maximumBodyBytes else { throw HermesClientError.transport("response body exceeds 1 MiB") }
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
        // 3xx はそのまま応答として返し、新しい場所へは決して要求しない（鍵を別の origin へ送らない）。
        completionHandler(nil)
    }

    /// server trust を含め、認証の判定は OS の既定処理に任せる（自己署名の受け入れや検証の省略はしない）。
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
