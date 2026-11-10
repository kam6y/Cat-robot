#if DEBUG
import CryptoKit
import Foundation
import Security

enum HermesServerTrustVerdict: Equatable, Sendable {
    case accepted
    /// leaf の pin が一致しない。trust 評価には進まない。
    case pinMismatch
    /// pin は一致したが、hostname / 期限 / 署名のいずれかで評価に失敗した。理由は secret を含まない短文。
    case rejected(String)
}

/// 契約 r3 §2.3: pin → 検証専用 anchor → SSL policy(host) の順。pin 一致だけで trust を飛ばさず、system trust も使わない。
struct HermesServerTrustPolicy: Sendable {
    let pins: Set<String>
    let host: String

    init(pins: [String], host: String) {
        self.pins = Set(pins.map { $0.lowercased() })
        self.host = host
    }

    /// 証明書 DER 全体の SHA-256、小文字 hex。
    static func pin(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    func evaluate(_ trust: SecTrust) -> HermesServerTrustVerdict {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return .rejected("no leaf certificate")
        }
        guard pins.contains(Self.pin(of: leaf)) else { return .pinMismatch }
        // 検証専用 anchor は pin が一致した leaf だけ。system trust は使わない。
        guard SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess else {
            return .rejected("trust configuration failed")
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            // 理由は OSStatus code だけ記録する（説明文に証明書名が入るため）。
            let code = (error as Error?).map { ($0 as NSError).code } ?? 0
            return .rejected("SecTrustEvaluateWithError \(code)")
        }
        return .accepted
    }
}
#endif
