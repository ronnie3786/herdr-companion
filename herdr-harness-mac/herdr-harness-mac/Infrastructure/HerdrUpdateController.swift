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
/// Scheduled checks surface a banner and a persistent indicator; installing
/// always requires user interaction.
@MainActor
@Observable
final class HerdrUpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    typealias BackgroundCheckRunner = @MainActor () -> Void

    /// Herdr keeps its own ten-minute cadence because Sparkle clamps its
    /// scheduled timer to a one-hour minimum. An explicit background check is
    /// not subject to that clamp, and it never presents update UI by itself.
    static let backgroundCheckInterval: TimeInterval = 600
    static let firstBackgroundCheckDelay: TimeInterval = 120

    /// Newest version a check has offered. Kept after the banner is dismissed so
    /// the window's indicator stays actionable until the update is installed.
    private(set) var availableVersion: String?
    private(set) var canCheckForUpdates = false
    private(set) var isUpdateSessionInProgress = false
    private(set) var statusMessage: String?
    private(set) var lastBackgroundCheckAt: Date?
    private(set) var nextBackgroundCheckAt: Date?
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
    @ObservationIgnored private let backgroundCheckRunner: BackgroundCheckRunner?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var backgroundCheckTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var didOfferUpdate = false
    @ObservationIgnored private var dismissedVersion: String?
    @ObservationIgnored private var isRuntimeAllowed = HerdrUpdateController.runtimeAllowsUpdateChecks

    /// Unit tests and demo mode must never make release checks, schedule them, or
    /// present updater windows.
    static var runtimeAllowsUpdateChecks: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && NSClassFromString("XCTestCase") == nil
            && !ProcessInfo.processInfo.arguments.contains("-HerdrDemoMode")
    }

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        backgroundCheckRunner: BackgroundCheckRunner? = nil
    ) {
        self.defaults = defaults
        self.backgroundCheckRunner = backgroundCheckRunner
        configuration = HerdrUpdateConfiguration(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
        isConfigured = configuration != nil
        // Every Herdr release is published on the preview channel, so a build
        // whose preference was never stored would otherwise filter the whole feed
        // away and could never see an update. The toggle still turns previews off.
        includesPreviewUpdates = defaults.object(forKey: Self.previewPreference) as? Bool ?? true
        super.init()
        if !isConfigured {
            statusMessage = "Updates are available in signed release builds."
        }
    }

    /// The banner is hidden by Later, while the availability indicator stays.
    var isBannerVisible: Bool {
        availableVersion != nil && dismissedVersion != availableVersion
    }

    func start() {
        guard !didStart, isConfigured else { return }
        guard isRuntimeAllowed else { return }
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
        startBackgroundChecks()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        if !isUpdateSessionInProgress { statusMessage = "Checking for updates…" }
        controller?.checkForUpdates(nil)
    }

    /// Hides the banner without discarding the fact that an update is available.
    func dismissBanner() {
        dismissedVersion = availableVersion
    }

    /// One step of the ten-minute cadence. Skipped while an update session is in
    /// progress, when automatic checks are off, or before the updater started.
    func performBackgroundCheck(now: Date = Date()) {
        guard HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: isConfigured,
            runtimeAllowed: isRuntimeAllowed,
            isStarted: didStart,
            automaticallyChecksForUpdates: automaticallyChecksForUpdates,
            isSessionInProgress: isUpdateSessionInProgress
        ) else { return }
        lastBackgroundCheckAt = now
        nextBackgroundCheckAt = now.addingTimeInterval(Self.backgroundCheckInterval)
        if let backgroundCheckRunner {
            backgroundCheckRunner()
            return
        }
        guard let controller else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    private func startBackgroundChecks() {
        guard backgroundCheckTask == nil, isRuntimeAllowed else { return }
        nextBackgroundCheckAt = Date().addingTimeInterval(Self.firstBackgroundCheckDelay)
        backgroundCheckTask = Task { @MainActor [weak self] in
            var delay = Self.firstBackgroundCheckDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                delay = Self.backgroundCheckInterval
                self.performBackgroundCheck()
            }
        }
    }

    #if DEBUG
    /// Test seam: exercises the cadence and its gates without starting Sparkle.
    func startBackgroundChecksForTesting(runtimeAllowed: Bool, automaticallyChecks: Bool) {
        isRuntimeAllowed = runtimeAllowed
        didStart = true
        automaticallyChecksForUpdates = automaticallyChecks
        startBackgroundChecks()
    }

    /// Test seam: the timer's sleep interval is not observable mid-flight.
    func performBackgroundCheckForTesting(now: Date = Date()) {
        performBackgroundCheck(now: now)
    }
    #endif

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesPreviewUpdates ? ["preview"] : []
    }

    /// Settings-facing summary of the ten-minute cadence.
    static func backgroundCheckDescription(
        isConfigured: Bool,
        lastCheckAt: Date?,
        nextCheckAt: Date?,
        interval: TimeInterval
    ) -> String {
        guard isConfigured else { return "Not available in this build." }
        let minutes = max(1, Int(interval / 60))
        let cadence = "Every \(minutes) minutes while Herdr runs"
        guard let lastCheckAt else {
            return "\(cadence). The first check runs two minutes after launch."
        }
        let last = lastCheckAt.formatted(date: .omitted, time: .shortened)
        guard let nextCheckAt else { return "\(cadence). Last checked \(last)." }
        let next = nextCheckAt.formatted(date: .omitted, time: .shortened)
        return "\(cadence). Last checked \(last); next around \(next)."
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
        guard !handleShowingUpdate else {
            // Sparkle's own window has focus; a banner would duplicate it. The
            // next scheduled check restores the indicator if the user defers.
            availableVersion = nil
            dismissedVersion = nil
            return
        }
        if dismissedVersion != update.displayVersionString {
            dismissedVersion = nil
        }
        availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        statusMessage = "Herdr \(update.displayVersionString) is available."
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        dismissedVersion = nil
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
        dismissedVersion = nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        guard error.domain != SUSparkleErrorDomain || ![Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(error.code) else { return }
        didOfferUpdate = false
        statusMessage = "The update could not complete. Check for Updates to try again."
        availableVersion = nil
        dismissedVersion = nil
    }
}
