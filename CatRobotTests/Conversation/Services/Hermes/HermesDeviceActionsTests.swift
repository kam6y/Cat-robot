import ImageIO
import XCTest
@testable import CatRobot

@MainActor
final class HermesDeviceActionsTests: XCTestCase {
    func testOrdinarySpeechCannotTriggerActionsAndMalformedControlCannotBeSpoken() throws {
        XCTAssertNil(try HermesDeviceActions.parse("「CAROT_ACTIONS」はどういう意味？"))
        XCTAssertNil(try HermesDeviceActions.parse(#"{"look":true}"#))
        for body in ["", "{}", #"{"look":"yes"}"#, #"{"other":"move"}"#, #"{"look":true} ほかの言葉"#] {
            XCTAssertThrowsError(try HermesDeviceActions.parse("CAROT_ACTIONS\n" + body + "\nこんにちは"))
        }
        XCTAssertThrowsError(try HermesDeviceActions.parse("CAROT_ACTIONS\n" + #"{"express":{"expression":"happy"}}"#),
                             "neck and face need words to ride with")
    }

    /// 3 行目からが話す言葉。look のときは言葉が無くてよく、あっても話さない（履歴にも出さない）。
    func testSpeechFollowsTheTwoControlLines() throws {
        let control = try XCTUnwrap(HermesDeviceActions.parse(
            "CAROT_ACTIONS\n" + #"{"move_head":{"gesture":"nod","intensity":"small"}}"# + "\n  うん。\nそうだね。  "))
        XCTAssertEqual(control.speech, "うん。\nそうだね。")
        XCTAssertEqual(control.actions.moveHead?.gesture, "nod")
        let look = try XCTUnwrap(HermesDeviceActions.parse("CAROT_ACTIONS\n" + #"{"look":true}"#))
        XCTAssertEqual(look.speech, "")
    }

    func testHermesActionsUseSameTurnAndReturnOneJPEG() async throws {
        let motion = MotionControllerSpy(), face = FaceExpressionHarness()
        let camera = ImmediateSnapshotCamera()
        let look = LookCoordinator(camera: camera, clock: SystemRobotClock())
        let tools = RobotConversationToolProvider(motion: motion, expressions: face.sut, look: look)
        let turn = MotionTurnID()
        look.setVisible(true)
        look.beginTurn(turn)
        face.sut.beginTurn(turn)
        let plan = try XCTUnwrap(HermesDeviceActions.parse("""
        CAROT_ACTIONS
        {"look":true,"move_head":{"gesture":"nod","intensity":"small","repeats":2},"express":{"expression":"happy"}}
        """))
        let feedback = try await MotionTurnContext.$current.withValue(turn) { try await tools.perform(plan.actions) }
        XCTAssertEqual(motion.reservations.map(\.turn), [turn])
        XCTAssertEqual(motion.reservations.first?.request, .init(gesture: .nod, intensity: .small, repeats: 2))
        XCTAssertNil(face.sut.heldExpression)
        face.sut.speechStarted(turn)
        XCTAssertEqual(face.sut.heldExpression, .happy)
        XCTAssertEqual(camera.requests, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(feedback.jpeg) as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertTrue(try XCTUnwrap(feedback.cameraMessage).contains("画像を1枚取得"))
    }

    func testNoCaptureWhenOnlyExpressionRequestedOrTurnScopeMissing() async throws {
        let camera = ImmediateSnapshotCamera()
        let look = LookCoordinator(camera: camera, clock: SystemRobotClock())
        let tools = RobotConversationToolProvider(motion: MotionControllerSpy(), look: look)
        let turn = MotionTurnID()
        look.setVisible(true)
        look.beginTurn(turn)
        let plan = try XCTUnwrap(HermesDeviceActions.parse("CAROT_ACTIONS\n{\"express\":{\"expression\":\"sorry\"}}\nごめんね"))
        let feedback = try await MotionTurnContext.$current.withValue(turn) { try await tools.perform(plan.actions) }
        XCTAssertNil(feedback.jpeg)
        let outsideTurn = try XCTUnwrap(HermesDeviceActions.parse("CAROT_ACTIONS\n{\"look\":true}"))
        let rejected = try await tools.perform(outsideTurn.actions)
        XCTAssertNil(rejected.jpeg)
        XCTAssertEqual(rejected.cameraMessage, "この返答では画像を取得できません")
        XCTAssertEqual(camera.requests, 0)
    }
}
