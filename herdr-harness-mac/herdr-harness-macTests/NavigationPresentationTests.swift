import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Navigation presentation")
struct NavigationPresentationTests {
    @Test("Date picker exposes exactly All, Today, and Recents in order")
    func recencyPickerCases() {
        #expect(SidebarRecency.pickerCases == [.all, .today, .recents])
        #expect(SidebarRecency.pickerCases.map(\.title) == ["All", "Today", "Recents"])
    }

    @Test("Legacy persisted date ranges migrate to All", arguments: ["last3Days", "thisWeek"])
    func legacyRecencyMigration(rawValue: String) throws {
        let suiteName = "NavigationPresentationTests.recency.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(rawValue, forKey: SidebarRecency.defaultsKey)

        #expect(SidebarRecency.load(from: defaults) == .all)
        #expect(defaults.string(forKey: SidebarRecency.defaultsKey) == SidebarRecency.all.rawValue)
    }

    @Test("No machines hide the picker, three use segments, and four use a menu")
    func machinePickerBoundary() {
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 0) == .hidden)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 3) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 4) == .menu)
    }

    @Test("Git window identity includes machine, workspace, and pane")
    func gitWindowIdentity() throws {
        let workspace = try #require(DemoData.workspaces.first?.stamped(machineID: "machine-a"))
        let pane = try #require(workspace.panes.first)
        let target = WorkspaceGitWindowTarget(pane: pane)

        #expect(target.scopedPaneID == pane.id)
        #expect(target == WorkspaceGitWindowTarget(pane: pane))
        #expect(target != WorkspaceGitWindowTarget(
            machineID: pane.machineID,
            workspaceID: pane.workspaceID,
            paneID: "another-pane"
        ))
        #expect(try JSONDecoder().decode(
            WorkspaceGitWindowTarget.self,
            from: JSONEncoder().encode(target)
        ) == target)
    }

    @Test("Git window route stays pinned to its machine and workspace")
    func gitWindowRouting() throws {
        let source = try #require(DemoData.workspaces.first)
        let expected = source.stamped(machineID: "machine-a")
        let sameRawIDsOnAnotherMachine = source.stamped(machineID: "machine-b")
        let pane = try #require(expected.panes.first)
        let target = WorkspaceGitWindowTarget(pane: pane)

        let route = try #require(target.resolve(in: [sameRawIDsOnAnotherMachine, expected]))
        #expect(route.workspace.id == expected.id)
        #expect(route.pane.id == pane.id)
        #expect(target.resolve(in: [sameRawIDsOnAnotherMachine]) == nil)
    }
}
