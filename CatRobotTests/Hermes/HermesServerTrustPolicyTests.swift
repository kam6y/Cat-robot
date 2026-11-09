import Foundation
import Security
import XCTest
@testable import CatRobot

/// 契約 r3 §2.3 / §4.1-4: pin → anchor → SSL policy(host, 期限) の順で判定し、どれか 1 つでも欠ければ拒否する。
/// fixture は試験用に生成した自己署名証明書（named-curve P-256、公開情報のみ、鍵は repo に無い）。
/// 期間判定は試験内で固定した verify date（2027-03-01T00:00:00Z）で行い、fixture の実時間での失効に左右されない。
final class HermesServerTrustPolicyTests: XCTestCase {
    /// good / wronghost の有効期間（2026-11-09 〜 2027-09-05）の内側。
    private let fixedVerifyDate = ISO8601DateFormatter().date(from: "2027-03-01T00:00:00Z")!

    // SAN: IP 192.168.0.202, IP 127.0.0.1, DNS localhost。有効 2026-11-09T18:04:51Z 〜 2027-09-05T18:04:51Z（300 日）。
    private let goodPin = "6dba63efa1002a2c8a24a7a8379c2cb674c8892026119a68fa8ea7d3cc582bfc"
    private let goodDER = "MIIBzjCCAXWgAwIBAgIUK3px20I19X/Ydo4PNgvokQzuM/YwCgYIKoZIzj0EAwIwLTErMCkGA1UEAwwiQ2F0Um9ib3QtSGVybWVzLVByb2JlLUZpeHR1cmUtR29vZDAeFw0yNjExMDkxODA0NTFaFw0yNzA5MDUxODA0NTFaMC0xKzApBgNVBAMMIkNhdFJvYm90LUhlcm1lcy1Qcm9iZS1GaXh0dXJlLUdvb2QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASaGRiMWBLHSzSeiTYS0uC0k7o1XkM3LIbGyNivwPlQXbmeVdqed5WU4cMZb4JKBKIV9uXNVfWGPAshaLuyCD2Mo3MwcTAdBgNVHQ4EFgQUEY+6Lruv659ek4JBIhdMYkbUffAwIAYDVR0RBBkwF4cEwKgAyocEfwAAAYIJbG9jYWxob3N0MBMGA1UdJQQMMAoGCCsGAQUFBwMBMAsGA1UdDwQEAwIHgDAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0cAMEQCIG4WgRO3DHYFb8BwLlzFvSxPuMSG8erQxRlaGs91u5euAiA/AbT+y9BstkXgSaeZgL94V57JlQ+Zi+r8CkJQTp1XvQ=="
    // SAN: IP 10.0.0.1, DNS other.invalid。有効期間は good と同じ。
    private let wrongHostPin = "913cb0e763e78222b8e6546f443b44bc802035780c4285aebd4d001e04b4e4ff"
    private let wrongHostDER = "MIIB2DCCAX2gAwIBAgIUY/LjHB5DOZBQp5bLROeP8ZdLDJUwCgYIKoZIzj0EAwIwMjEwMC4GA1UEAwwnQ2F0Um9ib3QtSGVybWVzLVByb2JlLUZpeHR1cmUtV3JvbmdIb3N0MB4XDTI2MTEwOTE4MDQ1MVoXDTI3MDkwNTE4MDQ1MVowMjEwMC4GA1UEAwwnQ2F0Um9ib3QtSGVybWVzLVByb2JlLUZpeHR1cmUtV3JvbmdIb3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEhVB9RsfteUM1DbiyIGE8z5AVQirB8s3n7c4rUlE56DzB+4s9ciuCNWWLJe5lFVvenc47Nm9e5x6vp3047CxotKNxMG8wHQYDVR0OBBYEFDoIO9vnTZAeS0QWThmFnDVhA8b3MB4GA1UdEQQXMBWHBAoAAAGCDW90aGVyLmludmFsaWQwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCwYDVR0PBAQDAgeAMAwGA1UdEwEB/wQCMAAwCgYIKoZIzj0EAwIDSQAwRgIhAKgHuL09ktCis3Y2A5VEDAnq63STI3GKW3MUpb57R+12AiEA1MEOvbroXUe2hwolBsFu/YC1nCG0bupIKS3V/fIzLNU="
    // SAN は good と同じ。有効 2020-01-01 〜 2020-01-02（固定 verify date では期限切れ）。
    private let expiredPin = "1324f384904c45314244123be58ce0a1ee5677ec71d16f01e2831a67b99b53da"
    private let expiredDER = "MIIBtDCCAVmgAwIBAgIUEYFZzAlwsZcFfb20wsUuQvvnyP4wCgYIKoZIzj0EAwIwMDEuMCwGA1UEAwwlQ2F0Um9ib3QtSGVybWVzLVByb2JlLUZpeHR1cmUtRXhwaXJlZDAeFw0yMDAxMDEwMDAwMDBaFw0yMDAxMDIwMDAwMDBaMDAxLjAsBgNVBAMMJUNhdFJvYm90LUhlcm1lcy1Qcm9iZS1GaXh0dXJlLUV4cGlyZWQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARRTJGcbSySoptDvWMDheTANoisU5UEg8u68/sBex1AZ4ldYrc+OtOuib8EHXZRp3HWuPZiWF+e7ZYxl1teg7suo1EwTzAgBgNVHREEGTAXhwTAqADKhwR/AAABgglsb2NhbGhvc3QwCQYDVR0TBAIwADALBgNVHQ8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIzj0EAwIDSQAwRgIhALzkbQigOP6xyk/tvbZ0WJcJ4yHFohbLwZ0yKuOqVb2+AiEAy8mLLVwtBEUCAEQl9ovrtr4VvuxX0YaPFaGpuN2kYF4="

    private func certificate(_ base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    /// サーバーが提示した chain を模した SecTrust。anchor も policy も付けない（評価側が付ける）。期間判定の基準日だけ固定する。
    private func serverTrust(_ base64: String, verifyDate: Date? = nil) throws -> SecTrust {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(try certificate(base64), SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let result = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetVerifyDate(result, (verifyDate ?? fixedVerifyDate) as CFDate), errSecSuccess)
        return result
    }

    func testPinIsTheLowercaseHexSHA256OfTheWholeDER() throws {
        XCTAssertEqual(HermesServerTrustPolicy.pin(of: try certificate(goodDER)), goodPin)
        XCTAssertEqual(HermesServerTrustPolicy.pin(of: try certificate(expiredDER)), expiredPin)
    }

    func testMatchingPinWithValidHostAndDateIsAccepted() throws {
        for host in ["192.168.0.202", "127.0.0.1", "localhost"] {
            let policy = HermesServerTrustPolicy(pins: [goodPin], host: host)
            XCTAssertEqual(policy.evaluate(try serverTrust(goodDER)), .accepted, host)
        }
    }

    func testPinComparisonIgnoresHexCase() throws {
        let policy = HermesServerTrustPolicy(pins: [goodPin.uppercased()], host: "127.0.0.1")
        XCTAssertEqual(policy.evaluate(try serverTrust(goodDER)), .accepted)
    }

    func testWrongPinIsRejectedBeforeAnyTrustEvaluation() throws {
        // 証明書自体は host/期限とも正しい。pin が違うだけで拒否される。
        let policy = HermesServerTrustPolicy(pins: [wrongHostPin, expiredPin], host: "127.0.0.1")
        XCTAssertEqual(policy.evaluate(try serverTrust(goodDER)), .pinMismatch)
    }

    func testHostnameMismatchIsRejectedEvenWithAMatchingPin() throws {
        let policy = HermesServerTrustPolicy(pins: [wrongHostPin], host: "192.168.0.202")
        guard case .rejected = policy.evaluate(try serverTrust(wrongHostDER)) else {
            return XCTFail("SAN {10.0.0.1, other.invalid} must not satisfy 192.168.0.202")
        }
    }

    func testExpiredCertificateIsRejectedEvenWithAMatchingPinAndHost() throws {
        let policy = HermesServerTrustPolicy(pins: [expiredPin], host: "127.0.0.1")
        guard case .rejected = policy.evaluate(try serverTrust(expiredDER)) else {
            return XCTFail("an expired leaf must not be trusted")
        }
    }

    func testNotYetValidCertificateIsRejectedEvenWithAMatchingPinAndHost() throws {
        // good の notBefore（2026-11-09T18:04:51Z）より前の基準日。
        let beforeIssue = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        let policy = HermesServerTrustPolicy(pins: [goodPin], host: "127.0.0.1")
        guard case .rejected = policy.evaluate(try serverTrust(goodDER, verifyDate: beforeIssue)) else {
            return XCTFail("a not-yet-valid leaf must not be trusted")
        }
    }

    func testPinMatchAloneNeverTrustsTheServer() throws {
        // 期限切れ fixture に対し pin と host が共に一致しても accepted にならないこと（pin 一致で trust を飛ばさない）。
        let policy = HermesServerTrustPolicy(pins: [expiredPin, goodPin], host: "localhost")
        XCTAssertNotEqual(policy.evaluate(try serverTrust(expiredDER)), .accepted)
    }
}
