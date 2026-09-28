import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
private final class DriverHarness {
    let fleet = FirstMateFleetIndex()
    var roster: FirstMateFleetRoster
    var clients: [String: SyntheticChatFleetClient] = [:]
    private(set) var reconciled: [FirstMateFleetRoster.Identity] = []
    private(set) var driver: FirstMateFleetDriver!

    init(machines: [String], activeInterval: Duration = FirstMateFleetDriver.activeInterval) {
        roster = .empty
        setMachines(machines)
        driver = FirstMateFleetDriver(
            fleet: fleet,
            reconcile: { [unowned self] roster in reconciled.append(roster.identity) },
            makeClient: { [unowned self] configuration in
                clients[configuration.baseURL.host() ?? ""] ?? SyntheticChatFleetClient()
            },
            isInert: false,
            // Tests call `sync()` themselves; the sampler only runs once.
            sampleInterval: .seconds(600),
            activeInterval: activeInterval,
            backgroundInterval: activeInterval * 3
        )
    }

    func setMachines(_ ids: [String], token: String = "token", generation: Int = 1) {
        var configurations: [String: ServerConfiguration] = [:]
        for id in ids {
            let machine = ChatFixtures.machine(id)
            configurations[id] = ServerConfiguration(urlString: machine.urlString, token: "\(id)-\(token)")!
            if clients["\(id).example.invalid"] == nil {
                clients["\(id).example.invalid"] = SyntheticChatFleetClient(features: [ChatFixtures.feature("\(id)-one", status: "blocked")])
            }
        }
        roster = FirstMateFleetRoster(
            isDemo: false,
            connectionGeneration: generation,
            machines: ids.map(ChatFixtures.machine),
            configurations: configurations
        )
    }

    func start() {
        driver.start { [unowned self] in roster }
    }

    func client(_ id: String) -> SyntheticChatFleetClient { clients["\(id).example.invalid"]! }
}

@Suite("First Mate fleet driver", .serialized)
@MainActor
struct FirstMateFleetDriverTests {
    @Test("Starting twice observes once, and reconciles the roster once")
    func startsOnce() async throws {
        let harness = DriverHarness(machines: ["alpha"])
        defer { harness.driver.stop() }
        harness.start()
        harness.start()
        harness.driver.sync()
        harness.driver.sync()
        try await ChatFixtures.waitUntil("alpha loads") { harness.fleet.hosts.first?.features.count == 1 }
        harness.driver.sync()
        #expect(harness.driver.isRunning)
        #expect(harness.driver.observationStarts == 1)
        #expect(harness.reconciled.count == 1)
        #expect(harness.fleet.hasObserver)
        #expect(harness.fleet.pollingInterval == FirstMateFleetDriver.activeInterval || harness.fleet.pollingInterval == FirstMateFleetDriver.backgroundInterval)
    }

    @Test("A roster, name, or credential change reconciles and restarts observation")
    func restartsOnRosterChange() async throws {
        let harness = DriverHarness(machines: ["alpha"])
        defer { harness.driver.stop() }
        harness.start()
        harness.driver.sync()
        try await ChatFixtures.waitUntil("alpha loads") { harness.fleet.hosts.map(\.machineID) == ["alpha"] }

        harness.setMachines(["alpha", "beta"])
        harness.driver.sync()
        try await ChatFixtures.waitUntil("beta loads") {
            harness.fleet.hosts.map(\.machineID) == ["alpha", "beta"] && harness.fleet.hosts.allSatisfy { $0.features.count == 1 }
        }
        #expect(harness.driver.observationStarts == 2)
        #expect(harness.reconciled.count == 2)

        harness.setMachines(["alpha", "beta"], token: "rotated")
        harness.driver.sync()
        #expect(harness.driver.observationStarts == 3)
        #expect(harness.reconciled.last?.machines.map(\.token) == ["alpha-rotated", "beta-rotated"])

        harness.driver.sync()
        #expect(harness.driver.observationStarts == 3, "An unchanged roster changes nothing")
    }

    @Test("Polling continues after the window that started it goes away")
    func outlivesTheWindow() async throws {
        let harness = DriverHarness(machines: ["alpha"], activeInterval: .milliseconds(20))
        defer { harness.driver.stop() }
        // A window's view task starts the driver and is then cancelled, as
        // closing the main window cancels its tasks.
        let windowTask = Task { @MainActor in
            harness.start()
            harness.driver.sync()
            try? await Task.sleep(for: .seconds(600))
        }
        try await ChatFixtures.waitUntil("first poll") { harness.client("alpha").featureListCalls >= 1 }
        windowTask.cancel()
        let before = harness.client("alpha").featureListCalls
        try await ChatFixtures.waitUntil("later polls") { harness.client("alpha").featureListCalls >= before + 2 }
        #expect(harness.fleet.hasObserver)
    }

    @Test("Resumes observing when the observation lapsed and nothing else observes")
    func resumesAfterLapse() async throws {
        let harness = DriverHarness(machines: ["alpha"])
        defer { harness.driver.stop() }
        harness.start()
        harness.driver.sync()
        try await ChatFixtures.waitUntil("observing") { harness.fleet.hasObserver }
        harness.fleet.deactivate()
        try await ChatFixtures.waitUntil("observer ends") { !harness.fleet.hasObserver }
        // Let the ended observation clear its task.
        try await Task.sleep(for: .milliseconds(700))
        harness.driver.sync()
        #expect(harness.driver.observationStarts == 2)
        try await ChatFixtures.waitUntil("observing again") { harness.fleet.hasObserver }
        #expect(harness.reconciled.count == 1, "The roster did not change")
    }

    @Test("Demo mode observes an empty roster once and never polls")
    func demoRoster() async throws {
        let harness = DriverHarness(machines: ["alpha"])
        defer { harness.driver.stop() }
        harness.start()
        harness.driver.sync()
        try await ChatFixtures.waitUntil("alpha loads") { harness.fleet.hosts.count == 1 }
        harness.roster.isDemo = true
        harness.driver.sync()
        try await ChatFixtures.waitUntil("hosts clear") { harness.fleet.hosts.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        harness.driver.sync()
        harness.driver.sync()
        #expect(harness.driver.observationStarts == 2)
        #expect(!harness.fleet.hasObserver)
    }

    @Test("Polls every 10 s while active and 30 s in the background, refreshing on activation")
    func cadence() async throws {
        let harness = DriverHarness(machines: ["alpha"])
        defer { harness.driver.stop() }
        harness.start()
        harness.driver.sync()
        try await ChatFixtures.waitUntil("first poll") { harness.client("alpha").featureListCalls == 1 }

        harness.driver.applicationActivityChanged(isActive: false)
        #expect(harness.fleet.pollingInterval == .seconds(30))
        #expect(!harness.driver.isApplicationActive)
        #expect(harness.client("alpha").featureListCalls == 1, "Resigning does not refresh")

        harness.driver.applicationActivityChanged(isActive: true)
        #expect(harness.fleet.pollingInterval == .seconds(10))
        try await ChatFixtures.waitUntil("activation refresh") { harness.client("alpha").featureListCalls == 2 }

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await ChatFixtures.waitUntil("resign notification") { harness.fleet.pollingInterval == .seconds(30) }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await ChatFixtures.waitUntil("activate notification") {
            harness.fleet.pollingInterval == .seconds(10) && harness.client("alpha").featureListCalls == 3
        }
    }

    @Test("An inert driver (the default under XCTest) starts nothing")
    func inertUnderTests() {
        #expect(FirstMateFleetDriver.isHostedByTests)
        let fleet = FirstMateFleetIndex()
        let driver = FirstMateFleetDriver(fleet: fleet, reconcile: { _ in Issue.record("reconciled") })
        driver.start { .empty }
        driver.sync()
        #expect(!driver.isRunning)
        #expect(driver.observationStarts == 0)

        let shell = ChatFixtures.shell()
        shell.startFirstMateServices(model: ChatFixtures.model(demo: false))
        shell.startFirstMateServices(model: ChatFixtures.model(demo: false))
        #expect(shell.firstMateFleetDriver?.isRunning == false)
        #expect(shell.firstMateDockBadge?.ownsBadge == false)
    }
}

@Suite("First Mate Dock badge and menu", .serialized)
@MainActor
struct FirstMateDockBadgeTests {
    private static func defaults() -> UserDefaults {
        let name = "FirstMateDockBadgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Preferences: the window preview is off and the Dock count on by default, independently")
    func preferenceDefaults() {
        #expect(FirstMateChatPreferences.defaultWindowEnabled == false)
        #expect(FirstMateChatPreferences.defaultDockBadgeEnabled == true)
        #expect(FirstMateChatPreferences.windowEnabledKey != FirstMateChatPreferences.dockBadgeEnabledKey)
        let defaults = Self.defaults()
        let controller = FirstMateDockBadgeController(defaults: defaults, apply: { _ in }, isInert: false)
        #expect(controller.isEnabled)
        defaults.set(false, forKey: FirstMateChatPreferences.windowEnabledKey)
        #expect(controller.isEnabled, "The Dock count does not follow the window preview")
        defaults.set(false, forKey: FirstMateChatPreferences.dockBadgeEnabledKey)
        #expect(!controller.isEnabled)
    }

    @Test("The label is the count, and hidden at zero")
    func label() {
        #expect(FirstMateDockBadgeController.label(for: 0) == nil)
        #expect(FirstMateDockBadgeController.label(for: 1) == "1")
        #expect(FirstMateDockBadgeController.label(for: 123) == "123")
    }

    @Test("Demo shows 3, follows read markers, and owns the badge while on")
    func demoCount() async throws {
        let model = ChatFixtures.model(demo: true)
        let shell = ChatFixtures.shell()
        var applied: [String?] = []
        let controller = FirstMateDockBadgeController(defaults: Self.defaults(), apply: { applied.append($0) }, isInert: false)
        #expect(controller.count(model: model, shell: shell) == 3)
        controller.start(model: model, shell: shell)
        controller.start(model: model, shell: shell)
        #expect(applied == ["3"])
        #expect(controller.ownsBadge)
        #expect(model.isAlertBadgeSuspended)

        controller.update()
        #expect(applied == ["3"], "An unchanged count writes nothing")

        let receipts = try #require(FirstMateDemo.chatWindowFleet().first { $0.featureID == "demo-receipts" })
        await shell.firstMateFleet.markRead(
            machineID: "demo", featureID: receipts.featureID,
            throughMessageID: try #require(receipts.latestFirstMateMessageID)
        )
        try await ChatFixtures.waitUntil("badge follows the read marker") { applied.last == "2" }
    }

    @Test("A live fleet with nothing that needs you shows no badge")
    func emptyAtZero() {
        let model = ChatFixtures.model(demo: false)
        let shell = ChatFixtures.shell()
        var applied: [String?] = []
        let controller = FirstMateDockBadgeController(defaults: Self.defaults(), apply: { applied.append($0) }, isInert: false)
        controller.start(model: model, shell: shell)
        #expect(controller.count(model: model, shell: shell) == 0)
        #expect(applied == [nil])
        #expect(controller.appliedLabel == nil)
    }

    @Test("Turning the setting off clears the count and restores the alert-count badge")
    func settingOffRestoresAlerts() async throws {
        let model = ChatFixtures.model(demo: true)
        let shell = ChatFixtures.shell()
        var alertWrites: [Int] = []
        model.alertBadgeWriter = { alertWrites.append($0) }
        let defaults = Self.defaults()
        var applied: [String?] = []
        let controller = FirstMateDockBadgeController(defaults: defaults, apply: { applied.append($0) }, isInert: false)
        controller.start(model: model, shell: shell)
        #expect(model.isAlertBadgeSuspended)
        #expect(alertWrites.isEmpty)

        defaults.set(false, forKey: FirstMateChatPreferences.dockBadgeEnabledKey)
        try await ChatFixtures.waitUntil("setting off applies") { !controller.ownsBadge }
        #expect(applied == ["3", nil])
        #expect(!model.isAlertBadgeSuspended)
        #expect(alertWrites == [model.unreadAlertCount], "The alert count is written again")

        defaults.set(true, forKey: FirstMateChatPreferences.dockBadgeEnabledKey)
        try await ChatFixtures.waitUntil("setting on applies") { controller.ownsBadge }
        #expect(applied == ["3", nil, "3"])
        #expect(model.isAlertBadgeSuspended)
    }

    @Test("A setting that starts off never touches the badge")
    func startsOff() {
        let model = ChatFixtures.model(demo: true)
        let defaults = Self.defaults()
        defaults.set(false, forKey: FirstMateChatPreferences.dockBadgeEnabledKey)
        var applied: [String?] = []
        let controller = FirstMateDockBadgeController(defaults: defaults, apply: { applied.append($0) }, isInert: false)
        controller.start(model: model, shell: ChatFixtures.shell())
        #expect(applied.isEmpty)
        #expect(!model.isAlertBadgeSuspended)
    }

    @Test("The Dock menu lists up to five dotted conversations as \"emoji name: status\"")
    func menuItems() {
        var conversations: [FirstMateConversation] = []
        for index in 0..<7 {
            conversations.append(ChatFixtures.conversation("Needs \(index)", hud: index.isMultiple(of: 2) ? .blocked : .turn, unread: true))
            conversations.append(ChatFixtures.conversation("Read \(index)", hud: .blocked, unread: false))
            conversations.append(ChatFixtures.conversation("Moving \(index)", hud: .working, unread: true))
        }
        let items = FirstMateDockMenuItem.items(conversations: conversations)
        #expect(items.count == 5)
        #expect(items.map(\.title) == [
            "🧪 Needs 0: Blocked", "🧪 Needs 1: Your turn", "🧪 Needs 2: Blocked", "🧪 Needs 3: Your turn", "🧪 Needs 4: Blocked",
        ])
        #expect(items.map(\.id.featureID) == ["Needs 0", "Needs 1", "Needs 2", "Needs 3", "Needs 4"])
        #expect(FirstMateDockMenuItem.items(conversations: conversations.filter { !$0.showsDot }).isEmpty)

        let menu = HerdrMacAppDelegate.dockMenu(items: items, target: nil, action: nil)
        #expect(menu?.items.map(\.title) == items.map(\.title))
        #expect(menu?.items.map(\.tag) == [0, 1, 2, 3, 4])
        #expect(HerdrMacAppDelegate.dockMenu(items: [], target: nil, action: nil) == nil)
    }

    @Test("The demo Dock menu names Receipt export as blocked")
    func demoMenu() {
        let model = ChatFixtures.model(demo: true)
        let shell = ChatFixtures.shell()
        let controller = FirstMateDockBadgeController(defaults: Self.defaults(), apply: { _ in }, isInert: false)
        let items = controller.menuItems(model: model, shell: shell)
        #expect(items.count == 3)
        #expect(items.contains { $0.title == "🧾 Receipt export: Blocked" && $0.id == FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts") })
        #expect(Set(items.map(\.id.featureID)) == ["demo-receipts", "demo-release", "demo-search"])
    }

    @Test("Choosing a conversation opens the chat window with the preview on, else the First Mate screen")
    func opening() throws {
        let model = ChatFixtures.model(demo: false)
        let shell = ChatFixtures.shell()
        let id = FirstMateFleetFeatureID(machineID: "alpha", featureID: "fmf_synthetic")
        var opened: [String] = []
        let openWindow = OpenWindowActionProbe { opened.append($0) }
        openWindow.open(id, model: model, shell: shell, chatWindowEnabled: true)
        #expect(shell.firstMateChatOpenRequest == id)
        #expect(opened == [HerdrWindowID.firstMateChat])

        shell.firstMateChatOpenRequest = nil
        openWindow.open(id, model: model, shell: shell, chatWindowEnabled: false)
        #expect(shell.firstMateChatOpenRequest == nil)
        #expect(shell.detailScope == .firstMate)
        #expect(shell.firstMateScope == .machine("alpha"))
        let target = try #require(shell.pendingFirstMateControlTarget)
        #expect(target.machineID == "alpha" && target.featureID == "fmf_synthetic" && target.inspector == .overview)
        #expect(opened == [HerdrWindowID.firstMateChat, HerdrWindowID.main])
    }
}

/// `OpenWindowAction` has no public initializer, so the opening test drives
/// the same branches through a recorder.
@MainActor
private struct OpenWindowActionProbe {
    let record: (String) -> Void

    func open(_ id: FirstMateFleetFeatureID, model: HerdrAppModel, shell: HerdrShellState, chatWindowEnabled: Bool) {
        FirstMateChatWindowOpening.route(id, model: model, shell: shell, chatWindowEnabled: chatWindowEnabled, activate: {}, openWindow: record)
    }
}

@Suite("First Mate counted labels")
struct FirstMateCountTextTests {
    @Test("One is singular; zero and many are plural")
    func pluralization() {
        #expect(FirstMateCountText.phrase(1, "agent") == "1 agent")
        #expect(FirstMateCountText.phrase(0, "agent") == "0 agents")
        #expect(FirstMateCountText.phrase(2, "document") == "2 documents")
        #expect(FirstMateCountText.phrase(1, "saved session") == "1 saved session")
        #expect(FirstMateCountText.phrase(3, "child", plural: "children") == "3 children")
    }
}

@Suite("First Mate chat window entry points render", .serialized)
@MainActor
struct FirstMateChatShellRenderTests {
    @Test("The First Mate screen shows Open in window beside Chat | Git while the preview is on")
    func openInWindowButton() async throws {
        let defaults = UserDefaults.standard
        let key = FirstMateChatPreferences.windowEnabledKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let model = HerdrRenderFixtures.demoModel()
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.show(.firstMate, model: model)
        shell.configureFirstMateIfNeeded(machineID: "demo", configuration: nil, connectionGeneration: model.connectionGeneration, isDemo: true)
        await shell.firstMate.refresh()
        shell.firstMate.advanceDemo()
        _ = try #require(shell.firstMate.snapshot)

        let result = try await HerdrRenderHarness.renderWindow("fmchat-shell-first-mate-open-in-window.png", size: MonoScreenRenderTests.window) {
            MonoRenderFixtures.window(model: model, shell: shell)
                .background(FirstMatePalette(scheme: .dark).background)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        }
        result.expectSubstantial()
    }
}
