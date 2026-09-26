import XCTest
@testable import CatRobot
final class SupertonicErrorMapperTests: XCTestCase {
    func testUnavailableAssetsAreDistinguishedFromInferenceFailure() {
        for error in [SupertonicError.missingAssets, .invalidAssets, .unsupportedVoice] {
            XCTAssertEqual(SupertonicErrorMapper.map(error), .speechVoiceUnavailable)
        }
        XCTAssertEqual(SupertonicErrorMapper.map(SupertonicError.inferenceFailed), .speechSynthesisFailed)
    }
}
