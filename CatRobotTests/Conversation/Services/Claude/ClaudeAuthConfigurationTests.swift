import XCTest
@testable import CatRobot

final class ClaudeAuthConfigurationTests: XCTestCase {
    func testDebugPrefersEnvironmentKeyThenBundledKeyThenClientID() {
        let info: [String: Any] = ["CatRobotClaudeClientID": "clid_abc"]
        XCTAssertEqual(ClaudeAuthConfiguration.resolve(environment: ["ANTHROPIC_API_KEY": "sk-env"], infoDictionary: info,
                                                       bundledKey: "sk-file", isDebugBuild: true), .apiKey("sk-env"))
        XCTAssertEqual(ClaudeAuthConfiguration.resolve(environment: [:], infoDictionary: info,
                                                       bundledKey: " sk-file\n", isDebugBuild: true), .apiKey("sk-file"))
        XCTAssertEqual(ClaudeAuthConfiguration.resolve(environment: [:], infoDictionary: info,
                                                       bundledKey: nil, isDebugBuild: true), .appAttest(clientID: "clid_abc"))
    }

    func testReleaseIgnoresEveryKeySource() {
        let info: [String: Any] = ["CatRobotClaudeClientID": "clid_abc"]
        XCTAssertEqual(ClaudeAuthConfiguration.resolve(environment: ["ANTHROPIC_API_KEY": "sk-env"], infoDictionary: info,
                                                       bundledKey: "sk-file", isDebugBuild: false), .appAttest(clientID: "clid_abc"))
    }

    func testUnexpandedOrEmptyClientIDIsMissing() {
        for value in ["", "$(CATROBOT_CLAUDE_CLIENT_ID)", "not-a-client-id"] {
            XCTAssertEqual(ClaudeAuthConfiguration.resolve(environment: [:], infoDictionary: ["CatRobotClaudeClientID": value],
                                                           bundledKey: nil, isDebugBuild: false), .missing, value)
        }
        XCTAssertNil(ClaudeAuthConfiguration.missing.authMode)
        XCTAssertNotNil(ClaudeAuthConfiguration.apiKey("sk").authMode)
    }
}
