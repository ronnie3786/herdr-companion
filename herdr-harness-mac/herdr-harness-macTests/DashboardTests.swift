import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Dashboard behavior", .serialized)
@MainActor
struct DashboardTests {
    @Test("Equal message timestamps preserve the server conversation order")
    func timelineOrder() {
        let snapshot = FirstMateDemo.features(step: 2)[0]
        let content = AgentBoardContent.build(from: .adapting(snapshot))
        #expect(content.timeline.map(\.id) == snapshot.messages.filter { ["user", "human", "assistant"].contains($0.role) }.map(\.id))
    }

    @Test("A 20,000-event feature builds bounded column content quickly and keeps its journal out of chat")
    func largeFeature() {
        var snapshot = FirstMateDemo.features(step: 2)[0]
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let types = ["pi.message_end", "pi.tool_execution_start", "pi.tool_execution_end", "pi.context_usage"]
        snapshot.events = (1...20_000).map { index in
            FirstMateEvent(sequence: index, id: "e\(index)", featureID: snapshot.feature.id,
                           type: index.isMultiple(of: 400) ? "visit.completed" : types[index % types.count],
                           summary: "Event \(index)", createdAt: HerdrTimestamp.string(from: base.addingTimeInterval(Double(index))))
        }
        let clock = ContinuousClock()
        var content: AgentBoardContent?
        let elapsed = clock.measure { content = AgentBoardContent.build(from: .adapting(snapshot)) }
        #expect(elapsed < .milliseconds(500))
        #expect(content?.timeline.map(\.id) == snapshot.messages.map(\.id))
        let notes = content?.latestNotes.map(\.text) ?? []
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { text in text.hasPrefix("Event ") && Int(text.dropFirst(6))!.isMultiple(of: 400) })
    }

    @Test("Chat shows only the conversation; journal milestones collapse into Overview")
    func noteCollapsing() {
        var snapshot = FirstMateDemo.features(step: 2)[0]
        let id = snapshot.feature.id
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func at(_ seconds: Double) -> String { HerdrTimestamp.string(from: base.addingTimeInterval(seconds)) }
        snapshot.messages = [.init(id: "m1", featureID: id, role: "user", text: "Go ahead", status: "done", createdAt: at(30))]
        snapshot.events = [
            FirstMateEvent(sequence: 1, id: "e1", featureID: id, type: "visit.completed", summary: "Planning complete", createdAt: at(0)),
            FirstMateEvent(sequence: 2, id: "e2", featureID: id, type: "visit.started", summary: "Implementation started", createdAt: at(40)),
            FirstMateEvent(sequence: 3, id: "e3", featureID: id, type: "assignment.queued", summary: "Worker queued", createdAt: at(41)),
            FirstMateEvent(sequence: 4, id: "e4", featureID: id, type: "assignment.queued", summary: "Worker queued", createdAt: at(42)),
            FirstMateEvent(sequence: 5, id: "e5", featureID: id, type: "session.bound", summary: "Saved Pi session attached", createdAt: at(43)),
        ]
        let content = AgentBoardContent.build(from: .adapting(snapshot))
        #expect(content.timeline.map(\.id) == ["m1"])
        let journal = content.latestNotes.map { $0.count > 1 ? "\($0.text) ×\($0.count)" : $0.text }
        #expect(journal == ["Worker queued ×2", "Implementation started", "Planning complete"])
    }

    @Test("Background replies and system updates never reach the chat, and a private note journals")
    func backgroundRowsStayOutOfChat() {
        var snapshot = FirstMateDemo.features(step: 2)[0]
        let id = snapshot.feature.id
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func at(_ seconds: Double) -> String { HerdrTimestamp.string(from: base.addingTimeInterval(seconds)) }
        snapshot.messages = [
            .init(id: "direction", featureID: id, role: "user", text: "Build it", status: "done", createdAt: at(0)),
            .init(id: "update", featureID: id, role: "system", text: "Lane 1 reported success", status: "done",
                  createdAt: at(10), visibility: "background"),
            .init(id: "chatter", featureID: id, role: "assistant", text: "Lane 1 closed out clean.", status: "done",
                  createdAt: at(11), visibility: "background"),
            .init(id: "checkpoint", featureID: id, role: "assistant", text: "Stage done. Awaiting your direction.",
                  status: "done", createdAt: at(12), visibility: "conversation"),
            .init(id: "legacy", featureID: id, role: "assistant", text: "Older companions omit visibility.",
                  status: "done", createdAt: at(13)),
        ]
        snapshot.events = [FirstMateEvent(sequence: 1, id: "note", featureID: id, type: "coordinator.note",
                                          summary: "Waiting on lane 2.", createdAt: at(11))]
        let content = AgentBoardContent.build(from: .adapting(snapshot))
        #expect(content.timeline.map(\.id) == ["direction", "checkpoint", "legacy"])
        #expect(content.earlierMessageCount == 0)
        #expect(content.latestNotes.map(\.text) == ["Waiting on lane 2."])
        #expect(FirstMateDashboardSummary.from(snapshot).latestMessage == "Older companions omit visibility.")
    }

    @Test("Message rows compare by their source text, not their styled runs")
    func messageRowEquality() {
        let snapshot = FirstMateDemo.features(step: 2)[0]
        let first = AgentBoardContent.build(from: .adapting(snapshot))
        let second = AgentBoardContent.build(from: .adapting(snapshot))
        #expect(first == second)
        var changed = snapshot
        changed.messages[changed.messages.count - 1].text += " More."
        #expect(AgentBoardContent.build(from: .adapting(changed)) != first)
    }

    @Test("Card text drops repeated ticket prefixes, markdown, and HTML entities")
    func cardText() {
        var feature = FirstMateFeature(id: "f", title: "APP-12 — Offline &amp; sync notes", goal: "Keep **notes** safe",
                                       cwd: "/tmp/synthetic", status: "awaiting_direction", currentVisitID: nil, revision: 1,
                                       createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        feature.workItemID = "APP-12"
        feature.dashboardSummary = .init(currentStageTitle: "Plan", currentStageIndex: 1, stageCount: 1,
                                         latestMessage: "The **second** review is in — `PR #12` is *approved*:",
                                         latestMessageAt: nil, needsUser: true,
                                         needsUserPrompt: "## Choose\n- **A**: merge\n- B: wait",
                                         assignmentCount: 2, runningAssignmentCount: 0)
        let entry = DashboardFeatureEntry(machineID: "m", machineName: "Mac", feature: feature)
        #expect(entry.title == "Offline & sync notes")
        #expect(entry.preview == "The second review is in — PR #12 is approved:")
        #expect(entry.attentionPrompt == "Choose. A: merge · B: wait")
        #expect(AgentBoardProse.plainText(fromMarkdown: "Done\n\n- Two approvals\n- `ios_core` pending\n\nMerge?")
                == "Done. Two approvals · ios_core pending. Merge?")
        #expect(AgentBoardContent.displayTitle("APP-12: Fix", workItemID: "APP-12") == "Fix")
        #expect(AgentBoardContent.displayTitle("APP-12", workItemID: "APP-12") == "APP-12")
        #expect(AgentBoardContent.displayTitle("APP-120 fix", workItemID: nil) == "APP-120 fix")
        #expect(AgentBoardProse.decodeEntities("iOS platform &amp; architecture &amp;lt;lead&amp;gt;") == "iOS platform & architecture &lt;lead&gt;")
        #expect(AgentBoardProse.readable("planning_lead") == "planning lead")
    }

    @Test("Assistant replies render as compact blocks with resolved inline markdown")
    func compactProse() {
        let blocks = AgentBoardProse.blocks(from: "# Plan\n\nUse **bold** and `code`.\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
        #expect(blocks.count == 6)
        if case .heading(_, let text) = blocks[0] { #expect(String(text.characters) == "Plan") } else { Issue.record("heading") }
        if case .paragraph(_, let text) = blocks[1] { #expect(String(text.characters) == "Use bold and code.") } else { Issue.record("paragraph") }
        if case .listItem(_, let marker, _, _) = blocks[2] { #expect(marker == "•") } else { Issue.record("list") }
        if case .code(_, let code) = blocks[4] { #expect(code == "let x = 1") } else { Issue.record("code") }
        if case .notice = blocks[5] {} else { Issue.record("table notice") }
    }

    @Test("Agents list running work first and decode role text")
    func agentOrdering() {
        var snapshot = FirstMateDemo.features(step: 2)[0]
        let template = snapshot.assignments[0]
        snapshot.assignments = [("done", "completed"), ("run", "running"), ("fail", "failed"), ("wait", "queued")].map { id, status in
            var agent = template
            agent.id = id
            agent.status = status
            agent.role = "iOS platform &amp; architecture_lead"
            return agent
        }
        let agents = AgentBoardContent.build(from: .adapting(snapshot)).agents
        #expect(agents.map(\.id) == ["run", "wait", "fail", "done"])
        #expect(agents[0].roleLabel == "iOS platform & architecture lead")
    }

    @Test("Dashboard launches first and both new destinations survive navigation history")
    func navigation() throws {
        let defaults = isolatedDefaults()
        let shell = HerdrShellState(userDefaults: defaults)
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        #expect(shell.detailScope == .dashboard)
        #expect(shell.resolvedScope(for: model) == .dashboard)
        shell.recordVisit(for: model)
        shell.show(.agentBoard, model: model)
        shell.show(.firstMate, model: model)
        #expect(shell.goBack(model: model))
        #expect(shell.detailScope == .agentBoard)
        #expect(shell.goBack(model: model))
        #expect(shell.detailScope == .dashboard)
        #expect(shell.goForward(model: model))
        #expect(shell.detailScope == .agentBoard)
        #expect(HerdrDestinationRecord(.dashboard)?.destination == .dashboard)
        #expect(HerdrDestinationRecord(.agentBoard)?.destination == .agentBoard)
        #expect(HerdrDetailScope.pickerSelection(for: .dashboard) == nil)
        let pane = try #require(model.workspaces.first?.panes.first)
        shell.openPane(id: pane.id, model: model)
        #expect(shell.resolvedScope(for: model) == .session)
        #expect(model.selectedPaneID == pane.id)
    }

    @Test("Going home from a screen opened there steps back instead of stacking history")
    func goHome() {
        let shell = HerdrShellState(userDefaults: isolatedDefaults())
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        shell.recordVisit(for: model)
        for _ in 0..<3 {
            shell.show(.prReview, model: model)
            shell.goHome(model: model)
        }
        #expect(shell.detailScope == .dashboard)
        #expect(shell.history.backward.isEmpty)
        #expect(shell.canGoForward)
        shell.show(.agentBoard, model: model)
        shell.show(.firstMate, model: model)
        shell.goHome(model: model)
        #expect(shell.detailScope == .dashboard)
        #expect(shell.canGoBack)
    }

    @Test("Sidebar visibility is remembered separately for home screens and other screens")
    func sidebarPreference() {
        let defaults = isolatedDefaults()
        let shell = HerdrShellState(userDefaults: defaults)
        #expect(shell.sidebarVisibility(home: true) == .detailOnly)
        #expect(shell.sidebarVisibility(home: false) == .all)
        shell.rememberSidebarVisibility(.all, home: true)
        shell.rememberSidebarVisibility(.detailOnly, home: false)
        let restored = HerdrShellState(userDefaults: defaults)
        #expect(restored.sidebarVisibility(home: true) == .all)
        #expect(restored.sidebarVisibility(home: false) == .detailOnly)
        #expect(HerdrDetailScope.dashboard.isHome && HerdrDetailScope.agentBoard.isHome && !HerdrDetailScope.firstMate.isHome)
    }

    @Test("Columns fill the window when they fit and leave a peek when they do not")
    func columnWidths() {
        #expect(abs(AgentBoardView.columnWidth(for: 1240, count: 3) - CGFloat(1240 - 32 - 28) / 3) < 0.5)
        #expect(abs(AgentBoardView.columnWidth(for: 1764, count: 3) - CGFloat(1764 - 32 - 28) / 3) < 0.5)
        let peeking = AgentBoardView.columnWidth(for: 1764, count: 5)
        #expect(peeking * 3 + 14 * 3 < 1764 - 32)
        #expect(AgentBoardView.columnWidth(for: 2560, count: 1) == 720)
        // One wide column plus a peek of the next on a narrow window.
        let narrow = AgentBoardView.columnWidth(for: 700, count: 3)
        #expect(narrow >= 340 && narrow + 14 < 700 - 32)
        let card = DashboardFirstMatesSection.cardWidth(for: 1240)
        #expect(card >= 300 && card * 3 + 48 + 48 < 1240)
        #expect(DashboardFirstMatesSection.cardWidth(for: 2560) == 560)
    }

    @Test("Recent chats leave out PR Review workers and apply Focus before the limit")
    func recentChats() throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let workspaces = model.workspaces
        let reviewLabel = try #require(workspaces.first?.label)
        let rows = DashboardChatsSection.rows(workspaces: workspaces, machineID: "", excludedWorkspaceLabel: "PR Reviews",
                                              query: "", focusMode: false)
        #expect(!rows.isEmpty)
        #expect(rows.count <= SidebarRecency.recentsLimit)
        #expect(rows.allSatisfy { !$0.reservedShell })
        // Treat the first demo workspace as the review workers' workspace.
        let excluded = DashboardChatsSection.rows(workspaces: workspaces, machineID: "", excludedWorkspaceLabel: reviewLabel,
                                                  query: "", focusMode: false)
        let excludedIDs = Set(workspaces.filter { $0.label == reviewLabel }.flatMap(\.panes).map(\.id))
        #expect(!excluded.contains { excludedIDs.contains($0.id) })
        let focused = DashboardChatsSection.rows(workspaces: workspaces, machineID: "", excludedWorkspaceLabel: "PR Reviews",
                                                 query: "", focusMode: true)
        #expect(focused.allSatisfy { $0.agentStatus == .blocked })
    }

    @Test("Focus hides nonwaiting work, rejects unknown states, and respects machine identity")
    func featureFiltering() {
        let statuses = ["paused", "running", "blocked", "awaiting_direction", "recovering", "future_status", "completed", "cancelled", "archived"]
        var entries = statuses.map { entry($0) }
        entries.append(entry("awaiting_direction", machineID: "other"))
        entries.append(entries[2])
        let focused = DashboardFeatureEntry.ordered(entries, focusMode: true)
        #expect(focused.map(\.feature.status) == ["awaiting_direction", "awaiting_direction", "blocked"])
        #expect(Set(focused.map(\.id)).count == 3)
        #expect(DashboardFeatureEntry.ordered(entries).count == 7)
        #expect(DashboardFeatureEntry.ordered(entries, query: "running").count == 1)
        var archived = entry("blocked")
        var feature = archived.feature
        feature.archivedAt = "2026-01-01T00:00:00Z"
        archived = .init(machineID: "a", machineName: "A", feature: feature)
        #expect(DashboardFeatureEntry.ordered([archived], focusMode: true).isEmpty)
    }

    @Test("Ordering uses conversation activity, not telemetry-driven update times")
    func activityOrdering() {
        var busy = entry("running", machineID: "busy").feature
        busy.updatedAt = "2026-01-01T12:00:00Z"
        busy.dashboardSummary = summary(activityAt: "2026-01-01T08:00:00Z")
        var recent = entry("running", machineID: "recent").feature
        recent.updatedAt = "2026-01-01T09:00:00Z"
        recent.dashboardSummary = summary(activityAt: "2026-01-01T09:00:00Z")
        let ordered = DashboardFeatureEntry.ordered([
            .init(machineID: "busy", machineName: "Busy", feature: busy),
            .init(machineID: "recent", machineName: "Recent", feature: recent),
        ])
        #expect(ordered.map(\.machineID) == ["recent", "busy"])
    }

    @Test("Focus mode and the independent chat machine filter survive relaunch")
    func persistence() {
        let defaults = isolatedDefaults()
        let state = DashboardState(defaults: defaults)
        state.focusMode = true
        state.recentMachineID = "synthetic-machine"
        let restored = DashboardState(defaults: defaults)
        #expect(restored.focusMode)
        #expect(restored.recentMachineID == "synthetic-machine")
    }

    @Test("Review filtering never confuses approval or unavailable data with waiting for me")
    func reviewFiltering() throws {
        var reviews = try ["approved", "pending", "re_review_requested", "not_reviewed", "unknown", "future_state"].enumerated().map { index, status in
            var review = try JSONDecoder().decode(PRReviewSummary.self, from: Data("{\"id\":\"review-\(index)\"}".utf8))
            review.viewerReview = .init(state: status, needsUser: true)
            return review
        }
        var own = reviews[1]
        own.id = "own"
        own.viewerReview?.isOwnPR = true
        reviews.append(own)
        var archived = reviews[2]
        archived.id = "archived"
        archived.archivedAt = "2026-01-01T00:00:00Z"
        reviews.append(archived)
        #expect(DashboardReviewPresentation.filtered(reviews, focusMode: true, query: "").map(\.id) == ["review-1", "review-2"])
        #expect(DashboardReviewPresentation.filtered(reviews, focusMode: false, query: "").count == 6)
        #expect(DashboardReviewState(state: "future", needsUser: true).needsAttention == false)
    }

    @Test("Old companion payloads remain decodable without dashboard fields")
    func compatibility() throws {
        let feature = entry("running").feature
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feature)) as? [String: Any])
        object.removeValue(forKey: "dashboard_summary")
        let decoded = try JSONDecoder().decode(FirstMateFeature.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.dashboardSummary == nil)
        let review = try JSONDecoder().decode(PRReviewSummary.self, from: Data("{\"id\":\"legacy\"}".utf8))
        #expect(review.viewerReview == nil)
        #expect(review.skillRuns == nil)
        #expect(DashboardReviewPresentation.filtered([review], focusMode: true, query: "").isEmpty)
    }

    @Test("A journal-only snapshot with a server cursor is never mistaken for an older one")
    func eventCursor() {
        let store = FirstMateStore()
        store.configure(client: nil, demo: true)
        var full = FirstMateDemo.features(step: 2)[0]
        full.events = (1...10).map { FirstMateEvent(sequence: $0, id: "e\($0)", featureID: full.feature.id, type: "pi.message_end",
                                                    summary: "", createdAt: "2026-01-01T00:00:00Z") }
        store.receive(full)
        var journal = full
        journal.events = [FirstMateEvent(sequence: 4, id: "e4", featureID: full.feature.id, type: "visit.started",
                                         summary: "Started", createdAt: "2026-01-01T00:00:00Z")]
        journal.messages.append(.init(id: "new", featureID: full.feature.id, role: "assistant", text: "New reply",
                                      status: "done", createdAt: "2026-01-01T00:00:00Z"))
        journal.eventCursor = 11
        store.receive(journal)
        #expect(store.snapshots[full.feature.id]?.messages.last?.id == "new")
    }

    @Test("Dashboard cards open the owning machine and Overview")
    func firstMateRouting() {
        let shell = HerdrShellState(userDefaults: isolatedDefaults())
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        shell.showFirstMate(machineID: "machine-b", featureID: "same-id", inspector: .overview, model: model)
        #expect(shell.detailScope == .firstMate)
        #expect(shell.firstMateMachineID == "machine-b")
        #expect(shell.pendingFirstMateControlTarget?.featureID == "same-id")
        #expect(shell.pendingFirstMateControlTarget?.inspector == .overview)
    }

    @Test("Older equal-revision snapshots cannot replace newer GitHub viewer state")
    func reviewFreshness() async {
        let store = PRReviewStore()
        store.configure(client: TestPRReviewClient(), machineID: "synthetic", demo: false)
        var old = PRReviewDemo.snapshot()
        old.review.viewerReview = .init(state: "pending", checkedAt: "2026-01-01T00:00:00Z")
        store.receive(old)
        store.reviews[0].viewerReview = .init(state: "approved", checkedAt: "2026-01-01T00:01:00Z")
        store.receive(old)
        #expect(store.reviews[0].viewerReview?.state == "approved")
        #expect(store.snapshot?.review.viewerReview?.state == "approved")
        var failed = old.review
        failed.viewerReview = .init(state: "approved", checkedAt: "2026-01-01T00:02:00Z", error: "Offline")
        #expect(failed.retainingNewerViewerState(from: store.reviews[0]).viewerReview?.error == "Offline")
        // The newer failed attempt stays stale instead of an old success erasing its warning.
        #expect(old.review.retainingNewerViewerState(from: failed).viewerReview?.error == "Offline")
        store.unsupported = true
        _ = await store.refreshDashboard()
        #expect(!store.unsupported)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DashboardTests.\(UUID().uuidString)")!
    }
    private func summary(activityAt: String) -> FirstMateDashboardSummary {
        .init(currentStageTitle: nil, currentStageIndex: nil, stageCount: 0, latestMessage: nil, latestMessageAt: nil,
              needsUser: false, needsUserPrompt: nil, assignmentCount: 0, runningAssignmentCount: 0, activityAt: activityAt)
    }
    private func entry(_ status: String, machineID: String = "synthetic") -> DashboardFeatureEntry {
        let feature = FirstMateFeature(id: status, title: status, goal: "Synthetic goal", cwd: "/tmp/synthetic", status: status,
            currentVisitID: nil, revision: 1, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        return .init(machineID: machineID, machineName: "Synthetic Mac", feature: feature)
    }
}
