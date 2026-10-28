import CoreBluetooth
import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class CoreBluetoothRobotTransportTests: XCTestCase {
    func testInitializationDoesNotCreateCentral() {
        var calls = 0
        let transport = CoreBluetoothRobotTransport(makeCentral: { _ in
            calls += 1
            throw NSError(domain: "UnusedFactory", code: 1)
        })
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(transport.canSendWriteWithoutResponse)
    }

    func testBluetoothUsageDescription() {
        let reason = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        XCTAssertFalse(reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        XCTAssertTrue(reason?.contains("Bluetooth") ?? false)
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes"))
    }

    func testAuthenticationFailuresRemainDistinctFromBluetoothPermissionDenial() {
        for code in [CBATTError.insufficientAuthentication, .insufficientAuthorization,
                     .insufficientEncryption, .insufficientEncryptionKeySize] {
            let error = NSError(domain: CBATTErrorDomain, code: code.rawValue)
            XCTAssertEqual(CoreBluetoothRobotTransport.failure(for: error), .authenticationFailed)
        }
        let removed = NSError(domain: CBErrorDomain, code: CBError.peerRemovedPairingInformation.rawValue)
        XCTAssertEqual(CoreBluetoothRobotTransport.failure(for: removed), .authenticationFailed)
        let unknown = NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)
        XCTAssertEqual(CoreBluetoothRobotTransport.failure(for: unknown), .disconnected)
    }
}
