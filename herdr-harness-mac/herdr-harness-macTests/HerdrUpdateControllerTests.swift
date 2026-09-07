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
        #expect(controller.availableVersion == nil)
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

    @Test("Preview updates require opt-in and the choice survives controller recreation")
    func previewPreference() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let updater = unstartedUpdater()
        #expect(!controller.includesPreviewUpdates)
        #expect(controller.allowedChannels(for: updater).isEmpty)

        controller.includesPreviewUpdates = true
        let restored = fixture.makeController()
        #expect(restored.includesPreviewUpdates)
        #expect(restored.allowedChannels(for: updater) == ["preview"])

        restored.includesPreviewUpdates = false
        #expect(!fixture.makeController().includesPreviewUpdates)
        #expect(restored.allowedChannels(for: updater).isEmpty)
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

        func makeController() -> HerdrUpdateController {
            HerdrUpdateController(bundle: bundle, defaults: defaults)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
