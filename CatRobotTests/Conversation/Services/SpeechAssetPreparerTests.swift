import Foundation
import Speech
import XCTest
@testable import CatRobot

final class SpeechAssetPreparerTests: XCTestCase {
    func testUnavailableTranscriberMapsToSpeechAssetsUnavailable() async {
        let inventory = FakeSpeechAssetInventory(isTranscriberAvailable: false)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        do {
            _ = try await preparer.makePreparedTranscriber()
            XCTFail("Expected unavailable SpeechTranscriber support")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechAssetsUnavailable)
        }

        let installCount = await inventory.installCount
        XCTAssertEqual(installCount, 0)
    }

    func testPrepareRejectsUnsupportedJapaneseLocale() async {
        let inventory = FakeSpeechAssetInventory(equivalentLocale: nil)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        do {
            _ = try await preparer.makePreparedTranscriber()
            XCTFail("Expected an unsupported locale error")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechLocaleUnsupported)
        }
    }

    func testPrepareDownloadsWhenRequestExistsThenReservesEquivalentLocale() async throws {
        let supportedLocale = Locale(identifier: "ja-JP")
        let inventory = FakeSpeechAssetInventory(
            equivalentLocale: supportedLocale,
            needsDownload: true
        )
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja_JP"),
            inventory: inventory
        )

        _ = try await preparer.makePreparedTranscriber()

        let downloadCount = await inventory.downloadCount
        let reservedLocales = await inventory.reservedLocales
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(reservedLocales, [supportedLocale])
    }

    func testInstalledStatusIsRequiredAfterInstallation() async {
        let inventory = FakeSpeechAssetInventory(isInstalled: false)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        do {
            _ = try await preparer.makePreparedTranscriber()
            XCTFail("Expected missing installed assets")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechAssetsUnavailable)
        }

        let reservedLocales = await inventory.reservedLocales
        XCTAssertTrue(reservedLocales.isEmpty)
    }

    func testInstallationCancellationMapsToCancelled() async {
        let inventory = FakeSpeechAssetInventory(installFailure: .cancelled)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        do {
            _ = try await preparer.makePreparedTranscriber()
            XCTFail("Expected installation cancellation")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .cancelled)
        }
    }

    func testInstallationFailureMapsToSpeechAssetsUnavailable() async {
        let inventory = FakeSpeechAssetInventory(installFailure: .unexpected)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        do {
            _ = try await preparer.makePreparedTranscriber()
            XCTFail("Expected installation failure")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechAssetsUnavailable)
        }
    }

    func testReservationErrorDoesNotHideInstalledAssetsOrReleaseUnownedLocale() async throws {
        let inventory = FakeSpeechAssetInventory(reserveFailure: .unexpected)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        _ = try await preparer.makePreparedTranscriber()
        await preparer.releaseReservation()

        let releasedLocales = await inventory.releasedLocales
        XCTAssertTrue(releasedLocales.isEmpty)
    }

    func testFalseReservationDoesNotReleaseUnownedLocale() async throws {
        let inventory = FakeSpeechAssetInventory(reserveResult: false)
        let preparer = SpeechAssetPreparer(
            locale: Locale(identifier: "ja-JP"),
            inventory: inventory
        )

        _ = try await preparer.makePreparedTranscriber()
        await preparer.releaseReservation()

        let releasedLocales = await inventory.releasedLocales
        XCTAssertTrue(releasedLocales.isEmpty)
    }

    func testExplicitReleaseOnlyReleasesSuccessfulReservationOnce() async throws {
        let locale = Locale(identifier: "ja-JP")
        let inventory = FakeSpeechAssetInventory(
            equivalentLocale: locale,
            reserveResult: true
        )
        let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
        _ = try await preparer.makePreparedTranscriber()

        await preparer.releaseReservation()
        await preparer.releaseReservation()

        let releasedLocales = await inventory.releasedLocales
        XCTAssertEqual(releasedLocales, [locale])
    }

    func testReleaseClearsReservationBeforeAwaitingInventory() async throws {
        let locale = Locale(identifier: "ja-JP")
        let inventory = FakeSpeechAssetInventory(
            equivalentLocale: locale,
            reserveResult: true,
            suspendRelease: true
        )
        let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
        _ = try await preparer.makePreparedTranscriber()

        let firstRelease = Task {
            await preparer.releaseReservation()
        }
        await inventory.waitUntilReleaseStarts()

        await preparer.releaseReservation()
        let releaseCountWhileFirstCallIsSuspended = await inventory.releaseCount
        XCTAssertEqual(releaseCountWhileFirstCallIsSuspended, 1)

        await inventory.resumeRelease()
        await firstRelease.value
    }
}

private enum FakeSpeechAssetFailure: Error, Sendable {
    case cancelled
    case unexpected
}

private actor FakeSpeechAssetInventory: SpeechAssetInventory {
    private let isTranscriberAvailableValue: Bool
    private let equivalentLocaleValue: Locale?
    private let needsDownload: Bool
    private let isInstalledValue: Bool
    private let installFailure: FakeSpeechAssetFailure?
    private let reserveResult: Bool
    private let reserveFailure: FakeSpeechAssetFailure?
    private let suspendRelease: Bool

    private(set) var installCount = 0
    private(set) var downloadCount = 0
    private(set) var reservedLocales: [Locale] = []
    private(set) var releasedLocales: [Locale] = []

    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        isTranscriberAvailable: Bool = true,
        equivalentLocale: Locale? = Locale(identifier: "ja-JP"),
        needsDownload: Bool = false,
        isInstalled: Bool = true,
        installFailure: FakeSpeechAssetFailure? = nil,
        reserveResult: Bool = true,
        reserveFailure: FakeSpeechAssetFailure? = nil,
        suspendRelease: Bool = false
    ) {
        isTranscriberAvailableValue = isTranscriberAvailable
        equivalentLocaleValue = equivalentLocale
        self.needsDownload = needsDownload
        isInstalledValue = isInstalled
        self.installFailure = installFailure
        self.reserveResult = reserveResult
        self.reserveFailure = reserveFailure
        self.suspendRelease = suspendRelease
    }

    func isSpeechTranscriberAvailable() async -> Bool {
        isTranscriberAvailableValue
    }

    func equivalentSupportedLocale(to locale: Locale) async -> Locale? {
        equivalentLocaleValue
    }

    func installIfNeeded(supporting transcriber: SpeechTranscriber) async throws {
        installCount += 1
        if let installFailure {
            switch installFailure {
            case .cancelled:
                throw CancellationError()
            case .unexpected:
                throw FakeSpeechAssetFailure.unexpected
            }
        }
        if needsDownload {
            downloadCount += 1
        }
    }

    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool {
        isInstalledValue
    }

    func reserve(locale: Locale) async throws -> Bool {
        if let reserveFailure {
            throw reserveFailure
        }
        guard reserveResult else { return false }
        reservedLocales.append(locale)
        return true
    }

    func release(reservedLocale: Locale) async -> Bool {
        releasedLocales.append(reservedLocale)
        let waiters = releaseStartWaiters
        releaseStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if suspendRelease {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return true
    }

    var releaseCount: Int {
        releasedLocales.count
    }

    func waitUntilReleaseStarts() async {
        guard releasedLocales.isEmpty else { return }
        await withCheckedContinuation { continuation in
            releaseStartWaiters.append(continuation)
        }
    }

    func resumeRelease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
