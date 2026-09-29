import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Mac chat sidebar presentation")
@MainActor
struct SidebarChatRowTests {
    @Test("Only a nonempty conventional Pi title prefix is hidden in the sidebar")
    func titleDecoration() {
        #expect(SidebarChatRow.sidebarTitle("π - Sample plan") == "Sample plan")
        for title in ["π - ", "π -", "π in an equation", "P - Plain", "Shell session", "Use π - inside text"] {
            #expect(SidebarChatRow.sidebarTitle(title) == title)
        }
    }

    @Test("Visible adjacency crosses model groups but not headings or hidden rows")
    func dividerBoundaries() {
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: []) == [])
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: [0, 0]) == [])
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: [1]) == [false])
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: [1, 0, 2]) == [false, true, true])
        // Recents/filter results and expanded families contain only visible rows.
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: [3]) == [false, true, true])
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: [1]) == [false]) // collapsed family
        // A new priority/tab heading starts a new run, not a second border.
        #expect(SidebarChatPresentation.dividerFlags(groupSizes: [2]) == [false, true])
    }

    @Test("Location is structured and preserves casing, duplicates, and missing fields")
    func location() throws {
        let pane = try #require(DemoData.workspaces.first?.panes.first).stamped(machineID: "machine-1")
        let workspace = try #require(DemoData.workspaces.first).stamped(machineID: "machine-1")
        let first = HerdrSidebarView.chatContext(for: pane, machineName: "Lab · Build", workspace: workspace)
        #expect(first.machine == "Lab · Build")
        #expect(first.workspace == workspace.label)
        #expect(first.tab == (workspace.tabs.first { $0.tabID == pane.tabID }?.label ?? "Untitled tab"))
        #expect(first.accessibilityLabel.contains("Machine: Lab · Build"))
        let duplicate = HerdrSidebarView.chatContext(for: pane, machineName: "Lab · Build", workspace: workspace)
        #expect(duplicate.machine == first.machine) // labels never supply identity
        let missing = HerdrSidebarView.chatContext(for: pane, machineName: nil, workspace: nil)
        #expect(missing.machine == "Unknown machine")
        #expect(missing.workspace == "Unknown workspace")
        #expect(missing.tab == "Untitled tab")
    }

    @Test("Recents uses activity then first-seen; All uses the matching status episode only")
    func ages() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = first.addingTimeInterval(120)
        let working = first.addingTimeInterval(240)
        let pane = HerdrPane(
            paneID: "w1:p1", terminalID: "t1", workspaceID: "w1", tabID: "w1:t1",
            focused: false, agentStatus: .working, revision: 0,
            cwd: nil, foregroundCWD: nil, label: "Sample", title: nil,
            agent: "pi", displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil,
            firstSeenAt: first, lastActivityAt: activity, workingSince: working
        ).stamped(machineID: "machine-1")
        #expect(HerdrSidebarView.recentSince(for: pane) == activity)
        #expect(HerdrSidebarView.statusSince(for: pane, alerts: []) == working)
        let otherMachine = HerdrAlert(
            id: "other", workspaceID: "w1", paneID: pane.paneID, status: .done,
            title: "Sample", message: "", createdAt: HerdrTimestamp.string(from: activity), isRead: false
        ).stamped(machineID: "machine-2")
        #expect(HerdrSidebarView.statusSince(for: pane, alerts: [otherMachine]) == working)
        let done = HerdrPane(
            paneID: pane.paneID, terminalID: "t1", workspaceID: "w1", tabID: "w1:t1",
            focused: false, agentStatus: .done, revision: 0,
            cwd: nil, foregroundCWD: nil, label: "Sample", title: nil,
            agent: "pi", displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil
        ).stamped(machineID: "machine-1")
        let matching = HerdrAlert(
            id: "matching", workspaceID: "w1", paneID: pane.paneID, status: .done,
            title: "Sample", message: "", createdAt: HerdrTimestamp.string(from: activity), isRead: false
        ).stamped(machineID: "machine-1")
        #expect(HerdrSidebarView.statusSince(for: done, alerts: [otherMachine]) == nil)
        #expect(HerdrSidebarView.statusSince(for: done, alerts: [otherMachine, matching]) == activity)
        let undated = HerdrPane(
            paneID: "w1:p2", terminalID: "t2", workspaceID: "w1", tabID: "w1:t1",
            focused: false, agentStatus: .idle, revision: 0,
            cwd: nil, foregroundCWD: nil, label: "No date", title: nil,
            agent: "pi", displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil
        ).stamped(machineID: "machine-1")
        #expect(HerdrSidebarView.recentSince(for: undated) == nil)
        #expect(HerdrSidebarView.statusSince(for: undated, alerts: []) == nil)
        let firstOnly = HerdrPane(
            paneID: "w1:p3", terminalID: "t3", workspaceID: "w1", tabID: "w1:t1",
            focused: false, agentStatus: .idle, revision: 0,
            cwd: nil, foregroundCWD: nil, label: "First seen", title: nil,
            agent: "pi", displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil,
            firstSeenAt: first
        ).stamped(machineID: "machine-1")
        #expect(HerdrSidebarView.recentSince(for: firstOnly) == first)
    }

    @Test("Every status retains a textual label even without a timestamp")
    func statuses() {
        #expect(AgentStatus.working.title == "Working")
        #expect(AgentStatus.done.title == "Ready")
        #expect(AgentStatus.blocked.title == "Needs you")
        #expect(AgentStatus.idle.title == "Idle")
        #expect(AgentStatus.unknown.title == "Shell")
    }
}
