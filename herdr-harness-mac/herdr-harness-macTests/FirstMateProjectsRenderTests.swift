import SwiftUI
import Testing
@testable import herdr_harness_mac

/// All records and paths come from the in-memory projects demo. No companion
/// connections, local folders, or live sessions are read or modified.
@Suite("First Mate projects native presentation", .serialized)
@MainActor
struct FirstMateProjectsRenderTests {
    @Test("A saved project and starting prompt render in both appearances", arguments: [ColorScheme.light, .dark])
    func startSession(scheme: ColorScheme) async throws {
        let index = await demoIndex()
        let model = FirstMateStartSessionModel()
        model.chooseProject(.init(machineID: "demo", projectID: "demo-ios"))
        model.prompt = "Improve search suggestions in the iOS app.\n\nStart by reviewing how suggestions load and propose a focused plan."
        #expect(model.canStart(in: index))
        let render = try await HerdrRenderHarness.render("first-mate-start-\(appearance(scheme)).png", size: CGSize(width: 960, height: 790)) {
            FirstMateStartSessionView(model: model, index: index, manageProjects: {}) { _ in }
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
        render.expectSubstantial(minimumBytes: 12_000)
    }

    @Test("The projects page renders names, machine owners, and folder paths", arguments: [ColorScheme.light, .dark])
    func projects(scheme: ColorScheme) async throws {
        let index = await demoIndex()
        #expect(index.activeChoices.count == 2)
        let render = try await HerdrRenderHarness.render("first-mate-projects-\(appearance(scheme)).png", size: CGSize(width: 960, height: 720)) {
            FirstMateProjectsView(index: index) { _ in }
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
        render.expectSubstantial(minimumBytes: 10_000)
    }

    @Test("The new project editor renders its machine, folder, and save controls", arguments: [ColorScheme.light, .dark])
    func editor(scheme: ColorScheme) async throws {
        let index = await demoIndex()
        let model = FirstMateProjectEditorModel(preferredMachineID: "demo")
        model.name = "Design system"
        model.cwd = FirstMateProjectsDemoClient.home + "/Projects/design-system"
        #expect(model.canSave(in: index))
        let render = try await HerdrRenderHarness.render("first-mate-editor-\(appearance(scheme)).png", size: CGSize(width: 580, height: 560)) {
            FirstMateProjectEditorView(model: model, index: index) { _ in }
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
        render.expectSubstantial(minimumBytes: 8_192)
    }

    @Test("An archived project's revision conflict retains visible recovery controls", arguments: [ColorScheme.light, .dark])
    func archivedConflict(scheme: ColorScheme) async throws {
        let index = await demoIndex()
        let connection = try #require(index.connection(for: "demo"))
        let archived = try await connection.client.setFirstMateProjectArchived(
            id: "demo-ios", archived: true, expectedRevision: 1, requestID: "synthetic-archive"
        )
        index.receive(archived.project, from: connection)
        let choice = try #require(index.choice(.init(machineID: "demo", projectID: "demo-ios")))
        let model = FirstMateProjectEditorModel(choice: choice, connection: connection)
        // A separate client restored the record after this editor loaded it.
        _ = try await connection.client.setFirstMateProjectArchived(
            id: "demo-ios", archived: false, expectedRevision: 2, requestID: "synthetic-external-restore"
        )
        #expect(await model.setArchived(false, in: index) == nil)
        #expect(model.isArchived)
        #expect(model.isConflict)
        let render = try await HerdrRenderHarness.render("first-mate-editor-conflict-\(appearance(scheme)).png", size: CGSize(width: 660, height: 740)) {
            FirstMateProjectEditorView(model: model, index: index) { _ in }
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
        render.expectSubstantial(minimumBytes: 10_000)
    }

    @Test("Project forms support the largest app text size", arguments: [ColorScheme.light, .dark])
    func largeText(scheme: ColorScheme) async throws {
        let index = await demoIndex()
        let model = FirstMateProjectEditorModel(preferredMachineID: "demo")
        model.name = "Shared component library"
        model.cwd = FirstMateProjectsDemoClient.home + "/Projects/design-system"
        let render = try await HerdrRenderHarness.render("first-mate-editor-large-text-\(appearance(scheme)).png", size: CGSize(width: 760, height: 760)) {
            FirstMateProjectEditorView(model: model, index: index) { _ in }
                .environment(\.colorScheme, scheme)
                .environment(\.herdrFontScale, .xxxLarge)
                .preferredColorScheme(scheme)
        }
        render.expectSubstantial(minimumBytes: 10_000)
    }

    @Test("Manual setup remains available with a named machine and folder", arguments: [ColorScheme.light, .dark])
    func manual(scheme: ColorScheme) async throws {
        let index = await demoIndex()
        let model = FirstMateStartSessionModel()
        model.mode = .manual
        model.manualMachineID = "demo"
        model.manualTitle = "Investigate a rendering regression"
        model.manualPath = FirstMateProjectsDemoClient.home + "/Projects/web-app"
        model.prompt = "Investigate the rendering regression and explain what changed before making a fix."
        #expect(model.canStart(in: index))
        let render = try await HerdrRenderHarness.render("first-mate-start-manual-\(appearance(scheme)).png", size: CGSize(width: 960, height: 880)) {
            FirstMateStartSessionView(model: model, index: index, manageProjects: {}) { _ in }
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        }
        render.expectSubstantial(minimumBytes: 12_000)
    }

    private func demoIndex() async -> FirstMateProjectIndex {
        let index = FirstMateProjectIndex()
        index.activate(sources: [], demo: true)
        await index.refresh()
        return index
    }

    private func appearance(_ scheme: ColorScheme) -> String { scheme == .light ? "light" : "dark" }
}
