import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Shell refresh lifecycle")
@MainActor
struct ShellRefreshLifecycleTests {
    @Test("A replaced activity request cannot restore a removed host or stop the new request")
    func rejectsOldActivityResponse() async throws {
        let fixture = fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let oldGate = ActivityResponseGate()
        let first = Task { await model.refreshActivityFeed { _ in await oldGate.load() } }
        await oldGate.waitUntilRequested()
        model.machines = [.init(id: "new", name: "New host", urlString: "https://new.example")]
        model.connectionGeneration += 1
        model.prepareRuntime(for: model.machines[0], generation: model.connectionGeneration)
        let newGate = ActivityResponseGate()
        let second = Task { await model.refreshActivityFeed { _ in await newGate.load() } }
        await newGate.waitUntilRequested()
        await oldGate.finish([alert("old")])
        await first.value
        #expect(model.isRefreshingActivity)
        #expect(model.activityHistoryAlerts.isEmpty)
        await newGate.finish([alert("new")])
        await second.value
        #expect(model.activityHistoryAlerts.map(\.machineID) == ["new"])
        #expect(!model.isRefreshingActivity)
        #expect(model.activityFeedError == nil)
    }

    @Test("A new generation or endpoint never borrows its previous runtime", arguments: [true, false])
    func rejectsStaleRuntime(changeGeneration: Bool) async {
        let fixture = fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        if changeGeneration { model.connectionGeneration += 1 }
        else { model.machines[0].urlString = "https://replacement.example" }
        let calls = ActivityInvocationCounter()
        await model.refreshActivityFeed { _ in await calls.record(); return [alert("wrong-source")] }
        #expect(await calls.count == 0)
        #expect(model.activityHistoryAlerts.isEmpty)
        #expect(model.activityFeedError?.contains("No active connection") == true)
        #expect(model.workInboxConnectionIdentity.connection == nil)
        do {
            _ = try await model.fetchWorkInbox(expectedIdentity: model.workInboxConnectionIdentity)
            Issue.record("An unprepared new connection must not fetch the old primary's inbox")
        } catch APIError.noActiveConnection {
            // The previous runtime was rejected before starting a request.
        } catch {
            Issue.record("Unexpected stale-runtime error: \(error)")
        }
        model.prepareRuntime(for: model.machines[0], generation: model.connectionGeneration)
        #expect(model.workInboxConnectionIdentity.connection?.generation == model.connectionGeneration)
    }

    @Test("Cancellation preserves good activity and never surfaces a cancellation banner")
    func cancelsActivityWithoutBanner() async {
        let fixture = fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        await model.refreshActivityFeed { _ in [alert("retained")] }
        let gate = ActivityResponseGate()
        let task = Task { await model.refreshActivityFeed { _ in await gate.load() } }
        await gate.waitUntilRequested()
        task.cancel()
        await gate.finish([alert("late")])
        await task.value
        #expect(model.activityHistoryAlerts.map(\.rawID) == ["retained"])
        #expect(model.activityFeedError == nil)
        #expect(!model.isRefreshingActivity)
    }

    @Test("A changed source snapshot rejects results even before its generation is updated")
    func rejectsChangedRoster() async {
        let fixture = fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let gate = ActivityResponseGate()
        let task = Task { await model.refreshActivityFeed { _ in await gate.load() } }
        await gate.waitUntilRequested()
        model.machines.removeAll()
        await gate.finish([alert("late")])
        await task.value
        #expect(model.activityHistoryAlerts.isEmpty)
        #expect(model.activityFeedError == nil)
    }

    @Test("Hidden shell reconciles sources and invalidates primary inbox without polling")
    func reconcilesWhileHidden() async {
        let fixture = fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let shell = HerdrShellState(userDefaults: fixture.defaults)
        await shell.refreshCoordinator.run(model: model, shell: shell, canPoll: false)
        #expect(shell.prReviewFleet.sourceCount == 1)
        #expect(shell.watchers.sources.map(\.machineID) == ["old"])
        #expect(!shell.refreshCoordinator.isPolling)
        #expect(!shell.prReviewFleet.hasLoaded)
        #expect(!shell.workInbox.hasLoaded)
        await shell.workInbox.refresh(for: model.workInboxConnectionIdentity) { .empty }
        #expect(shell.workInbox.hasLoaded)
        model.machines.removeAll()
        model.connectionGeneration += 1
        await shell.refreshCoordinator.run(model: model, shell: shell, canPoll: false)
        #expect(shell.prReviewFleet.sourceCount == 0)
        #expect(shell.watchers.sources.isEmpty)
        #expect(!shell.workInbox.hasLoaded)
    }

    @Test("Stable shell updates summaries independently of its selected destination")
    func pollsAcrossDestinations() async {
        let fixture = fixture(demo: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let shell = HerdrShellState(userDefaults: fixture.defaults)
        shell.detailScope = .home
        let task = Task { await shell.refreshCoordinator.run(model: model, shell: shell, canPoll: true) }
        for _ in 0..<1_000 where !shell.workInbox.hasLoaded { await Task.yield() }
        #expect(shell.workInbox.hasLoaded)
        #expect(shell.watchers.loaded)
        #expect(shell.refreshCoordinator.isPolling)
        shell.detailScope = .session
        #expect(shell.refreshCoordinator.isPolling)
        task.cancel()
        await task.value
        #expect(!shell.refreshCoordinator.isPolling)
    }

    private func fixture(demo: Bool = false) -> RefreshFixture {
        let suite = "ShellRefreshLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: demo ? ["-HerdrDemoMode"] : [], userDefaults: defaults, configuredMachines: [])
        if !demo {
            model.machines = [.init(id: "old", name: "Old host", urlString: "https://old.example")]
            model.hasCompletedSetup = true
            model.prepareRuntime(for: model.machines[0], generation: model.connectionGeneration)
        }
        return .init(model: model, defaults: defaults, suite: suite)
    }
}

@MainActor
private struct RefreshFixture {
    let model: HerdrAppModel
    let defaults: UserDefaults
    let suite: String
    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

private func alert(_ id: String) -> HerdrAlert {
    .init(id: id, workspaceID: "workspace", paneID: "pane", status: .blocked, title: "Needs input", message: "", createdAt: "2026-10-03T12:00:00Z", isRead: false)
}

private actor ActivityResponseGate {
    private var pending: CheckedContinuation<[HerdrAlert], Never>?
    private var started: CheckedContinuation<Void, Never>?
    func load() async -> [HerdrAlert] {
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ alerts: [HerdrAlert]) { pending?.resume(returning: alerts); pending = nil }
}

private actor ActivityInvocationCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
