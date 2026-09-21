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

    @Test("Picker boundaries stay hidden, segmented, then menu from zero through four machines")
    func machinePickerBoundary() {
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 0) == .hidden)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 1) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 2) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 3) == .segmented)
        #expect(SidebarMachinePickerPresentation.presentation(machineCount: 4) == .menu)
    }

    @Test("Every reported roster order projects Work, Dev, Studio", arguments: reportedRosterPermutations())
    func reportedRosterOrdering(roster: [(id: String, name: String)]) {
        let machines = roster.map { machine(id: $0.id, name: $0.name) }
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.count == roster.count)
        #expect(segments.map(\.title) == ["Work", "Dev", "Studio"])
        #expect(segments.map(\.id) == ["work-mac", "devbox", "local-mac"])
        #expect(segments.map(\.name) == ["Work Mac", "DevBox", "Local Mac"])
    }

    @Test("Canonical short labels match whole names case-insensitively after trimming", arguments: [
        ("Work Mac", "Work"),
        ("work mac", "Work"),
        ("  Work Mac  ", "Work"),
        ("Work", "Work"),
        ("WORK", "Work"),
        ("DevBox", "Dev"),
        ("devbox", "Dev"),
        ("  Dev  ", "Dev"),
        ("Local Mac", "Studio"),
        ("local mac", "Studio"),
        ("STUDIO", "Studio"),
    ])
    func canonicalShortLabels(name: String, expectedTitle: String) {
        let segments = SidebarMachineSegmentPresentation.segments(for: [machine(id: "only", name: name)])

        #expect(segments.map(\.title) == [expectedTitle])
        #expect(segments.map(\.name) == [name])
        #expect(segments.map(\.id) == ["only"])
    }

    @Test("Nil roles and unrelated role values do not affect the presentation order")
    func rolesDoNotAffectPresentation() {
        let machines = [
            machine(id: "work", name: "Work Mac", role: "local"),
            machine(id: "dev", name: "DevBox", role: "work"),
            machine(id: "studio", name: "Local Mac", role: nil),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Work", "Dev", "Studio"])
        #expect(segments.map(\.id) == ["work", "dev", "studio"])
    }

    @Test("Unknown names stay unchanged after the recognized segments")
    func unknownNamesRemainUnchanged() {
        let machines = [
            machine(id: "build", name: "Build Mac"),
            machine(id: "work", name: "Work Mac"),
            machine(id: "lab", name: "Lab Mac"),
            machine(id: "dev", name: "DevBox"),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Work", "Dev", "Build Mac", "Lab Mac"])
        #expect(segments.map(\.name) == ["Work Mac", "DevBox", "Build Mac", "Lab Mac"])
        #expect(segments.map(\.id) == ["work", "dev", "build", "lab"])
    }

    @Test("Partial rosters produce one segment per configured machine and no invented ones")
    func partialRostersProduceOnlyConfiguredSegments() {
        let devOnly = SidebarMachineSegmentPresentation.segments(for: [machine(id: "dev", name: "DevBox")])
        #expect(devOnly.count == 1)
        #expect(devOnly.map(\.title) == ["Dev"])

        let pair = SidebarMachineSegmentPresentation.segments(for: [
            machine(id: "studio", name: "Local Mac"),
            machine(id: "work", name: "Work"),
        ])
        #expect(pair.map(\.title) == ["Work", "Studio"])
        #expect(pair.map(\.id) == ["work", "studio"])

        #expect(SidebarMachineSegmentPresentation.segments(for: []).isEmpty)
    }

    @Test("Duplicate display labels stay separate segments with distinct IDs")
    func duplicateLabelsAreNeverDeduplicated() {
        let machines = [
            machine(id: "work-a", name: "Work"),
            machine(id: "work-b", name: "Work Mac"),
            machine(id: "dev-a", name: "Dev"),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Work", "Work", "Dev"])
        #expect(segments.map(\.id) == ["work-a", "work-b", "dev-a"])
        #expect(segments.map(\.name) == ["Work", "Work Mac", "Dev"])
    }

    @Test("Equal-ranked and unrecognized choices keep their original roster order")
    func equalRanksKeepRosterOrder() {
        let machines = [
            machine(id: "zulu", name: "Zulu Mac"),
            machine(id: "studio-a", name: "Studio"),
            machine(id: "alpha", name: "Alpha Mac"),
            machine(id: "studio-b", name: "Local Mac"),
        ]
        let segments = SidebarMachineSegmentPresentation.segments(for: machines)

        #expect(segments.map(\.title) == ["Studio", "Studio", "Zulu Mac", "Alpha Mac"])
        #expect(segments.map(\.id) == ["studio-a", "studio-b", "zulu", "alpha"])
    }

    @Test("Projection leaves the source machine records unchanged")
    func projectionDoesNotMutateRecords() {
        let source = [
            machine(id: "work", name: "Work Mac", role: nil),
            machine(id: "dev", name: "DevBox", role: nil),
            machine(id: "local", name: "Local Mac", role: nil),
        ]
        let snapshot = source
        let segments = SidebarMachineSegmentPresentation.segments(for: source)

        #expect(source == snapshot)
        #expect(segments.map(\.id) == ["work", "dev", "local"])
        #expect(segments.map(\.name) == source.map(\.name))
    }

    @Test("Persisted machine scope keeps the original machine ID across presentation")
    func persistedScopeUsesOriginalMachineID() throws {
        let suiteName = "NavigationPresentationTests.machineScope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MachineScope.load(from: defaults) == .all)

        let machines = [
            machine(id: "work-id", name: "Work Mac"),
            machine(id: "dev-id", name: "DevBox"),
            machine(id: "studio-id", name: "Local Mac"),
        ]
        MachineScope.machine("dev-id").save(to: defaults)

        let segments = SidebarMachineSegmentPresentation.segments(for: machines)
        let devSegment = try #require(segments.first(where: { $0.title == "Dev" }))
        #expect(devSegment.id == "dev-id")
        #expect(MachineScope.load(from: defaults) == .machine(devSegment.id))

        MachineScope.all.save(to: defaults)
        #expect(MachineScope.load(from: defaults) == .all)
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

private func machine(id: String, name: String, role: String? = nil) -> HerdrMachine {
    HerdrMachine(id: id, name: name, urlString: "https://machine.example.invalid", role: role)
}

private func reportedRosterPermutations() -> [[(id: String, name: String)]] {
    let roster: [(id: String, name: String)] = [
        ("work-mac", "Work Mac"),
        ("devbox", "DevBox"),
        ("local-mac", "Local Mac"),
    ]
    var permutations: [[(id: String, name: String)]] = []
    for first in roster.indices {
        for second in roster.indices where second != first {
            for third in roster.indices where third != first && third != second {
                permutations.append([roster[first], roster[second], roster[third]])
            }
        }
    }
    return permutations
}
