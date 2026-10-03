import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent Roles sharing")
@MainActor
struct AgentRolesShareModelTests {
    private typealias Fixtures = AgentRoleTestFixtures

    @Test("Companions without sharing keep Share visible but its items off, and send nothing")
    func capabilityMissing() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.reviewOverview())
        let (store, model) = await makeModel(client)
        #expect(store.canOpenShareMenu)
        #expect(!store.supportsSharing)
        #expect(!store.canShareRoles)
        await model.loadExportPreview()
        #expect(model.exportError == "Update the companion on Desktop to share roles.")
        #expect(!model.canExport)
        await model.openImport(fileName: "herdr-roles-20261002.json", data: try Fixtures.shareDocument())
        #expect(model.importError == "Update the companion on Desktop to share roles.")
        #expect(await client.recordedImports().isEmpty)
        #expect(await client.recordedExports().isEmpty)
    }

    @Test("Share waits for loaded roles and stays off while saving or reloading a changed connection")
    func shareGuards() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        let store = AgentRolesStore(machines: Fixtures.machines, clients: ["desktop": client], catalog: AgentRoleTestCatalog())
        #expect(!store.canOpenShareMenu)
        await store.load()
        #expect(store.canShareRoles)
        store.draft?.systemPrompt = "Unsaved sample edit."
        #expect(store.canShareRoles)
        #expect(store.beginShareSession(importing: false) != nil)
        #expect(store.beginShareSession(importing: true) == nil)
        let changed = try #require(ServerConfiguration(urlString: "http://localhost:9093", token: "sample"))
        store.refreshConnections(machines: Fixtures.machines, configurations: ["desktop": changed], clients: ["desktop": client])
        #expect(store.requiresConnectionReload)
        #expect(!store.canShareRoles)
    }

    @Test("An import in flight blocks edits, reloads, machine changes and connection refreshes")
    func importingBlocksOtherChanges() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        let (store, _) = await makeModel(client)
        store.selectRole("worker")
        let session = try #require(store.beginShareSession(importing: true))
        #expect(store.beginImportRequest(session))
        #expect(store.isImporting)
        #expect(!store.canEdit)
        #expect(!store.canShareRoles)
        #expect(!store.canEditTeams)
        store.selectRole("planner")
        #expect(store.draft?.id == "worker")
        await store.selectMachine("laptop")
        #expect(store.selectedMachineID == "desktop")
        let changed = try #require(ServerConfiguration(urlString: "http://localhost:9093", token: "sample"))
        store.refreshConnections(machines: Fixtures.machines, configurations: ["desktop": changed], clients: [:])
        #expect(store.status == .loaded)
        #expect(store.isCurrent(session))
        #expect(!store.beginImportRequest(session))
        store.endImportRequest()
        #expect(store.canEdit)
    }

    @Test("Export starts with every shareable role; defaults can't be chosen and teams toggle their agents")
    func exportSelection() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToSharePreview(with: try Fixtures.sharePreview())
        let (_, model) = await makeModel(client)
        await model.loadExportPreview()
        #expect(model.exportError == nil)
        #expect(model.exportSelection == ["worker", Fixtures.releaseNotesID, "sample-review-agent", Fixtures.contrastID, Fixtures.schemaID])
        #expect(model.exportWorkerRoles.map(\.id) == ["first_mate", "worker", Fixtures.releaseNotesID])
        #expect(model.exportReviewRolesWithoutTeam.map(\.id) == ["pr-review-comprehensive", Fixtures.schemaID])
        #expect(model.exportTeams.map(\.name) == ["Sample team"])
        #expect(model.exportTeams.first?.roles.map(\.id) == ["sample-review-agent", Fixtures.contrastID])
        model.setExportRole("first_mate", selected: true)
        model.toggleExportRole("pr-review-comprehensive")
        #expect(!model.isExportSelected("first_mate"))
        #expect(!model.isExportSelected("pr-review-comprehensive"))
        #expect(model.isExportTeamSelected("Sample team"))
        model.setExportTeam("Sample team", selected: false)
        #expect(!model.isExportSelected("sample-review-agent"))
        #expect(!model.isExportSelected(Fixtures.contrastID))
        #expect(model.exportCount == 3)
        model.toggleExportRole(Fixtures.contrastID)
        #expect(!model.isExportTeamSelected("Sample team"))
        model.setExportTeam("Sample team", selected: true)
        #expect(model.isExportTeamSelected("Sample team"))
        #expect(model.exportCount == 5)
        #expect(model.canExport)
    }

    @Test("Exporting asks for the chosen roles in order and writes the file exactly as received")
    func exportWritesFile() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToSharePreview(with: try Fixtures.sharePreview())
        let document = try Fixtures.shareDocument()
        await client.respondToExport(with: .success(.init(document: document,
            summary: .init(roles: 3, skills: 1, files: 1, bytes: 15), warnings: [])))
        let (store, model) = await makeModel(client)
        store.draft?.systemPrompt = "Unsaved sample edit."
        await model.loadExportPreview()
        model.setExportTeam("Sample team", selected: false)
        let export = try #require(await model.exportSelectedRoles())
        #expect(await client.recordedExports() == [["worker", Fixtures.releaseNotesID, Fixtures.schemaID]])
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-roles-share-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(model.saveExport(export, to: url))
        #expect(try Data(contentsOf: url) == document)
        #expect(store.savedMessage == "Exported 3 roles. Teammates import them in Settings › Agent Roles › Share.")
        #expect(store.draft?.systemPrompt == "Unsaved sample edit.")
    }

    @Test("A blocked export shows the companion's reason in the sheet")
    func blockedExport() async throws {
        let message = "‘Atlas’ skill ‘deploy’ file scripts/key.txt contains a private key. Remove it or leave this role out."
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToSharePreview(with: try Fixtures.sharePreview())
        await client.respondToExport(with: .failure(.server(status: 400, message: message)))
        let (_, model) = await makeModel(client)
        await model.loadExportPreview()
        #expect(await model.exportSelectedRoles() == nil)
        #expect(model.exportError == message)
        #expect(model.canExport)
    }

    @Test("A connection change ends an export in progress")
    func exportConnectionChange() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToSharePreview(with: try Fixtures.sharePreview())
        let (store, model) = await makeModel(client)
        await model.loadExportPreview()
        #expect(model.canExport)
        let changed = try #require(ServerConfiguration(urlString: "http://localhost:9093", token: "sample"))
        store.refreshConnections(machines: Fixtures.machines, configurations: ["desktop": changed], clients: ["desktop": client])
        #expect(!model.canExport)
        #expect(model.exportError == "The connection to Desktop changed. Close this window and export again.")
        #expect(await model.exportSelectedRoles() == nil)
        #expect(await client.recordedExports().isEmpty)
    }

    @Test("Export files are named by date without a machine name")
    func exportFileName() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-02T21:00:00Z"))
        #expect(AgentRolesShareModel.exportFileName(on: date, timeZone: try #require(TimeZone(identifier: "UTC")))
                == "herdr-roles-20261002.json")
        #expect(AgentRolesShareModel.exportFileName(on: date, timeZone: try #require(TimeZone(secondsFromGMT: 14 * 3600)))
                == "herdr-roles-20261003.json")
    }

    @Test("Files that aren't roles files, or need a newer Herdr, are refused before anything is sent",
          arguments: [
            ("format", "This isn't a Herdr roles file. Choose a file exported from Settings › Agent Roles."),
            ("version", "This file needs a newer Herdr. Update Herdr, then import it again."),
            ("text", "This roles file is damaged. Ask for a new export."),
            ("fraction", "This roles file is damaged. Ask for a new export."),
            ("size", "This file is larger than 16 MB. Ask for an export with fewer roles or skills."),
          ])
    func headerRejection(problem: String, message: String) async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        let (_, model) = await makeModel(client)
        await model.openImport(fileName: "sample.json", data: try file(with: problem))
        #expect(model.importError == message)
        #expect(model.importPlan == nil)
        #expect(!model.canCommitImport)
        #expect(await client.recordedImports().isEmpty)
    }

    @Test("The dry run sends the file as is and selects what the plan recommends")
    func dryRunDefaults() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan())])
        let (store, model) = await makeModel(client)
        let document = try Fixtures.shareDocument()
        await model.openImport(fileName: "herdr-roles-20261002.json", data: Data([0xEF, 0xBB, 0xBF]) + document)
        let request = try #require(await client.recordedImports().first)
        #expect(request.dryRun)
        #expect(request.document == document)
        #expect(request.localSkills == ["skill_alpha": Self.syntheticHash, "skill_bravo": Self.syntheticHash])
        #expect(request.expectedRevision == nil)
        #expect(request.planDigest == nil)
        #expect(request.roleIDs == nil)
        #expect(model.importError == nil)
        #expect(model.importHeader?.roleCount == 1)
        #expect(model.importSelection == [Fixtures.releaseNotesID, Fixtures.contrastID, Fixtures.schemaID])
        #expect(model.replaceRoleIDs.isEmpty)
        #expect(model.importUnchangedRoles.map(\.id) == ["planner", "research_scout"])
        #expect(model.importWorkerRoles.map(\.id) == [Fixtures.releaseNotesID, "worker", "recovery_advisor"])
        #expect(model.importTeams.map(\.team.name) == ["Data team", "Sample team"])
        #expect(model.importExportedAt == ISO8601DateFormatter().date(from: "2026-10-02T21:00:00Z"))
        model.setImportRole("planner", selected: true)
        model.setImportRole("recovery_advisor", selected: true)
        #expect(model.importCount == 3)
        model.toggleImportRole("worker")
        #expect(model.replaceRoleIDs == ["worker"])
        #expect(model.importRoleIDs == [Fixtures.releaseNotesID, "worker", Fixtures.contrastID, Fixtures.schemaID])
        #expect(model.canCommitImport)
        #expect(!store.isImporting)
        #expect(store.overview?.revision == 7)
    }

    @Test("Committing names every replaced role, then shows the imported roles")
    func commit() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan()), .success(try Fixtures.committedPlan())])
        let (store, model) = await makeModel(client)
        store.selectRole("worker")
        await model.openImport(fileName: "herdr-roles-20261002.json", data: try Fixtures.shareDocument())
        model.setImportRole("worker", selected: true)
        model.setImportRole(Fixtures.schemaID, selected: false)
        #expect(await model.commitImport())
        let commit = try #require(await client.recordedImports().last)
        #expect(!commit.dryRun)
        #expect(commit.expectedRevision == 7)
        #expect(commit.planDigest == String(repeating: "d", count: 64))
        #expect(commit.roleIDs == [Fixtures.releaseNotesID, "worker", Fixtures.contrastID])
        #expect(commit.replaceRoleIDs == ["worker"])
        #expect(commit.localSkills == ["skill_alpha": Self.syntheticHash, "skill_bravo": Self.syntheticHash])
        #expect(store.overview?.revision == 8)
        #expect(store.roles.contains { $0.id == Fixtures.releaseNotesID })
        #expect(store.draft == Fixtures.updatedWorker())
        #expect(!store.hasUnsavedChanges)
        #expect(!store.isImporting)
        #expect(store.savedMessage == "Imported 3 roles to Desktop. Applies to new sessions.")
    }

    @Test("A commit that doesn't return the resulting roles isn't treated as confirmed")
    func unconfirmedCommit() async throws {
        let withoutOverview = try Fixtures.importPlan(dryRun: false, roles: Fixtures.importPlanRoles())
        #expect(withoutOverview.overview == nil)
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan()), .success(withoutOverview)])
        let (store, model) = await makeModel(client)
        await model.openImport(fileName: "sample.json", data: try Fixtures.shareDocument())
        #expect(await !model.commitImport())
        #expect(model.importError?.hasPrefix("The import wasn't confirmed.") == true)
        #expect(store.overview?.revision == 7)
        #expect(store.savedMessage == nil)
    }

    @Test("Changed roles refresh the plan and keep the choices still available",
          arguments: ["agent_role_conflict", "import_plan_changed"])
    func conflictReplans(code: String) async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        let refreshed = try Fixtures.samplePlan(releaseNotes: "update", planner: "update", digest: String(repeating: "e", count: 64))
        await client.respondToImports(with: [
            .success(try Fixtures.samplePlan()),
            .failure(.server(status: 409, message: code)),
            .success(refreshed),
        ])
        let (_, model) = await makeModel(client)
        await model.openImport(fileName: "sample.json", data: try Fixtures.shareDocument())
        model.setImportRole(Fixtures.contrastID, selected: false)
        model.setImportRole("worker", selected: true)
        #expect(await !model.commitImport())
        let requests = await client.recordedImports()
        #expect(requests.map(\.dryRun) == [true, false, true])
        #expect(model.importPlan == refreshed)
        // Release notes now replaces a role but stays chosen; Planner was reviewed as unchanged, so it stays off.
        #expect(model.importSelection == [Fixtures.releaseNotesID, "worker", Fixtures.schemaID])
        #expect(model.replaceRoleIDs == [Fixtures.releaseNotesID, "worker"])
        #expect(model.importNotice == "Roles changed on Desktop. Review the updated plan.")
        #expect(model.importError == nil)
        #expect(model.canCommitImport)
    }

    @Test("A connection change during review stops the import")
    func connectionChangeCancels() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan())])
        let (store, model) = await makeModel(client)
        await model.openImport(fileName: "sample.json", data: try Fixtures.shareDocument())
        #expect(model.canCommitImport)
        let changed = try #require(ServerConfiguration(urlString: "http://localhost:9093", token: "sample"))
        store.refreshConnections(machines: Fixtures.machines, configurations: ["desktop": changed],
                                 clients: ["desktop": AgentRoleTestClient(overview: Fixtures.shareOverview())])
        #expect(model.isImportCancelled)
        #expect(model.importError == "The connection to Desktop changed, so this import stopped. Import the file again to review a new plan.")
        #expect(!model.canCommitImport)
        #expect(await !model.commitImport())
        #expect(await client.recordedImports().count == 1)
    }

    @Test("Local skill hashes are read one package at a time and keep unreadable local copies separate")
    func localSkillHashes() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan())])
        let catalog = AgentRoleTestCatalog()
        catalog.unreadableIDs = ["skill_bravo"]
        let (_, model) = await makeModel(client, catalog: catalog)
        await model.openImport(fileName: "sample.json", data: try Fixtures.shareDocument())
        #expect(model.importHeader?.skillIDs == ["skill_alpha", "skill_bravo", "skill_remote"])
        #expect(catalog.bundleRequests == [["skill_alpha"], ["skill_bravo"]])
        let expected = ["skill_alpha": Self.syntheticHash, "skill_bravo": AgentRolesShareModel.unreadableSkillHash]
        #expect(model.importLocalSkills == expected)
        #expect(await client.recordedImports().first?.localSkills == expected)
    }

    @Test("Imports need saved roles first")
    func importNeedsCleanEditor() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        let (store, model) = await makeModel(client)
        store.draft?.systemPrompt = "Unsaved sample edit."
        await model.openImport(fileName: "sample.json", data: try Fixtures.shareDocument())
        #expect(model.importError == "Save or discard your role edits, then import again.")
        #expect(await client.recordedImports().isEmpty)
    }

    @Test("Opening a file reads it from disk and plans it")
    func openFromURL() async throws {
        let client = AgentRoleTestClient(overview: Fixtures.shareOverview())
        await client.respondToImports(with: [.success(try Fixtures.samplePlan())])
        let (_, model) = await makeModel(client)
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-roles-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try Fixtures.shareDocument()
        try document.write(to: url)
        await model.openImport(url: url)
        #expect(model.importFileName == url.lastPathComponent)
        #expect(model.importPlan != nil)
        #expect(await client.recordedImports().first?.document == document)
        model.closeImport()
        #expect(!model.hasImportSession)
    }

    @Test("Skills copied to the execution computer aren't reported as missing")
    func savedCopies() async {
        let imported = AgentRoleSkill(id: "skill_imported", name: "Sample importer", description: "Synthetic skill.",
                                      source: "agents", path: "/example/host/skills/importer/SKILL.md", estimatedTokens: 40)
        let lost = AgentRoleSkill(id: "skill_lost", name: "Sample lost skill", description: "Synthetic skill.",
                                  source: "agents", path: "/example/host/skills/lost/SKILL.md", estimatedTokens: 40)
        var overview = Fixtures.shareOverview(skills: Fixtures.skills + [imported, lost])
        overview.missingRoleSkills = ["worker": ["skill_lost"]]
        let store = AgentRolesStore(machines: Fixtures.machines,
            clients: ["desktop": AgentRoleTestClient(overview: overview)], catalog: AgentRoleTestCatalog())
        await store.load()
        store.selectRole("worker")
        store.draft?.skillIds = ["skill_bravo", "skill_imported", "skill_lost", "skill_unknown"]
        #expect(store.missingIDs == ["skill_imported", "skill_lost", "skill_unknown"])
        #expect(store.savedCopyIDs == ["skill_imported"])
        #expect(store.unavailableSkillIDs == ["skill_lost", "skill_unknown"])
        #expect(store.missingSkillName("skill_imported") == "Sample importer")
        store.toggleSkill("skill_imported")
        #expect(store.savedCopyIDs.isEmpty)
    }

    private func file(with problem: String) throws -> Data {
        switch problem {
        case "format": try Fixtures.shareDocument(format: "other-roles")
        case "version": try Fixtures.shareDocument(version: 2)
        case "text": try Fixtures.shareDocument(version: "1")
        case "fraction": try Fixtures.shareDocument(version: 1.5)
        default: Data(count: AgentRolesShareFileHeader.maxFileBytes + 1)
        }
    }

    /// The companion's `content_hash` of the test catalog's one-file package.
    private static let syntheticHash = "fbb0f407af849b41e2147646f617864d358733fbc74bb8fb2fb6d4d1e80462e6"

    private func makeModel(_ client: AgentRoleTestClient,
                           catalog: AgentRoleTestCatalog = AgentRoleTestCatalog()) async -> (AgentRolesStore, AgentRolesShareModel) {
        let store = AgentRolesStore(machines: Fixtures.machines, clients: ["desktop": client], catalog: catalog)
        await store.load()
        return (store, AgentRolesShareModel(store: store))
    }
}

@Suite("Agent Roles sharing wording")
struct AgentRolesSharePresentationTests {
    @Test("Export rows summarize what each role carries")
    func exportSubtitles() throws {
        let preview = try AgentRoleTestFixtures.sharePreview()
        let subtitles = Dictionary(uniqueKeysWithValues: preview.roles.map { ($0.id, AgentRolesSharePresentation.exportSubtitle($0)) })
        #expect(subtitles["first_mate"] == "Default — nothing to share")
        #expect(subtitles[AgentRoleTestFixtures.releaseNotesID] == "Automatic skills (not included)")
        #expect(subtitles[AgentRoleTestFixtures.contrastID] == "No skills")
        let worker = try #require(subtitles["worker"])
        #expect(worker.hasPrefix("1 skill · "))
        #expect(worker.hasSuffix(" · 1 skill isn't stored here"))
    }

    @Test("Import rows summarize each skill's outcome and the action")
    func importLines() throws {
        let plan = try AgentRoleTestFixtures.samplePlan()
        let roles = Dictionary(uniqueKeysWithValues: plan.roles.map { ($0.id, $0) })
        let worker = try #require(roles["worker"])
        #expect(AgentRolesSharePresentation.importSkillsLine(worker) == "2 skills: 1 new, 1 not available")
        #expect(AgentRolesSharePresentation.actionTitle(worker) == "Replaces your Worker")
        let notes = try #require(roles[AgentRoleTestFixtures.releaseNotesID])
        #expect(AgentRolesSharePresentation.actionTitle(notes) == "New")
        #expect(AgentRolesSharePresentation.delegates(notes))
        #expect(AgentRolesSharePresentation.actionTitle(try #require(roles["recovery_advisor"])) == "Can't import")
        #expect(AgentRolesSharePresentation.importSkillsLine(try #require(roles[AgentRoleTestFixtures.contrastID]))
                == "1 skill: 1 kept separate")
        #expect(AgentRolesSharePresentation.importTitle(1) == "Import 1 Role")
        #expect(AgentRolesSharePresentation.exportTitle(3) == "Export 3 Roles…")
    }

    @Test("Plans read every documented field and tolerate ones they don't know")
    func planDecoding() throws {
        let plan = try AgentRoleTestFixtures.samplePlan()
        #expect(plan.dryRun)
        #expect(plan.revision == 7)
        #expect(plan.teams.map(\.name) == ["Sample team", "Data team"])
        let atlas = try #require(plan.roles.first { $0.id == "sample-review-agent" })
        #expect(atlas.team == .init(name: "Sample team", status: "joins"))
        #expect(atlas.current?.avatar == "quality")
        #expect(atlas.changes == ["Review prompt"])
        let skill = try #require(plan.skills.first)
        #expect(skill.files.map(\.executable) == [false, true])
        #expect(skill.executableFiles == 1)
        #expect(skill.usedBy == ["worker"])
        let minimal = try AgentRoleTestFixtures.decode(AgentRolesImportPlan.self, [
            "ok": true, "revision": 2, "planDigest": "digest", "laterField": 1,
            "roles": [["id": "worker", "action": "unchanged", "role": ["unexpected": true]]],
        ] as [String: Any])
        #expect(minimal.roles.first?.role == nil)
        #expect(minimal.roles.first?.purpose == "worker")
        #expect(minimal.skills.isEmpty)
    }
}
