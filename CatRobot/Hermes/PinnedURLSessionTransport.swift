#if DEBUG
import Foundation

/// 契約 r3 §2.3 の診断用 transport。probe と DEBUG の実機 live 試験だけが使い、ConversationComposition からは参照しない。
/// request の組み立て・redirect 非追従・1 MiB 上限は通常の transport と同じで、server trust だけを pin + hostname + 期限で判定する。
final class PinnedURLSessionTransport: HermesURLSessionTransport, @unchecked Sendable {
    private let policy: HermesServerTrustPolicy

    init(configuration: HermesProbeConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        policy = HermesServerTrustPolicy(pins: configuration.pins, host: configuration.endpoint.host ?? "")
        super.init(sessionConfiguration: sessionConfiguration)
    }

    override func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
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
