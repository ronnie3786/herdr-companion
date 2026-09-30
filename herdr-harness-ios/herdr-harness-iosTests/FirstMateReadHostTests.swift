import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("Mounted phone read scheduling", .serialized)
@MainActor
struct FirstMateReadHostTests {
    @Test("Optimistic clearing does not cancel a mounted chat's pending read transport", arguments: [false, true])
    func optimisticTransport(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        await fixture.client.setHeldReads(true)
        fixture.mount()
        defer { fixture.unmount() }
        try await fixture.wait { await fixture.client.readIDs.count == 1 }
        await fixture.settle()
        #expect(await fixture.client.cancellations == 0)
        #expect(fixture.unreadCount == 0)
        await fixture.client.finishRead()
        await fixture.settle()
        #expect(await fixture.client.readIDs == ["A"])
        #expect(fixture.unreadCount == 0)
    }

    @Test("Short transcripts stay within scroll bounds and retain their held read across identical refreshes", arguments: [false, true])
    func stableShortTranscript(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        await fixture.client.setHeldReads(true)
        fixture.mount()
        defer { fixture.unmount() }
        try await fixture.wait { await fixture.client.readIDs == ["A"] }
        for _ in 0..<3 {
            await fixture.fleet.refreshChatIndex()
            await fixture.fleet.refreshSelected(fixture.target)
            await fixture.settle()
            let scroll = try #require(fixture.transcriptScrollView)
            #expect(scroll.contentSize.height < scroll.bounds.height)
            #expect(scroll.contentOffset.y >= -scroll.adjustedContentInset.top - 0.001)
            #expect(await fixture.client.readIDs == ["A"])
            #expect(await fixture.client.cancellations == 0)
            #expect(fixture.unreadCount == 0)
        }
        await fixture.client.finishRead()
        await fixture.settle()
        #expect(fixture.unreadCount == 0)
    }

    @Test("A fleet summary ahead of a held and then failed selected fetch stays unread", arguments: [false, true])
    func summaryAhead(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(unread: false, lead: lead)
        fixture.mount()
        defer { fixture.unmount() }
        await fixture.settle()
        await fixture.client.advanceSummaryToB()
        let fetching = Task { await fixture.fleet.refreshSelected(fixture.target) }
        try await fixture.wait { await fixture.client.fetchHeld }
        await fixture.fleet.refreshChatIndex()
        await fixture.settle()
        #expect(await fixture.client.readIDs.isEmpty)
        #expect(fixture.unreadCount == 1)
        await fixture.client.finishFetch(fail: true)
        await fetching.value
        await fixture.settle()
        #expect(fixture.store.snapshots[fixture.target.featureID]?.messages.map(\.id) == (lead ? ["A", "U0"] : ["A"]))
        #expect(await fixture.client.readIDs.isEmpty)
        #expect(fixture.unreadCount == 1)
        // Returning a matching snapshot is insufficient while Info is on top.
        fixture.presentation.topmost = false
        await fixture.client.advanceSummaryToB()
        let later = Task { await fixture.fleet.refreshSelected(fixture.target) }
        try await fixture.wait { await fixture.client.fetchHeld }
        await fixture.client.finishFetch(fail: false)
        await later.value
        await fixture.settle()
        #expect(await fixture.client.readIDs.isEmpty)
        fixture.presentation.topmost = true
        try await fixture.wait { await fixture.client.readIDs == ["B"] }
        #expect(fixture.unreadCount == 0)
    }

    @Test("Real coverage, scene, tab, disappearance and source loss cancel a mounted transport", arguments: [false, true])
    func genuineVisibilityLoss(lead: Bool) async throws {
        for transition in 0..<6 {
            let fixture = try await ReadHostFixture(lead: lead)
            await fixture.client.setHeldReads(true)
            fixture.mount()
            defer { fixture.unmount() }
            try await fixture.wait { await fixture.client.readIDs.count == 1 }
            await fixture.settle()
            #expect(await fixture.client.cancellations == 0)
            switch transition {
            case 0: fixture.model.isSidebarPresented = true
            case 1: fixture.presentation.topmost = false
            case 2: fixture.presentation.phase = .inactive
            case 3: fixture.model.selectedTab = .settings
            case 4: fixture.presentation.mounted = false
            default: fixture.fleet.activate(sources: [], connectionGeneration: 2)
            }
            try await fixture.wait { await fixture.client.cancellations == 1 }
            await fixture.settle()
            #expect(await fixture.client.readIDs == ["A"])
            if transition < 5 { #expect(fixture.unreadCount == 1) }
            fixture.unmount()
        }
    }

    @Test("Inline Info keeps the visible chat's read alive, while its resource sheet covers the chat")
    func inlineInspectorAndResourceCoverage() async throws {
        let fixture = try await ReadHostFixture(controllable: true)
        let clock = ReadHostClock()
        fixture.fleet.chat.clock = { clock.now }
        fixture.fleet.chat.readSleep = { try await clock.sleep($0) }
        await fixture.client.setHeldReads(true)
        fixture.mount(width: 900)
        defer { fixture.unmount() }
        try await fixture.wait { await fixture.client.readIDs == ["A"] }
        #expect(fixture.model.firstMateCanControl(machineID: fixture.target.machineID))
        #expect(fixture.store.controlAvailable, "The mounted chat owns an actual control lease")
        fixture.presentation.inlineInfo = true
        await fixture.settle()
        fixture.store.inspector = .documents
        await fixture.settle()
        #expect(await fixture.client.cancellations == 0)
        fixture.presentation.inlineInfo = false
        await fixture.settle()
        #expect(fixture.store.controlAvailable, "Dismissing inline Info cannot release the chat's lease")
        fixture.presentation.inlineInfo = true
        await fixture.settle()
        #expect(fixture.store.controlAvailable)
        var document = try #require(FirstMateDemo.chatWindowFeatures().first?.documents.first)
        document.featureID = fixture.target.featureID
        await fixture.store.open(.document(document))
        try await fixture.wait { await fixture.client.cancellations == 1 }
        #expect(fixture.unreadCount == 1)
        fixture.store.closeResource()
        await fixture.settle()
        clock.advance(180)
        try await fixture.wait { await fixture.client.readIDs.count == 2 }
        await fixture.client.finishRead()
    }

    @Test("Offscreen render hosts cannot read until tracking is explicitly enabled", arguments: [false, true])
    func offscreenTracking(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        fixture.presentation.tracking = false
        fixture.mount()
        defer { fixture.unmount() }
        await fixture.settle()
        #expect(await fixture.client.readIDs.isEmpty)
        fixture.presentation.tracking = true
        try await fixture.wait { await fixture.client.readIDs == ["A"] }
    }

    @Test("A failed marker retries at its deadline despite identical healthy polls", arguments: [false, true])
    func scheduledRetry(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        let clock = ReadHostClock()
        fixture.fleet.chat.clock = { clock.now }
        fixture.fleet.chat.readSleep = { try await clock.sleep($0) }
        await fixture.client.failReads(1)
        fixture.mount()
        defer { fixture.unmount() }
        try await fixture.wait { clock.waiterCount == 1 }
        #expect(await fixture.client.readIDs == ["A"])
        #expect(fixture.unreadCount == 1)
        let lastSeen = fixture.fleet.hosts.first?.lastUpdated
        clock.advance(7)
        await fixture.fleet.refreshChatIndex()
        await fixture.fleet.refreshSelected(fixture.target)
        await fixture.settle()
        #expect(fixture.fleet.hosts.first?.lastUpdated == lastSeen)
        #expect(await fixture.client.readIDs == ["A"])
        clock.advance(1)
        try await fixture.wait { await fixture.client.readIDs.count == 2 }
        await fixture.settle()
        #expect(await fixture.client.readIDs == ["A", "A"])
        #expect(fixture.unreadCount == 0)
        #expect(clock.waiterCount == 0)
    }

    @Test("An equal-height new reply waits for its own transcript layout", arguments: [false, true])
    func equalHeightReplacement(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        fixture.mount()
        defer { fixture.unmount() }
        try await fixture.wait { await fixture.client.readIDs == ["A"] }
        await fixture.client.replaceWithB()
        await fixture.fleet.refreshChatIndex()
        await fixture.settle()
        #expect(await fixture.client.readIDs == ["A"])
        #expect(fixture.unreadCount == 1)
        await fixture.fleet.refreshSelected(fixture.target)
        try await fixture.wait { await fixture.client.readIDs == ["A", "B"] }
        #expect(fixture.unreadCount == 0)
    }

    @Test("A collapsed additional response is not displayed read authority", arguments: [false, true])
    func collapsedResponse(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        await fixture.client.prepareAdditionalResponse()
        await fixture.fleet.refreshChatIndex()
        await fixture.fleet.refreshSelected(fixture.target)
        fixture.mount()
        defer { fixture.unmount() }
        await fixture.settle()
        #expect(await fixture.client.readIDs.isEmpty)
        #expect(fixture.unreadCount == 1)
    }

    @Test("A real scroll away prevents reads until a new bottom observation", arguments: [false, true])
    func scrollAway(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        await fixture.client.makeLongReply()
        await fixture.fleet.refreshSelected(fixture.target)
        fixture.presentation.tracking = false
        fixture.mount()
        defer { fixture.unmount() }
        await fixture.settle()
        let scroll = try #require(fixture.transcriptScrollView)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        await fixture.settle()
        fixture.presentation.tracking = true
        await fixture.settle()
        #expect(await fixture.client.readIDs.isEmpty)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await fixture.wait { await fixture.client.readIDs == ["A"] }
    }

    @Test("Changing displayed content cancels the old read without masking its newer reply", arguments: [false, true])
    func contentReplacement(lead: Bool) async throws {
        let fixture = try await ReadHostFixture(lead: lead)
        await fixture.client.setHeldReads(true)
        fixture.mount()
        defer { fixture.unmount() }
        try await fixture.wait { await fixture.client.readIDs == ["A"] }
        await fixture.client.replaceWithB()
        await fixture.fleet.refreshChatIndex()
        try await fixture.wait { await fixture.client.cancellations == 1 }
        #expect(fixture.unreadCount == 1)
        await fixture.fleet.refreshSelected(fixture.target)
        try await fixture.wait { await fixture.client.readIDs == ["A", "B"] }
        await fixture.client.finishRead()
        await fixture.settle()
        #expect(fixture.unreadCount == 0)
    }

    @Test("Retry deadlines are cancelled on coverage or source change", arguments: [false, true])
    func cancelledDeadline(lead: Bool) async throws {
        for replaceSource in [false, true] {
            let fixture = try await ReadHostFixture(lead: lead)
            let clock = ReadHostClock()
            fixture.fleet.chat.clock = { clock.now }
            fixture.fleet.chat.readSleep = { try await clock.sleep($0) }
            await fixture.client.failReads(1)
            fixture.mount()
            defer { fixture.unmount() }
            try await fixture.wait { clock.waiterCount == 1 }
            if replaceSource { fixture.fleet.activate(sources: [], connectionGeneration: 2) }
            else { fixture.presentation.topmost = false }
            try await fixture.wait { clock.waiterCount == 0 }
            clock.advance(180)
            await fixture.fleet.refreshChatIndex()
            await fixture.settle()
            #expect(await fixture.client.readIDs == ["A"])
            fixture.unmount()
        }
    }
}

@MainActor
private final class ReadHostClock {
    var now = Date(timeIntervalSince1970: 1_900_000_000)
    private var waiters: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    var waiterCount: Int { waiters.count }
    func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = (now.addingTimeInterval(interval), $0) }
        } onCancel: { Task { @MainActor in self.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) } }
    }
    func advance(_ interval: TimeInterval) {
        now.addTimeInterval(interval)
        for id in waiters.keys.filter({ waiters[$0]!.0 <= now }) { waiters.removeValue(forKey: id)?.1.resume() }
    }
}

@MainActor @Observable
private final class ReadHostPresentation {
    var topmost = true
    var phase = ScenePhase.active
    var mounted = true
    var tracking = true
    var inlineInfo = false
}

@MainActor
private struct ReadHostRoot: View {
    let fixture: ReadHostFixture
    var body: some View {
        if fixture.presentation.mounted {
            HStack(spacing: 0) {
                FirstMateChatScreen(model: fixture.model, fleet: fixture.fleet, store: fixture.store,
                    target: fixture.target, topmost: fixture.presentation.topmost, openInfo: { _, _ in },
                    readTrackingEnabled: fixture.presentation.tracking, embedded: fixture.presentation.inlineInfo)
                    .frame(maxWidth: .infinity)
                if fixture.presentation.inlineInfo {
                    FirstMateInfoScreen(model: fixture.model, fleet: fixture.fleet, store: fixture.store,
                        target: fixture.target, embedded: true).frame(width: 320)
                }
            }
            .environment(\.scenePhase, fixture.presentation.phase)
        }
    }
}

@MainActor
private final class ReadHostFixture {
    let model: HerdrAppModel
    let client: ReadHostClient
    let store: FirstMateStore
    let target = FirstMateFeatureTarget(machineID: "synthetic", featureID: "feature")
    let presentation = ReadHostPresentation()
    var window: UIWindow?
    weak var previousWindow: UIWindow?
    var transcriptScrollView: UIScrollView? {
        func find(_ view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(find)
        }
        // The fixed 402×874 host has one large transcript viewport. Reject an
        // ambiguous hierarchy instead of selecting a composer or first match.
        let candidates = window.map(find)?.filter { $0.bounds.height > 200 } ?? []
        return candidates.count == 1 ? candidates[0] : nil
    }
    var fleet: FirstMateMobileFleetStore { model.firstMateFleet }
    var unreadCount: Int {
        if store.leadSnapshot != nil {
            #expect(fleet.badgeCount == 0, "A lead reply must never contribute a feature dot")
            return fleet.chat.leadIsUnread(machineID: target.machineID, fleet: fleet) ? 1 : 0
        }
        return fleet.badgeCount
    }
    init(unread: Bool = true, lead: Bool = false, controllable: Bool = false) async throws {
        let configuredModel = HerdrAppModel(credentials: TestCredentialStore(), arguments: [],
            userDefaults: UserDefaults(suiteName: "ReadHost.\(UUID())")!, bootstrapMachines: [])
        model = configuredModel
        configuredModel.selectedTab = .firstMate
        let scriptedClient = ReadHostClient(unread: unread, lead: lead)
        client = scriptedClient
        let machine = ChatFixtures.machine("synthetic")
        if controllable {
            configuredModel.hasCompletedSetup = true
            configuredModel.machines = [machine]
            configuredModel.machineStates[machine.id] = .live
        }
        let fleet = configuredModel.firstMateFleet
        fleet.activate(sources: [.init(machine: machine,
            configuration: .init(urlString: machine.urlString, token: "synthetic"), client: scriptedClient)], connectionGeneration: 1)
        store = try #require(fleet.store(forMachineID: machine.id))
        await fleet.refreshAll()
        if lead { #expect(await fleet.chat.openLead(fleet: fleet) == target) }
        else { #expect(fleet.open(target)); await fleet.refreshSelected(target) }
    }
    func mount(width: CGFloat? = nil) {
        previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: ReadHostRoot(fixture: self))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("A mounted read host requires the test app's window scene")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width ?? (presentation.inlineInfo ? 900 : 402), height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        window.layoutIfNeeded()
        self.window = window
    }
    func unmount() {
        presentation.mounted = false
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousWindow?.makeKey()
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(180)) }
    func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            window?.rootViewController?.view.layoutIfNeeded()
            window?.layoutIfNeeded()
            guard ContinuousClock.now < deadline else { throw ChatTestTimeout(description: "mounted read host") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ReadHostClient: FirstMateClient {
    let feature: FirstMateFeature
    var unread: Bool
    var summaryID = "A"
    var snapshot: FirstMateSnapshot
    var holdReads = false
    var holdFetch = false
    var readFailures = 0
    private var readWaiters: [UUID: (String, CheckedContinuation<FirstMateReadResponse, any Error>)] = [:]
    private var fetchWaiter: CheckedContinuation<FirstMateSnapshot, any Error>?
    private(set) var cancellations = 0
    private(set) var readIDs: [String] = []
    var fetchHeld: Bool { fetchWaiter != nil }
    init(unread: Bool, lead: Bool) {
        self.unread = unread
        var feature = ChatFixtures.feature("feature", status: "blocked")
        if lead { feature.kind = "lead" }
        self.feature = feature
        snapshot = FirstMateSnapshot(feature: feature, messages: [Self.message("A")])
        if lead {
            var user = Self.message("U0"); user.role = "user"
            snapshot.messages.append(user); summaryID = "U0"
        }
    }
    static func message(_ id: String) -> FirstMateMessage {
        .init(id: id, featureID: "feature", role: "assistant", text: "Synthetic reply \(id)", status: "completed", createdAt: "2030-01-01T00:00:00Z")
    }
    func setHeldReads(_ value: Bool) { holdReads = value }
    func failReads(_ count: Int) { readFailures = count }
    func advanceSummaryToB() { summaryID = feature.isLead ? "U1" : "B"; unread = true; holdFetch = true }
    func replaceWithB() { summaryID = "B"; unread = true; snapshot.messages = [Self.message("B")] }
    func prepareAdditionalResponse() {
        summaryID = "B"; unread = true
        var main = Self.message("A"); main.metadata = .init(turnID: "turn", checkpoint: true)
        var closing = Self.message("B"); closing.metadata = .init(inReplyTo: "turn")
        snapshot.messages = [main, closing]
    }
    func makeLongReply() { snapshot.messages[0].text = Array(repeating: "Synthetic full paragraph for actual scroll testing.", count: 80).joined(separator: "\n\n") }
    func finishFetch(fail: Bool) {
        holdFetch = false
        if fail { fetchWaiter?.resume(throwing: APIError.server(status: 503, message: "Synthetic fetch failure")) }
        else {
            snapshot.messages.append(Self.message("B"))
            if summaryID == "U1" { var user = Self.message("U1"); user.role = "user"; snapshot.messages.append(user) }
            fetchWaiter?.resume(returning: snapshot)
        }
        fetchWaiter = nil
    }
    func finishRead() {
        let pending = readWaiters; readWaiters = [:]
        for (message, waiter) in pending.values { waiter.resume(returning: .init(featureID: feature.id, readThroughMessageID: message, unread: false)) }
    }
    private func cancelRead(_ id: UUID) {
        cancellations += 1
        readWaiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-v1", "first-mate-fleet-v1"] + (feature.isLead ? ["first-mate-lead-v1"] : []))
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: feature.isLead ? [] : [feature]) }
    func fetchFirstMateFleet() async throws -> FirstMateFleetResponse {
        .init(features: feature.isLead ? [] : [ChatFixtures.entry(feature.id, hud: .blocked, unread: unread, latestFirstMate: summaryID)])
    }
    func fetchFirstMateLead() async throws -> FirstMateLeadResponse {
        .init(ok: true, lead: .init(feature: feature, unread: unread, workingOnReply: false,
            latestMessage: .init(id: summaryID, role: summaryID.hasPrefix("U") ? "user" : "assistant", text: "Synthetic lead", createdAt: nil)))
    }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        if holdFetch { return try await withCheckedThrowingContinuation { fetchWaiter = $0 } }
        return snapshot
    }
    func markFirstMateRead(featureID: String, throughMessageID: String) async throws -> FirstMateReadResponse {
        readIDs.append(throughMessageID)
        if readFailures > 0 { readFailures -= 1; throw APIError.server(status: 503, message: "Synthetic read failure") }
        if !holdReads { return .init(featureID: featureID, readThroughMessageID: throughMessageID, unread: false) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { readWaiters[id] = (throughMessageID, $0) }
        } onCancel: { Task { await self.cancelRead(id) } }
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
