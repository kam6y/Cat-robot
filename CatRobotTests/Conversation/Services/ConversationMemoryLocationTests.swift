import Foundation
import XCTest
@testable import CatRobot

final class ConversationMemoryLocationTests: XCTestCase {
    func testDebugLocationIsIsolatedAndRejectsInvalidIdentifiers() throws {
        let base = URL(fileURLWithPath: "/tmp/support")
        let id = "37211876-71AA-46CB-BDA0-7F65E27D0B55"
        let directory = try ConversationMemoryLocation.directory(applicationSupport: base,
            environment: ["CATROBOT_MEMORY_TEST_ID": id])
        XCTAssertEqual(directory.path, "/tmp/support/CatRobot/DeviceMemoryTests/" + id)
        XCTAssertThrowsError(try ConversationMemoryLocation.directory(applicationSupport: base,
            environment: ["CATROBOT_MEMORY_TEST_ID": "../../ConversationMemory"]))
        let standard = try ConversationMemoryLocation.directory(applicationSupport: base, environment: [:])
        XCTAssertEqual(standard.path, "/tmp/support/CatRobot/ConversationMemory")
    }
}
