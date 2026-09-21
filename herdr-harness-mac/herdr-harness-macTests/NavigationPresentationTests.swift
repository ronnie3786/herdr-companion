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

    @Test("Picker boundaries stay hidden, segmented, then full-name menu from zero through four machines")
    func machinePickerBoundary() {
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 0) == .hidden)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 1) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 2) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 3) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 4) == .menu)
    }

    @Test("Configured labels and partial orders are independent of names roles and IDs")
    func configuredPresentation() {
        let machines = [
            machine(id: UUID().uuidString, name: "Arbitrary One", role: "work", label: nil, order: nil),
            machine(id: "not-a-config-id", name: "Other Computer", role: "local", label: "Build", order: 8),
            machine(id: "third", name: "Completely Different", role: "development", label: "Lab", order: 2),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Lab", "Build", "Arbitrary One"])
        #expect(segments.map(\.id) == [machines[2].id, machines[1].id, machines[0].id])
        #expect(segments.map(\.name) == [machines[2].name, machines[1].name, machines[0].name])
    }

    @Test("Absent labels preserve full configured names and roster order")
    func absentPresentationMetadata() {
        let machines = [
            machine(id: "z", name: "Zulu Computer"),
            machine(id: "a", name: "Alpha Computer"),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Zulu Computer", "Alpha Computer"])
        #expect(segments.map(\.id) == ["z", "a"])
    }

    @Test("Equal orders and unordered machines retain saved roster order")
    func tiesAndPartialOrdersAreStable() {
        let machines = [
            machine(id: "unordered-a", name: "First"),
            machine(id: "ordered-a", name: "Second", label: "Build", order: 4),
            machine(id: "ordered-b", name: "Third", label: "Lab", order: 4),
            machine(id: "unordered-b", name: "Fourth"),
            machine(id: "first", name: "Fifth", order: 0),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.id) == ["first", "ordered-a", "ordered-b", "unordered-a", "unordered-b"])
        #expect(segments.map(\.title) == ["Fifth", "Build", "Lab", "First", "Fourth"])
    }

    @Test("Duplicate display labels stay separate segments with distinct IDs")
    func duplicateLabelsAreNeverDeduplicated() {
        let machines = [
            machine(id: "build-a", name: "One", label: "Build", order: 1),
            machine(id: "build-b", name: "Two", label: "Build", order: 1),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Build", "Build"])
        #expect(segments.map(\.id) == ["build-a", "build-b"])
        #expect(segments.map(\.name) == ["One", "Two"])
    }

    @Test("Projection leaves source records and connection identity unchanged")
    func projectionDoesNotMutateRecords() {
        let source = [
            machine(id: "uuid-a", name: "Long Computer A", role: "unexpected", label: "Lab", order: 2),
            machine(id: "uuid-b", name: "Long Computer B", role: nil, label: "Build", order: 1),
        ]
        let snapshot = source
        let segments = SidebarMachineSegmentPresentation.segments(for: source)

        #expect(source == snapshot)
        #expect(segments.map(\.id) == ["uuid-b", "uuid-a"])
        #expect(source.map(\.urlString) == snapshot.map(\.urlString))
    }

    @Test("Four-machine menu inputs keep complete names and saved order")
    func fullNameMenuInputsAreUnchanged() {
        let machines = [
            machine(id: "one", name: "Complete One", label: "A", order: 4),
            machine(id: "two", name: "Complete Two", label: "B", order: 3),
            machine(id: "three", name: "Complete Three", label: "C", order: 2),
            machine(id: "four", name: "Complete Four", label: "D", order: 1),
        ]

        #expect(SidebarMachinePickerPresentation.presentation(machineCount: machines.count) == .menu)
        #expect(machines.map(\.name) == ["Complete One", "Complete Two", "Complete Three", "Complete Four"])
        #expect(machines.map(\.id) == ["one", "two", "three", "four"])
    }

    @Test("Persisted machine scope keeps the original machine ID across presentation")
    func persistedScopeUsesOriginalMachineID() throws {
        let suiteName = "NavigationPresentationTests.machineScope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let machines = [
            machine(id: "uuid-build", name: "Computer One", label: "Build", order: 1),
            machine(id: "uuid-lab", name: "Computer Two", label: "Lab", order: 0),
        ]
        MachineScope.machine("uuid-build").save(to: defaults)

        let build = try #require(
            SidebarMachineSegmentPresentation.segments(for: machines).first { $0.title == "Build" }
        )
        #expect(build.id == "uuid-build")
        #expect(MachineScope.load(from: defaults) == .machine(build.id))
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

private func machine(
    id: String,
    name: String,
    role: String? = nil,
    label: String? = nil,
    order: Int? = nil
) -> HerdrMachine {
    HerdrMachine(
        id: id,
        name: name,
        urlString: "https://\(id).example.invalid",
        role: role,
        sidebarLabel: label,
        sidebarOrder: order
    )
}
