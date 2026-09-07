import Combine
import Foundation
import Observation
import Sparkle

/// Only a correctly configured distribution build participates in its signed feed.
/// Local builds with a different application identity remain independent.
struct HerdrUpdateConfiguration: Equatable {
    let feedURL: URL

    init?(info: [String: Any], bundleIdentifier: String?) {
        guard let expectedID = info["HerdrUpdateBundleIdentifier"] as? String,
              !expectedID.isEmpty, expectedID == bundleIdentifier,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else { return nil }
        feedURL = url
    }
}

/// Sparkle owns download verification, sandboxed installation, and relaunch.
/// Scheduled checks surface a banner; installing always requires user interaction.
@MainActor
@Observable
final class HerdrUpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private(set) var availableVersion: String?
    private(set) var canCheckForUpdates = false
    private(set) var isUpdateSessionInProgress = false
    private(set) var statusMessage: String?
    let isConfigured: Bool
    var automaticallyChecksForUpdates = false {
        didSet {
            if controller?.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }
    var includesPreviewUpdates: Bool {
        didSet {
            defaults.set(includesPreviewUpdates, forKey: Self.previewPreference)
            // Changes apply to the next check. An already displayed update stays
            // available until its Sparkle session ends, so Later never strands it.
            controller?.updater.resetUpdateCycle()
        }
    }

    static let previewPreference = "herdr.updates.includePreview"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let configuration: HerdrUpdateConfiguration?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var didOfferUpdate = false

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = HerdrUpdateConfiguration(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
        isConfigured = configuration != nil
        includesPreviewUpdates = defaults.bool(forKey: Self.previewPreference)
        super.init()
        if !isConfigured {
            statusMessage = "Updates are available in signed release builds."
        }
    }

    func start() {
        guard !didStart, isConfigured else { return }
        // Unit tests must never make release checks or present updater windows.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil,
              !ProcessInfo.processInfo.arguments.contains("-HerdrDemoMode") else { return }
        didStart = true
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }.store(in: &subscriptions)
        controller.updater.publisher(for: \.sessionInProgress, options: [.initial, .new])
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.isUpdateSessionInProgress = value }
            }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates, options: [.initial, .new])
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
            }.store(in: &subscriptions)
        do {
            try controller.updater.start()
        } catch {
            statusMessage = "The updater could not start. Reinstall a signed release to try again."
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        if !isUpdateSessionInProgress { statusMessage = "Checking for updates…" }
        controller?.checkForUpdates(nil)
    }

    func dismissBanner() {
        availableVersion = nil
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesPreviewUpdates ? ["preview"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Ignore any historical Sparkle URL in UserDefaults. The build pins its
        // HTTPS feed and public key together, including for downstream forks.
        configuration?.feedURL.absoluteString
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        didOfferUpdate = true
        statusMessage = "Herdr \(update.displayVersionString) is available."
        if !handleShowingUpdate { availableVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        statusMessage = "Herdr \(update.displayVersionString) is available."
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        if didOfferUpdate || statusMessage == "Checking for updates…" {
            statusMessage = "Check for Updates for the latest release."
        }
        didOfferUpdate = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        didOfferUpdate = false
        statusMessage = "No compatible update is available on this channel."
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        guard error.domain != SUSparkleErrorDomain || ![Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(error.code) else { return }
        didOfferUpdate = false
        statusMessage = "The update could not complete. Check for Updates to try again."
        availableVersion = nil
    }
}
