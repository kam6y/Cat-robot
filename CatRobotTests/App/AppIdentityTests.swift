import Foundation
import XCTest
@testable import CatRobot

final class AppIdentityTests: XCTestCase {
    func testIdentityPrivacyCopyAndFixedLeftCameraMetadata() {
        // 利用者に見せる名前は CaRot（読みはキャロット）。bundle id など内部の識別子は変えない。
        XCTAssertEqual(ProductName.display, "CaRot")
        XCTAssertEqual(ProductName.spoken, "キャロット")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, ProductName.display)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "CaRot")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleSpokenName") as? String, ProductName.spoken)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.kamby.CatRobot")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
            "CaRotは、この会話画面を開いている間、AIの猫と話すためにマイクを使用します。設定で呼びかけの言葉を声で入力するときも使います。音声は端末上で処理されます。"
        )
        for key in ["NSBluetoothAlwaysUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let reason = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertEqual(reason?.hasPrefix("CaRotは、"), true, key)
        }

        let orientations = Bundle.main.object(
            forInfoDictionaryKey: "UISupportedInterfaceOrientations"
        ) as? [String]

        XCTAssertEqual(
            Set(orientations ?? []),
            Set([
                "UIInterfaceOrientationLandscapeRight"
            ])
        )
    }
}
