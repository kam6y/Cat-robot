import Foundation
import XCTest
@testable import CatRobot

final class RobotProtocolTests: XCTestCase {
    func testMoveIsLittleEndian() throws {
        XCTAssertEqual(
            try RobotProtocol.encode(.move(yawDeci: 200, pitchDeci: -50, speed: 100)),
            Data([0x01, 0xC8, 0, 0xCE, 0xFF, 0x64])
        )
        XCTAssertEqual(
            try RobotProtocol.encode(.move(yawDeci: .min, pitchDeci: .max, speed: 0)),
            Data([1, 0, 0x80, 0xFF, 0x7F, 0])
        )
    }

    func testCommandsMatchFirmwareGoldenBytes() throws {
        let limits = RobotLimits(yawVelocityDeci: 1200, pitchVelocityDeci: 1000,
                                 yawAngleDeci: 600, pitchAngleDeci: 300)
        let fixtures: [(RobotCommand, [UInt8])] = [
            (.gesture(id: 1, ampDeci: 150, repeats: 2, speed: 100), [2, 1, 150, 2, 100]),
            (.gestureAt(id: 1, ampDeci: 150, repeats: 1, speed: 100, yawDeci: -340, pitchDeci: 60),
             [10, 1, 150, 1, 100, 0xAC, 0xFE, 60, 0]),
            (.stop, [3]),
            (.center(speed: 50), [4, 50]),
            (.torque(true), [5, 1]),
            (.torque(false), [5, 0]),
            (.setCalibration(.init(yawOffsetDeci: 25, pitchOffsetDeci: -10, invert: 3)),
             [6, 25, 0, 0xF6, 0xFF, 3]),
            (.saveCalibration(req: 9), [7, 9]),
            (.saveCalibration(req: 255), [7, 255]),
            (.setLimits(limits), [8, 0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1]),
            (.ping(seq: 0xAB), [9, 0xAB])
        ]
        for (command, bytes) in fixtures {
            XCTAssertEqual(try RobotProtocol.encode(command), Data(bytes), "\(command)")
        }
    }

    func testInvalidCommandCannotBeSent() {
        let commands: [RobotCommand] = [
            .gesture(id: 0, ampDeci: 1, repeats: 1, speed: 100),
            .gesture(id: 7, ampDeci: 1, repeats: 1, speed: 100),
            .gestureAt(id: 0, ampDeci: 150, repeats: 1, speed: 100, yawDeci: -340, pitchDeci: 60),
            .gestureAt(id: 7, ampDeci: 150, repeats: 1, speed: 100, yawDeci: -340, pitchDeci: 60),
            .saveCalibration(req: 0),
            .setLimits(.init(yawVelocityDeci: 1200, pitchVelocityDeci: 1000,
                             yawAngleDeci: -1, pitchAngleDeci: 300)),
            .setLimits(.init(yawVelocityDeci: 1200, pitchVelocityDeci: 1000,
                             yawAngleDeci: 600, pitchAngleDeci: -1))
        ]
        for command in commands {
            XCTAssertThrowsError(try RobotProtocol.encode(command)) {
                XCTAssertEqual($0 as? RobotProtocolError, .invalidValue)
            }
        }
    }

    func testStatusSignedAnglesAndSaveSequence() throws {
        let status = try RobotProtocol.decodeStatus(
            Data([0x85, 0xFF, 0x2D, 0, 3, 4, 7, 3, 0, 0, 3, 250])
        )
        XCTAssertEqual(status.yawDeci, -123)
        XCTAssertEqual(status.pitchDeci, 45)
        XCTAssertEqual(status.flags, [.link, .torque, .saveError])
        XCTAssertEqual(status.pingSeq, 7)
        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.voltageCenti, 0)
        XCTAssertEqual(status.rejectedCount, 3)
        XCTAssertEqual(status.saveSeq, 250)
    }

    func testStatusPreservesUnknownFlags() throws {
        let status = try RobotProtocol.decodeStatus(
            Data([0, 0, 0, 0, 0xFC, 0xFB, 255, 5, 0xF4, 1, 0, 0])
        )
        XCTAssertEqual(status.flags.rawValue, 0xFBFC)
        XCTAssertTrue(status.flags.contains(.moving))
        XCTAssertTrue(status.flags.contains(.returning))
        XCTAssertTrue(status.flags.contains(.pairOpen))
        XCTAssertFalse(status.flags.contains(.saveError))
        XCTAssertEqual(status.state, .relaxWait)
        XCTAssertEqual(status.voltageCenti, 500)
    }

    func testUnknownFirmwareStateIsRejected() {
        XCTAssertThrowsError(try RobotProtocol.decodeStatus(
            Data([0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        )) { XCTAssertEqual($0 as? RobotProtocolError, .invalidValue) }
    }

    func testCalibrationReadRetainsSavedAndSignedOffsets() throws {
        let saved = try RobotProtocol.decodeCalibration(Data([0xE7, 0xFF, 10, 0, 2, 1]))
        XCTAssertEqual(saved.values, .init(yawOffsetDeci: -25, pitchOffsetDeci: 10, invert: 2))
        XCTAssertTrue(saved.saved)
        let dirty = try RobotProtocol.decodeCalibration(Data([25, 0, 0xF6, 0xFF, 1, 0]))
        XCTAssertEqual(dirty.values.pitchOffsetDeci, -10)
        XCTAssertFalse(dirty.saved)
    }

    func testLimitsReadMatchesFirmwareGoldenBytes() throws {
        let limits = try RobotProtocol.decodeLimits(Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1]))
        XCTAssertEqual(limits, .init(yawVelocityDeci: 1200, pitchVelocityDeci: 1000,
                                    yawAngleDeci: 600, pitchAngleDeci: 300))
        XCTAssertThrowsError(try RobotProtocol.decodeLimits(Data([0, 0, 0, 0, 0xFF, 0xFF, 0, 0]))) {
            XCTAssertEqual($0 as? RobotProtocolError, .invalidValue)
        }
    }

    func testInfoReadValidatesProtocolAndIgnoresReservedBytes() throws {
        let info = try RobotProtocol.decodeInfo(Data([1, 0, 1, 0, 1, 5, 0xEE, 0xFF]))
        XCTAssertEqual(info, .init(protocolVersion: 1, major: 0, minor: 1, patch: 0,
                                   hardwareID: 1, capabilities: 5))
        XCTAssertThrowsError(try RobotProtocol.decodeInfo(Data([2, 0, 1, 0, 1, 0, 0, 0]))) {
            XCTAssertEqual($0 as? RobotProtocolError, .unsupportedProtocol)
        }
    }

    func testEveryReadRejectsShortAndLongPayloads() {
        let fixtures: [(Int, (Data) throws -> Void)] = [
            (12, { _ = try RobotProtocol.decodeStatus($0) }),
            (6, { _ = try RobotProtocol.decodeCalibration($0) }),
            (8, { _ = try RobotProtocol.decodeLimits($0) }),
            (8, { _ = try RobotProtocol.decodeInfo($0) })
        ]
        for (length, decode) in fixtures {
            for invalidLength in [0, length - 1, length + 1] {
                XCTAssertThrowsError(try decode(Data(repeating: 0, count: invalidLength))) {
                    XCTAssertEqual($0 as? RobotProtocolError, .badLength)
                }
            }
        }
    }

    func testGattAddressesMatchFirmwareService() {
        XCTAssertEqual(RobotProtocol.serviceUUID.uuidString.lowercased(),
                       "c47b0000-6d1f-4b9e-9c9a-2a3b4c5d6e7f")
        let fixtures: [(RobotCharacteristic, String)] = [
            (.command, "c47b0001-6d1f-4b9e-9c9a-2a3b4c5d6e7f"),
            (.status, "c47b0002-6d1f-4b9e-9c9a-2a3b4c5d6e7f"),
            (.calibration, "c47b0003-6d1f-4b9e-9c9a-2a3b4c5d6e7f"),
            (.limits, "c47b0004-6d1f-4b9e-9c9a-2a3b4c5d6e7f"),
            (.info, "c47b0005-6d1f-4b9e-9c9a-2a3b4c5d6e7f")
        ]
        for (characteristic, uuid) in fixtures {
            XCTAssertEqual(characteristic.uuid.uuidString.lowercased(), uuid)
        }
    }
}
