import Foundation
import Speech
import XCTest
@testable import CatRobot

@MainActor
final class AppleServiceCompositionTests: XCTestCase {
    func testAppleServiceCompositionConformsToDomainProtocols() {
        let availability: any ModelAvailabilityChecking =
            FoundationModelAvailabilityService()
        let classifier: any AddressClassifying =
            FoundationModelAddressClassifier()
        let replies: any ReplyGenerating = FoundationModelReplyService()
        let concreteRecognizer = AppleSpeechRecognizer()
        let recognizer: any SpeechRecognizing = concreteRecognizer
        let shutdown: @Sendable () async -> Void = {
            await concreteRecognizer.shutdown()
        }
        let speaker: any SpeechSpeaking = AppleSpeechSynthesizer()
        let audio: any AudioSessionControlling = AppleAudioSessionController()

        _ = (
            availability,
            classifier,
            replies,
            recognizer,
            shutdown,
            speaker,
            audio
        )
    }

    func testServiceTeardownClosureReleasesSpeechReservationOnce() async throws {
        let locale = Locale(identifier: "ja-JP")
        let inventory = CompositionSpeechAssetInventory(locale: locale)
        let driver = CompositionSpeechCaptureDriver()
        let preparer = SpeechAssetPreparer(
            locale: locale,
            inventory: inventory
        )
        let concreteRecognizer = AppleSpeechRecognizer(
            assetPreparer: preparer,
            driverFactory: { driver }
        )
        let recognizer: any SpeechRecognizing = concreteRecognizer
        let shutdown: @Sendable () async -> Void = {
            await concreteRecognizer.shutdown()
        }

        try await recognizer.prepare()
        await shutdown()
        await shutdown()

        let releasedLocales = await inventory.releasedLocales
        XCTAssertEqual(releasedLocales, [locale])
    }
}

private actor CompositionSpeechAssetInventory: SpeechAssetInventory {
    private let locale: Locale
    private(set) var releasedLocales: [Locale] = []

    init(locale: Locale) {
        self.locale = locale
    }

    func isSpeechTranscriberAvailable() async -> Bool { true }

    func equivalentSupportedLocale(to locale: Locale) async -> Locale? {
        self.locale
    }

    func installIfNeeded(
        supporting transcriber: SpeechTranscriber
    ) async throws {}

    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool { true }

    func reserve(locale: Locale) async throws -> Bool { true }

    func release(reservedLocale: Locale) async -> Bool {
        releasedLocales.append(reservedLocale)
        return true
    }
}

private actor CompositionSpeechCaptureDriver: SpeechCaptureDriving {
    func prepare(with transcriber: SpeechTranscriber) async throws {}

    func start(
        onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) async throws {}

    func stop() async throws {}

    func cancel() async {}
}
