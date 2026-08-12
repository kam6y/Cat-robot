import Foundation
import XCTest
@testable import CatRobot

final class AppIdentityTests: XCTestCase {
    func testIdentityPrivacyCopyAndLandscapeOnlyMetadata() {
        XCTAssertEqual(AppIdentity.displayName, "Cat Robot")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.kamby.CatRobot")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
            "Cat Robotは、この会話画面を開いている間、AIの猫と話すためにマイクを使用します。音声は端末上で処理されます。"
        )

        let orientations = Bundle.main.object(
            forInfoDictionaryKey: "UISupportedInterfaceOrientations"
        ) as? [String]

        XCTAssertEqual(
            Set(orientations ?? []),
            Set([
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ])
        )
    }
}
