import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("PR Review fleet sidebar", .serialized, .timeLimit(.minutes(1)))
struct PRReviewFleetSidebarTests {
    @Test("All machines renders both hosts with their machine captions")
    func rendersBothHosts() async throws {
        let fleet = makeFleet()
        await fleet.refresh()
        let store = PRReviewStore()
        // These flags describe only the default detail host, not the fleet.
        store.unconfigured = true
        store.unsupported = true
        store.error = "Synthetic default host is unsupported"
        let window = try await mount(PRReviewSidebarView(store: store, back: {}, fleet: fleet))
        defer { window.close() }

        let rows = reviewRows(in: window)
        #expect(rows.map { $0.accessibilityIdentifier() } == [
            rowID("host-a", "prr_a"), rowID("host-b", "prr_b"),
        ])
        let alpha = try #require(rows.first)
        let beta = try #require(rows.last)
        #expect(alpha.accessibilityLabel()?.contains("Seeds active Alpha") == true)
        #expect(alpha.accessibilityLabel()?.contains("Alpha Studio") == true)
        #expect(beta.accessibilityLabel()?.contains("Garden active Beta") == true)
        #expect(beta.accessibilityLabel()?.contains("Beta Forge") == true)
        #expect(!text(in: window).contains("Choose the PR review host"))
        #expect(!text(in: window).contains("Synthetic default host is unsupported"))
    }

    @Test("Duplicate review IDs render separate rows and selection includes the machine")
    func duplicateIDsAndSelection() async throws {
        var shared = review("prr_shared", title: "Same synthetic title")
        shared.walkthrough = .init(id: "synthetic-guide", state: "finished", baseSHA: shared.baseSHA, headSHA: shared.headSHA,
                                   comparisonID: nil, createdAt: "2026-01-01T00:00:00Z", finishedAt: "2026-01-01T00:01:00Z",
                                   seenAt: nil, error: nil, chapterCount: 3, needsAttention: true)
        let fleet = PRReviewFleetIndex()
        fleet.setSources([
            source("host-a", "Alpha Studio", active: [shared]),
            source("host-b", "Beta Forge", active: [shared]),
        ], identity: "duplicates")
        await fleet.refresh()
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "host-a", demo: false)
        store.select(shared.id)
        let window = try await mount(PRReviewSidebarView(store: store, back: {}, fleet: fleet))
        defer { window.close() }

        let rows = reviewRows(in: window)
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap { $0.accessibilityIdentifier() }) == [
            rowID("host-a", shared.id), rowID("host-b", shared.id),
        ])
        let alpha = try #require(rows.first { $0.accessibilityIdentifier() == rowID("host-a", shared.id) })
        let beta = try #require(rows.first { $0.accessibilityIdentifier() == rowID("host-b", shared.id) })
        #expect(alpha.isAccessibilitySelected())
        #expect(!beta.isAccessibilitySelected())
        #expect(alpha.accessibilityLabel()?.contains("Walkthrough ready") == true)
        #expect(beta.accessibilityLabel()?.contains("Walkthrough ready") == true)
        // SwiftUI combines a button's label into the row's AX element, so its
        // child identifier is checked through the same helper the label uses.
        let walkthroughIDs = fleet.active.map {
            PRReviewSidebarView.walkthroughAccessibilityIdentifier(reviewID: $0.review.id, rowID: $0.id.id)
        }
        #expect(Set(walkthroughIDs) == [
            "pr-review-walkthrough-host-a|prr_shared", "pr-review-walkthrough-host-b|prr_shared",
        ])
    }

    @Test("Search intersects Active and Archived across both hosts", arguments: [false, true])
    func filtersCombinedEntries(archived: Bool) async throws {
        let fleet = makeFleet()
        await fleet.refresh()
        let store = PRReviewStore()
        store.showArchived = archived
        let window = try await mount(PRReviewSidebarView(store: store, back: {}, fleet: fleet))
        defer { window.close() }
        let alphaID = rowID("host-a", archived ? "prr_a_old" : "prr_a")
        let betaID = rowID("host-b", archived ? "prr_b_old" : "prr_b")
        let queries: [(String, Set<String>)] = [
            ("", [alphaID, betaID]),
            ("SEEDS", [alphaID]),       // Title
            ("OWNER-BETA", [betaID]),   // Owner
            ("CATALOG", [alphaID]),     // Repository
            ("FORGE", [betaID]),        // Machine name only
            ("no synthetic match", []),
        ]
        for (query, expected) in queries {
            store.search = query
            try await pump(window)
            #expect(Set(reviewRows(in: window).compactMap { $0.accessibilityIdentifier() }) == expected,
                    "Search '\(query)' must filter the combined \(archived ? "Archived" : "Active") list")
        }
        store.search = ""
        store.showArchived.toggle()
        try await pump(window)
        #expect(Set(reviewRows(in: window).compactMap { $0.accessibilityIdentifier() }) == [
            rowID("host-a", archived ? "prr_a" : "prr_a_old"),
            rowID("host-b", archived ? "prr_b" : "prr_b_old"),
        ])
    }

    @Test("An unsupported or offline host notice does not hide a healthy host", arguments: [404, 501, 0])
    func rendersNoticeAlongsideRows(status: Int) async throws {
        let failure: any Error = status == 0
            ? SyntheticPRReviewSidebarError.offline
            : APIError.server(status: status, message: "Synthetic missing route")
        let fleet = PRReviewFleetIndex()
        fleet.setSources([
            source("host-a", "Alpha Studio", active: [review("prr_a", title: "Healthy synthetic review")]),
            .init(machineID: "host-b", machineName: "Beta Forge", client: SyntheticPRReviewSidebarClient(error: failure)),
        ], identity: "partial failure")
        await fleet.refresh()
        let window = try await mount(PRReviewSidebarView(store: PRReviewStore(), back: {}, fleet: fleet))
        defer { window.close() }

        #expect(reviewRows(in: window).compactMap { $0.accessibilityIdentifier() } == [rowID("host-a", "prr_a")])
        let message = status == 0
            ? "Synthetic companion is offline."
            : "Update this machine's companion for PR Review (pr-review-v1)."
        #expect(text(in: window).contains("Beta Forge: \(message)"))
        #expect(text(in: window).contains("Healthy synthetic review"))
    }

    @Test("Opening a fleet row passes its exact owner without selecting the detail store", arguments: [false, true])
    func openRoutesToOwner(callbackProvided: Bool) async throws {
        let fleet = makeFleet()
        await fleet.refresh()
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "host-a", demo: false)
        store.select("prr_current")
        store.snapshot = PRReviewDemo.snapshot()
        store.selectedPath = "Sources/Synthetic.swift"
        let originalSnapshot = store.snapshot
        var opened: [PRReviewWindowTarget] = []
        let callback: ((PRReviewWindowTarget) -> Void)? = callbackProvided ? { opened.append($0) } : nil
        let window = try await mount(PRReviewSidebarView(
            store: store, back: {}, fleet: fleet, openFleetReview: callback
        ))
        defer { window.close() }

        let beta = try #require(reviewRows(in: window).first { $0.accessibilityIdentifier() == rowID("host-b", "prr_b") })
        #expect(beta.accessibilityPerformPress())
        try await pump(window)

        #expect(opened == (callbackProvided ? [.init(machineID: "host-b", reviewID: "prr_b")] : []))
        #expect(store.currentMachineID == "host-a")
        #expect(store.selectedReviewID == "prr_current")
        #expect(store.snapshot == originalSnapshot)
        #expect(store.selectedPath == "Sources/Synthetic.swift")
    }

    @Test("No sources asks to pair a machine before and after loading", arguments: [false, true])
    func noSources(loaded: Bool) async throws {
        let fleet = PRReviewFleetIndex()
        fleet.setSources([], identity: "empty")
        if loaded { await fleet.refresh() }
        let store = PRReviewStore()
        store.unconfigured = true
        store.unsupported = true
        let window = try await mount(PRReviewSidebarView(store: store, back: {}, fleet: fleet))
        defer { window.close() }

        #expect(text(in: window).contains("Pair a machine in Settings → Machines"))
        #expect(!text(in: window).contains("Choose the PR review host"))
        #expect(reviewRows(in: window).isEmpty)
    }

    @Test("Configured empty fleets show loading until the first response", arguments: [false, true])
    func emptyBeforeAndAfterLoad(archived: Bool) async throws {
        let fleet = PRReviewFleetIndex()
        fleet.setSources([source("host-a", "Alpha Studio", active: [])], identity: "empty host")
        let store = PRReviewStore()
        store.showArchived = archived
        let window = try await mount(PRReviewSidebarView(store: store, back: {}, fleet: fleet))
        defer { window.close() }
        let message = archived ? "No archived reviews" : "No active reviews"

        #expect(!fleet.hasLoaded)
        #expect(text(in: window).contains("Loading reviews…"))
        #expect(!text(in: window).contains(message))
        #expect(elements(in: window).contains { $0.accessibilityIdentifier() == "pr-review-fleet-loading" })
        await fleet.refresh()
        try await pump(window)
        #expect(fleet.hasLoaded)
        #expect(!text(in: window).contains("Loading reviews…"))
        #expect(text(in: window).contains(message))
        #expect(reviewRows(in: window).isEmpty)
    }

    @Test("New review help explains an unavailable creation host", arguments: [false, true])
    func creationHostHelp(canControl: Bool) {
        let sidebar = PRReviewSidebarView(store: PRReviewStore(), back: {}, canControl: canControl)
        #expect(sidebar.newReviewHelp == (canControl
            ? "Start a pull request review"
            : "Choose a PR review host in Settings → Machines or pick a machine"))
    }

    @Test("Omitting fleet inputs keeps single-host rows and selection unchanged")
    func singleHostDefaults() async throws {
        let store = PRReviewStore()
        store.configure(client: nil, machineID: "host-a", demo: true)
        store.reviews = [review("prr_single", title: "Single-host synthetic review")]
        store.selectedPath = "Sources/Synthetic.swift"
        let window = try await mount(PRReviewSidebarView(store: store, back: {}))
        defer { window.close() }

        let rows = reviewRows(in: window)
        #expect(rows.compactMap { $0.accessibilityIdentifier() } == ["pr-review-review-prr_single"])
        let row = try #require(rows.first)
        #expect(row.accessibilityLabel()?.contains("Single-host synthetic review") == true)
        #expect(PRReviewSidebarView.walkthroughAccessibilityIdentifier(reviewID: "prr_single") == "pr-review-walkthrough-prr_single")
        #expect(row.accessibilityPerformPress())
        try await pump(window)
        #expect(store.currentMachineID == "host-a")
        #expect(store.selectedReviewID == "prr_single")
        #expect(store.selectedPath == nil)
    }

    // MARK: Synthetic fleet fixtures

    private func makeFleet() -> PRReviewFleetIndex {
        let fleet = PRReviewFleetIndex()
        fleet.setSources([
            source("host-a", "Alpha Studio", active: [
                review("prr_a", title: "Seeds active Alpha", owner: "owner-alpha", repo: "catalog"),
            ], archived: [
                review("prr_a_old", title: "Seeds archived Alpha", owner: "owner-alpha", repo: "catalog", archived: true),
            ]),
            source("host-b", "Beta Forge", active: [
                review("prr_b", title: "Garden active Beta", owner: "owner-beta", repo: "toolkit"),
            ], archived: [
                review("prr_b_old", title: "Garden archived Beta", owner: "owner-beta", repo: "toolkit", archived: true),
            ]),
        ], identity: "synthetic roster")
        return fleet
    }

    private func source(_ id: String, _ name: String, active: [PRReviewSummary], archived: [PRReviewSummary] = []) -> PRReviewFleetSource {
        .init(machineID: id, machineName: name, client: SyntheticPRReviewSidebarClient(active: active, archived: archived))
    }

    private func review(_ id: String, title: String, owner: String = "synthetic-owner", repo: String = "garden", archived: Bool = false) -> PRReviewSummary {
        var review = PRReviewDemo.snapshot().review
        review.id = id
        review.title = title
        review.owner = owner
        review.repo = repo
        review.url = "https://github.com/\(owner)/\(repo)/pull/7"
        review.number = 7
        review.archivedAt = archived ? "2026-01-01T00:00:00Z" : nil
        return review
    }

    private func rowID(_ machineID: String, _ reviewID: String) -> String {
        "pr-review-review-\(PRReviewWindowTarget(machineID: machineID, reviewID: reviewID).id)"
    }

    // MARK: Offscreen SwiftUI hosting and accessibility

    private func mount(_ view: some View) async throws -> SidebarTestHost {
        // SwiftUI creates its virtual AX tree only when enhanced accessibility
        // is enabled. This is local to the test app and restored on close.
        let previousAccessibility = NSApp.accessibilityAttributeValue(SidebarTestHost.accessibilityAttribute)
        NSApp.accessibilitySetValue(true, forAttribute: SidebarTestHost.accessibilityAttribute)
        let size = CGSize(width: 440, height: 820)
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        let host = SidebarTestHost(window: window, previousAccessibility: previousAccessibility)
        do {
            try await pump(host)
            return host
        } catch {
            host.close()
            throw error
        }
    }

    private func pump(_ host: SidebarTestHost) async throws {
        guard let hosting = host.window.contentView else { return }
        // Match the existing PR Review hosting tests: lazy rows need run-loop
        // turns to materialize, without any network or UI automation permission.
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            host.window.displayIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func elements(in host: SidebarTestHost) -> [SidebarAccessibilityElement] {
        guard let hosting = host.window.contentView else { return [] }
        var seen: Set<ObjectIdentifier> = []
        func walk(_ object: NSObject) -> [SidebarAccessibilityElement] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = SidebarAccessibilityElement(object: object)
            let children = (object as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
            return [element] + children.flatMap(walk)
        }
        return walk(hosting)
    }

    private func reviewRows(in window: SidebarTestHost) -> [SidebarAccessibilityElement] {
        elements(in: window).filter { $0.accessibilityIdentifier()?.hasPrefix("pr-review-review-") == true }
    }

    private func text(in window: SidebarTestHost) -> String {
        elements(in: window).flatMap {
            [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 }
        }.joined(separator: "\n")
    }
}

@MainActor
private struct SidebarTestHost {
    static let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    let window: NSWindow
    let previousAccessibility: Any?

    func close() {
        window.close()
        NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: Self.accessibilityAttribute)
    }
}

/// SwiftUI's virtual nodes implement AppKit's accessibility selectors without
/// declaring NSAccessibilityProtocol conformance. Query those selectors locally;
/// no AX trust or UI automation is used.
@MainActor
private struct SidebarAccessibilityElement {
    let object: NSObject

    func accessibilityIdentifier() -> String? {
        (object as AnyObject).accessibilityIdentifier?() ?? nil
    }

    func accessibilityLabel() -> String? {
        (object as AnyObject).accessibilityLabel?() ?? nil
    }

    func accessibilityValue() -> Any? {
        (object as AnyObject).accessibilityValue?() ?? nil
    }

    func isAccessibilitySelected() -> Bool {
        (object as AnyObject).isAccessibilitySelected?() ?? false
    }

    func accessibilityPerformPress() -> Bool {
        (object as AnyObject).accessibilityPerformPress?() ?? false
    }
}

private enum SyntheticPRReviewSidebarError: LocalizedError {
    case offline
    var errorDescription: String? { "Synthetic companion is offline." }
}

/// Only the two list endpoints are valid in a sidebar fixture. Unexpected
/// default-host requests fail rather than masking cross-machine routing bugs.
private actor SyntheticPRReviewSidebarClient: PRReviewClient {
    let active: [PRReviewSummary]
    let archived: [PRReviewSummary]
    let error: (any Error)?

    init(active: [PRReviewSummary] = [], archived: [PRReviewSummary] = [], error: (any Error)? = nil) {
        self.active = active
        self.archived = archived
        self.error = error
    }

    func prReviews(scope: String) async throws -> [PRReviewSummary] {
        if let error { throw error }
        return scope == "archived" ? archived : active
    }
    func prReviewCapabilities() async throws -> PRReviewCapabilities { throw APIError.invalidResponse }
    func prReviewSkills() async throws -> [PRReviewSkill] { throw APIError.invalidResponse }
    func addPRReviewSkill(_ body: PRReviewSkillCreateRequest) async throws -> PRReviewSkill { throw APIError.invalidResponse }
    func removePRReviewSkill(id: String, requestID: String) async throws -> [PRReviewSkill] { throw APIError.invalidResponse }
    func createPRReview(url: String, skillIDs: [String], requestID: String) async throws -> PRReviewSnapshot { throw APIError.invalidResponse }
    func prReview(id: String) async throws -> PRReviewSnapshot { throw APIError.invalidResponse }
    func refreshPRReview(id: String, requestID: String) async throws -> PRReviewSnapshot { throw APIError.invalidResponse }
    func archivePRReview(id: String, archived: Bool, requestID: String) async throws -> PRReviewSnapshot { throw APIError.invalidResponse }
    func prReviewDiff(id: String, path: String?) async throws -> PRReviewDiff { throw APIError.invalidResponse }
    func prReviewFileText(id: String, path: String, side: PRReviewSide, start: Int?, end: Int?) async throws -> PRReviewFileText { throw APIError.invalidResponse }
    func prReviewFindings(id: String, path: String) async throws -> PRReviewFindings { throw APIError.invalidResponse }
    func createPRReviewRun(id: String, skillID: String, requestID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRun(reviewID: String, runID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func finishPRReviewRun(reviewID: String, runID: String, state: PRReviewRunState, note: String?, requestID: String) async throws -> PRReviewRun { throw APIError.invalidResponse }
    func prReviewRunOutput(reviewID: String, runID: String, lines: Int) async throws -> String { throw APIError.invalidResponse }
    func markPRReviewSkill(reviewID: String, skillID: String, state: String, note: String?, requestID: String) async throws -> PRReviewSkillState { throw APIError.invalidResponse }
    func rankPRReview(id: String, requestID: String) async throws -> PRReviewSummary { throw APIError.invalidResponse }
    func setPRReviewRankings(id: String, files: [[String: String]], requestID: String) async throws -> [PRReviewFile] { throw APIError.invalidResponse }
    func setPRReviewViewed(id: String, paths: [String], viewed: Bool, requestID: String) async throws -> [PRReviewFile] { throw APIError.invalidResponse }
    func syncPRReviewViewed(id: String, requestID: String) async throws -> [PRReviewFile] { throw APIError.invalidResponse }
    func prReviewDocuments(id: String) async throws -> [PRReviewDocument] { throw APIError.invalidResponse }
    func addPRReviewDocument(id: String, payload: PRReviewDocumentPayload, requestID: String) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func prReviewDocument(reviewID: String, documentID: String) async throws -> PRReviewDocument { throw APIError.invalidResponse }
    func downloadPRReviewDocument(reviewID: String, documentID: String, expectedByteSize: Int64, to destinationURL: URL) async throws { throw APIError.invalidResponse }
    func prReviewEvents(id: String, after: Int?) async throws -> [PRReviewEvent] { throw APIError.invalidResponse }
}
