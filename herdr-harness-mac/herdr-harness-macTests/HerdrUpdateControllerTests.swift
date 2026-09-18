import Foundation
import Sparkle
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Update reminder lifecycle")
struct HerdrUpdateControllerTests {
    @Test("A scheduled appcast displays its release version and Later preserves the available status")
    func scheduledUpdateAndLater() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let item = try appcastItem()
        let state = try updateState(userInitiated: false)

        #expect(!controller.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true))
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: item, state: state)
        #expect(controller.availableVersion == "2.1 Preview 1")
        #expect(controller.statusMessage == "Herdr 2.1 Preview 1 is available.")

        controller.dismissBanner()
        // Later hides the banner only; the window's indicator stays actionable.
        #expect(controller.availableVersion == "2.1 Preview 1")
        #expect(!controller.isBannerVisible)
        #expect(controller.statusMessage == "Herdr 2.1 Preview 1 is available.")

        // A later user-initiated presentation belongs to Sparkle, not a second banner.
        controller.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try updateState(userInitiated: true))
        #expect(controller.availableVersion == nil)
        #expect(controller.statusMessage == "Herdr 2.1 Preview 1 is available.")
    }

    @Test("Giving an update attention clears its banner while retaining release status")
    func userAttention() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let item = try appcastItem()
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: item, state: try updateState(userInitiated: false))
        controller.standardUserDriverDidReceiveUserAttention(forUpdate: item)
        #expect(controller.availableVersion == nil)
        #expect(controller.statusMessage == "Herdr 2.1 Preview 1 is available.")
    }

    @Test("Ending a pending update clears the banner without claiming the app is current")
    func sessionEnds() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: try appcastItem(), state: try updateState(userInitiated: false))
        controller.standardUserDriverWillFinishUpdateSession()
        #expect(controller.availableVersion == nil)
        #expect(controller.statusMessage == "Check for Updates for the latest release.")
    }

    @Test("Preview updates are included unless the user turns them off, and the choice survives recreation")
    func previewPreference() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let updater = unstartedUpdater()
        // Every published Herdr release is on the preview channel, so a build with
        // no stored preference must include previews or it can never see an update.
        #expect(controller.includesPreviewUpdates)
        #expect(controller.allowedChannels(for: updater) == ["preview"])

        controller.includesPreviewUpdates = false
        let restored = fixture.makeController()
        #expect(!restored.includesPreviewUpdates)
        #expect(restored.allowedChannels(for: updater).isEmpty)

        restored.includesPreviewUpdates = true
        #expect(fixture.makeController().includesPreviewUpdates)
        #expect(restored.allowedChannels(for: updater) == ["preview"])
    }

    @Test("The background-check gate requires a configured, started, automatic, idle updater")
    func backgroundCheckPolicy() {
        #expect(HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: true, runtimeAllowed: true, isStarted: true,
            automaticallyChecksForUpdates: true, isSessionInProgress: false
        ))
        #expect(!HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: false, runtimeAllowed: true, isStarted: true,
            automaticallyChecksForUpdates: true, isSessionInProgress: false
        ))
        #expect(!HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: true, runtimeAllowed: false, isStarted: true,
            automaticallyChecksForUpdates: true, isSessionInProgress: false
        ))
        #expect(!HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: true, runtimeAllowed: true, isStarted: false,
            automaticallyChecksForUpdates: true, isSessionInProgress: false
        ))
        #expect(!HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: true, runtimeAllowed: true, isStarted: true,
            automaticallyChecksForUpdates: false, isSessionInProgress: false
        ))
        #expect(!HerdrUpdateCheckPolicy.shouldRunBackgroundCheck(
            isConfigured: true, runtimeAllowed: true, isStarted: true,
            automaticallyChecksForUpdates: true, isSessionInProgress: true
        ))
    }

    @Test("Background checks follow the ten-minute cadence and stop when automatic checks are off")
    func backgroundCheckCadence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var checks = 0
        let controller = fixture.makeController(backgroundCheckRunner: { checks += 1 })
        controller.startBackgroundChecksForTesting(runtimeAllowed: true, automaticallyChecks: true)
        let first = Date()

        controller.performBackgroundCheckForTesting(now: first)
        #expect(checks == 1)
        #expect(controller.lastBackgroundCheckAt == first)
        #expect(controller.nextBackgroundCheckAt == first.addingTimeInterval(HerdrUpdateController.backgroundCheckInterval))
        #expect(HerdrUpdateController.backgroundCheckInterval == 600)

        controller.automaticallyChecksForUpdates = false
        controller.performBackgroundCheckForTesting(now: first.addingTimeInterval(60))
        #expect(checks == 1)

        controller.automaticallyChecksForUpdates = true
        controller.performBackgroundCheckForTesting(now: first.addingTimeInterval(120))
        #expect(checks == 2)
    }

    @Test("Settings describes the cadence, the last check, and the next one")
    func cadenceDescription() {
        #expect(HerdrUpdateController.backgroundCheckDescription(
            isConfigured: false, lastCheckAt: nil, nextCheckAt: nil, interval: 600
        ) == "Not available in this build.")

        let beforeFirst = HerdrUpdateController.backgroundCheckDescription(
            isConfigured: true, lastCheckAt: nil, nextCheckAt: nil, interval: 600
        )
        #expect(beforeFirst.contains("Every 10 minutes"))
        #expect(beforeFirst.contains("two minutes after launch"))

        let last = Date()
        let afterFirst = HerdrUpdateController.backgroundCheckDescription(
            isConfigured: true,
            lastCheckAt: last,
            nextCheckAt: last.addingTimeInterval(600),
            interval: 600
        )
        #expect(afterFirst.contains("Last checked"))
        #expect(afterFirst.contains("next around"))
    }

    @Test("A channel with no compatible update does not imply every release is installed")
    func noCompatibleUpdate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: try appcastItem(), state: try updateState(userInitiated: false))
        controller.updaterDidNotFindUpdate(unstartedUpdater(), error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        #expect(controller.availableVersion == nil)
        #expect(controller.statusMessage == "No compatible update is available on this channel.")
    }

    @Test("An update error dismisses stale availability and offers another check")
    func failedUpdate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        controller.standardUserDriverWillHandleShowingUpdate(false, forUpdate: try appcastItem(), state: try updateState(userInitiated: false))
        controller.updater(unstartedUpdater(), didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(controller.availableVersion == nil)
        #expect(controller.statusMessage == "The update could not complete. Check for Updates to try again.")
    }

    @Test("An unconfigured build stays inactive when started or checked repeatedly")
    func unconfiguredStartup() throws {
        let fixture = try Fixture(configured: false)
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let initialStatus = controller.statusMessage
        controller.start()
        controller.start()
        controller.checkForUpdates()
        #expect(!controller.isConfigured)
        #expect(!controller.canCheckForUpdates)
        #expect(!controller.isUpdateSessionInProgress)
        #expect(controller.availableVersion == nil)
        #expect(controller.statusMessage == initialStatus)
    }

    @Test("A configured test-host build does not start Sparkle or enable update checks")
    func configuredTestHostStartup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        #expect(controller.isConfigured)
        controller.start()
        #expect(!controller.canCheckForUpdates)
        #expect(!controller.isUpdateSessionInProgress)
        #expect(controller.availableVersion == nil)
    }

    private func appcastItem() throws -> SUAppcastItem {
        // The public dictionary initializer is sufficient for display data;
        // these tests do not ask Sparkle to evaluate OS or application versions.
        try #require(SUAppcastItem(dictionary: [
            "title": "Herdr 2.1 Preview 1",
            "sparkle:version": "2101",
            "sparkle:shortVersionString": "2.1 Preview 1",
            "sparkle:channel": "preview",
            "enclosure": [
                "url": "https://example.com/Herdr-2.1-preview.zip",
                "length": "1024",
                "type": "application/octet-stream"
            ]
        ]))
    }

    private func updateState(userInitiated: Bool) throws -> SPUUserUpdateState {
        // Exercise Sparkle's real NSSecureCoding implementation without a
        // private initializer, network request, or update window.
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(SPUUserUpdateStage.notDownloaded.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        #expect(state.stage == .notDownloaded)
        #expect(state.userInitiated == userInitiated)
        return state
    }

    private func unstartedUpdater() -> SPUUpdater {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let bundle: Bundle
        let defaults: UserDefaults
        let suite: String

        init(configured: Bool = true) throws {
            let identifier = "org.example.herdr-update-tests.\(UUID().uuidString)"
            suite = identifier
            defaults = try #require(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".bundle")
            let contents = directory.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier,
                "CFBundleName": "Update Test Fixture",
                "CFBundleVersion": "1",
                "HerdrUpdateBundleIdentifier": configured ? identifier : "org.example.different-app",
                "SUFeedURL": "https://example.com/appcast.xml",
                "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
                "SURequireSignedFeed": true,
                "SUVerifyUpdateBeforeExtraction": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            bundle = try #require(Bundle(url: directory))
        }

        func makeController(backgroundCheckRunner: HerdrUpdateController.BackgroundCheckRunner? = nil) -> HerdrUpdateController {
            HerdrUpdateController(
                bundle: bundle,
                defaults: defaults,
                backgroundCheckRunner: backgroundCheckRunner
            )
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
