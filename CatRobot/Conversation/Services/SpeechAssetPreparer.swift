import Foundation
import Speech

protocol SpeechAssetInventory: Sendable {
    func isSpeechTranscriberAvailable() async -> Bool
    func equivalentSupportedLocale(to locale: Locale) async -> Locale?
    func installIfNeeded(supporting transcriber: SpeechTranscriber) async throws
    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool
    func reserve(locale: Locale) async throws -> Bool
    func release(reservedLocale: Locale) async -> Bool
}

actor SpeechAssetPreparer {
    private let locale: Locale
    private let inventory: any SpeechAssetInventory
    private var reservedLocale: Locale?

    init(
        locale: Locale = Locale(identifier: "ja-JP"),
        inventory: any SpeechAssetInventory = LiveSpeechAssetInventory()
    ) {
        self.locale = locale
        self.inventory = inventory
    }

    func makePreparedTranscriber() async throws -> SpeechTranscriber {
        guard await inventory.isSpeechTranscriberAvailable() else {
            throw ConversationServiceError.speechAssetsUnavailable
        }
        guard let supportedLocale = await inventory.equivalentSupportedLocale(to: locale) else {
            throw ConversationServiceError.speechLocaleUnsupported
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        do {
            try await inventory.installIfNeeded(supporting: transcriber)
        } catch is CancellationError {
            throw ConversationServiceError.cancelled
        } catch {
            throw ConversationServiceError.speechAssetsUnavailable
        }

        guard await inventory.isInstalled(transcriber) else {
            throw ConversationServiceError.speechAssetsUnavailable
        }

        if reservedLocale == nil,
           (try? await inventory.reserve(locale: supportedLocale)) == true {
            reservedLocale = supportedLocale
        }
        return transcriber
    }

    func releaseReservation() async {
        guard let locale = reservedLocale else { return }
        reservedLocale = nil
        _ = await inventory.release(reservedLocale: locale)
    }
}

private struct LiveSpeechAssetInventory: SpeechAssetInventory {
    func isSpeechTranscriberAvailable() async -> Bool {
        SpeechTranscriber.isAvailable
    }

    func equivalentSupportedLocale(to locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func installIfNeeded(supporting transcriber: SpeechTranscriber) async throws {
        let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        )
        try await request?.downloadAndInstall()
    }

    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool {
        await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    func reserve(locale: Locale) async throws -> Bool {
        try await AssetInventory.reserve(locale: locale)
    }

    func release(reservedLocale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: reservedLocale)
    }
}
