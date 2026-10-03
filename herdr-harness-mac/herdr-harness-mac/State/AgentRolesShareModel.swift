import Foundation
import Observation

/// Exports and imports roles files for the Agent Roles pane. Save and open
/// panels stay in the views; this takes file data and URLs.
@MainActor
@Observable
final class AgentRolesShareModel {
    /// PR review agents on one team, in the companion's order.
    struct ExportTeam: Identifiable {
        let name: String
        let roles: [AgentRolesSharePreview.Role]
        var id: String { name }
    }

    struct ImportTeam: Identifiable {
        let team: AgentRolesImportPlan.Team
        let roles: [AgentRolesImportPlan.Role]
        var id: String { team.name }
    }

    let store: AgentRolesStore

    private(set) var exportPreview: AgentRolesSharePreview?
    private(set) var isLoadingExportPreview = false
    private(set) var isExporting = false
    private var exportFailure: String?
    private(set) var exportSelection: Set<String> = []
    private var exportSession: AgentRolesShareSession?

    private(set) var importFileName: String?
    private(set) var importHeader: AgentRolesShareFileHeader?
    private(set) var importPlan: AgentRolesImportPlan?
    private(set) var importSelection: Set<String> = []
    private(set) var isPlanningImport = false
    private(set) var isCommittingImport = false
    /// Shown above a plan that was refreshed because roles changed meanwhile.
    private(set) var importNotice: String?
    private var importFailure: String?
    @ObservationIgnored private(set) var importDocument: Data?
    /// Content hashes of the file's skills that this Mac has, fixed for the session.
    @ObservationIgnored private(set) var importLocalSkills: [String: String] = [:]
    private var importSession: AgentRolesShareSession?

    init(store: AgentRolesStore) { self.store = store }

    // MARK: Export

    var exportMachineName: String { exportSession?.machineName ?? store.selectedMachine?.name ?? "this computer" }
    var exportWorkerRoles: [AgentRolesSharePreview.Role] { exportPreview?.roles.filter { !$0.isPRReview } ?? [] }
    var exportReviewRolesWithoutTeam: [AgentRolesSharePreview.Role] {
        exportPreview?.roles.filter { $0.isPRReview && $0.team.isEmpty } ?? []
    }
    var exportTeams: [ExportTeam] {
        let review = exportPreview?.roles.filter { $0.isPRReview && !$0.team.isEmpty } ?? []
        let names = review.map(\.team).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in ExportTeam(name: name, roles: review.filter { $0.team == name }) }
    }
    var exportCount: Int { exportSelection.count }
    var canExport: Bool {
        exportPreview != nil && !exportSelection.isEmpty && !isExporting && !isLoadingExportPreview && exportSessionIsCurrent
    }
    private var exportSessionIsCurrent: Bool { exportSession.map(store.isCurrent) ?? false }
    /// Shown in the sheet. The connection changing ends the export.
    var exportError: String? {
        if let exportFailure { return exportFailure }
        if let exportSession, !store.isCurrent(exportSession) {
            return connectionChangedMessage(exportSession.machineName, action: "export")
        }
        return nil
    }

    func loadExportPreview() async {
        exportPreview = nil
        exportSelection = []
        exportFailure = nil
        guard let session = store.beginShareSession(importing: false) else {
            exportSession = nil
            exportFailure = unavailableMessage(machine: store.selectedMachine?.name ?? "this computer")
            return
        }
        exportSession = session
        isLoadingExportPreview = true
        defer { if exportSession?.id == session.id { isLoadingExportPreview = false } }
        do {
            let preview = try await session.client.fetchAgentRolesSharePreview()
            guard exportSession?.id == session.id else { return }
            guard store.isCurrent(session) else {
                exportFailure = connectionChangedMessage(session.machineName, action: "export")
                return
            }
            guard preview.ok, Set(preview.roles.map(\.id)).count == preview.roles.count else { throw APIError.invalidResponse }
            exportPreview = preview
            exportSelection = Set(preview.roles.filter(\.shareable).map(\.id))
        } catch {
            guard exportSession?.id == session.id else { return }
            exportFailure = message(for: error, machine: session.machineName,
                                  fallback: "Couldn't load roles from \(session.machineName).")
        }
    }

    func isExportSelected(_ id: String) -> Bool { exportSelection.contains(id) }

    func setExportRole(_ id: String, selected: Bool) {
        guard !isExporting, exportPreview?.roles.contains(where: { $0.id == id && $0.shareable }) == true else { return }
        if selected { exportSelection.insert(id) } else { exportSelection.remove(id) }
    }

    func toggleExportRole(_ id: String) { setExportRole(id, selected: !exportSelection.contains(id)) }

    /// True when every shareable agent on the team is selected.
    func isExportTeamSelected(_ name: String) -> Bool {
        let members = shareableMembers(of: name)
        return !members.isEmpty && members.allSatisfy(exportSelection.contains)
    }

    func setExportTeam(_ name: String, selected: Bool) {
        guard !isExporting else { return }
        for id in shareableMembers(of: name) {
            if selected { exportSelection.insert(id) } else { exportSelection.remove(id) }
        }
    }

    /// Fetches the file for the selected roles. Errors, such as a blocked
    /// private key or a file that's too large, appear in `exportError`.
    func exportSelectedRoles() async -> AgentRolesExport? {
        guard canExport, let session = exportSession, let preview = exportPreview else { return nil }
        let ids = preview.roles.map(\.id).filter(exportSelection.contains)
        isExporting = true
        exportFailure = nil
        defer { if exportSession?.id == session.id { isExporting = false } }
        do {
            let export = try await session.client.exportAgentRoles(roleIDs: ids)
            guard exportSession?.id == session.id else { return nil }
            guard store.isCurrent(session) else {
                exportFailure = connectionChangedMessage(session.machineName, action: "export")
                return nil
            }
            return export
        } catch {
            guard exportSession?.id == session.id else { return nil }
            exportFailure = message(for: error, machine: session.machineName, fallback: "The roles weren't exported.")
            return nil
        }
    }

    /// Writes the file exactly as received and reports the export.
    @discardableResult
    func saveExport(_ export: AgentRolesExport, to url: URL) -> Bool {
        do {
            do { try export.document.write(to: url, options: .atomic) }
            catch { try export.document.write(to: url) }
        } catch {
            exportFailure = "Couldn't save \(url.lastPathComponent). \(error.localizedDescription)"
            return false
        }
        store.reportExported(roleCount: export.summary.roles > 0 ? export.summary.roles : exportSelection.count)
        return true
    }

    func closeExport() {
        exportSession = nil
        exportPreview = nil
        exportSelection = []
        exportFailure = nil
        isLoadingExportPreview = false
        isExporting = false
    }

    /// `herdr-roles-yyyyMMdd.json`, without a machine name.
    static func exportFileName(on date: Date = .now, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return "herdr-roles-\(formatter.string(from: date)).json"
    }

    private func shareableMembers(of team: String) -> [String] {
        exportPreview?.roles.filter { $0.isPRReview && $0.team == team && $0.shareable }.map(\.id) ?? []
    }

    // MARK: Import

    var importMachineName: String { importSession?.machineName ?? store.selectedMachine?.name ?? "this computer" }
    var hasImportSession: Bool { importSession != nil || importFailure != nil }
    /// The machine's connection or roles were replaced after the file was opened.
    var isImportCancelled: Bool {
        guard let importSession, !isCommittingImport else { return false }
        return !store.isCurrent(importSession)
    }
    var importError: String? {
        if let importFailure { return importFailure }
        if isImportCancelled {
            return "The connection to \(importMachineName) changed, so this import stopped. Import the file again to review a new plan."
        }
        return nil
    }
    var importExportedAt: Date? {
        guard let text = importPlan?.exportedAt ?? importHeader?.exportedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    var importWorkerRoles: [AgentRolesImportPlan.Role] {
        importPlan?.roles.filter { !$0.isPRReview && $0.kind != .unchanged } ?? []
    }
    var importReviewRolesWithoutTeam: [AgentRolesImportPlan.Role] {
        importPlan?.roles.filter { $0.isPRReview && $0.kind != .unchanged && $0.team == nil } ?? []
    }
    var importTeams: [ImportTeam] {
        let review = importPlan?.roles.filter { $0.isPRReview && $0.kind != .unchanged && $0.team != nil } ?? []
        var teams: [AgentRolesImportPlan.Team] = []
        for role in review {
            if let team = role.team, !teams.contains(where: { $0.name == team.name }) { teams.append(team) }
        }
        return teams.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { team in ImportTeam(team: team, roles: review.filter { $0.team?.name == team.name }) }
    }
    /// Collapsed into one line.
    var importUnchangedRoles: [AgentRolesImportPlan.Role] { importPlan?.roles.filter { $0.kind == .unchanged } ?? [] }
    /// The selected roles, in plan order.
    var importRoleIDs: [String] {
        importPlan?.roles.filter { $0.isSelectable && importSelection.contains($0.id) }.map(\.id) ?? []
    }
    /// Every selected role that replaces one on this computer must be named.
    var replaceRoleIDs: [String] {
        importPlan?.roles.filter { $0.kind == .update && importSelection.contains($0.id) }.map(\.id) ?? []
    }
    var importCount: Int { importRoleIDs.count }
    var canCommitImport: Bool {
        importPlan != nil && importDocument != nil && importCount > 0
            && !isPlanningImport && !isCommittingImport && !isImportCancelled
    }

    /// Reads a file chosen in the open panel, then plans its import.
    func openImport(url: URL) async {
        closeImport()
        let name = url.lastPathComponent
        importFileName = name
        do {
            let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= AgentRolesShareFileHeader.maxFileBytes else { throw AgentRolesShareFileError.tooLarge }
                return try Data(contentsOf: url)
            }.value
            guard importFileName == name, importSession == nil else { return }
            await openImport(fileName: name, data: data)
        } catch let error as AgentRolesShareFileError {
            importFailure = error.message
        } catch {
            importFailure = "Couldn't read \(name). \(error.localizedDescription)"
        }
    }

    /// Checks the file on this Mac, then asks the companion for a plan.
    func openImport(fileName: String, data: Data) async {
        closeImport()
        importFileName = fileName
        guard let session = store.beginShareSession(importing: true) else {
            importFailure = store.hasUnsavedChanges && store.supportsSharing
                ? "Save or discard your role edits, then import again."
                : unavailableMessage(machine: store.selectedMachine?.name ?? "this computer")
            return
        }
        importSession = session
        guard data.count <= AgentRolesShareFileHeader.maxFileBytes else {
            importFailure = AgentRolesShareFileError.tooLarge.message
            return
        }
        let document = Self.withoutByteOrderMark(data)
        do {
            let header = try await Task.detached(priority: .userInitiated) {
                try AgentRolesShareFileHeader(validating: document)
            }.value
            guard importSession?.id == session.id else { return }
            importHeader = header
            let localSkills = await localSkillHashes(for: header.skillIDs)
            guard importSession?.id == session.id else { return }
            importLocalSkills = localSkills
            importDocument = document
        } catch {
            guard importSession?.id == session.id else { return }
            importFailure = (error as? AgentRolesShareFileError)?.message ?? error.localizedDescription
            return
        }
        _ = await plan(session, keeping: nil)
    }

    func isImportSelected(_ id: String) -> Bool { importSelection.contains(id) }

    func setImportRole(_ id: String, selected: Bool) {
        guard !isPlanningImport, !isCommittingImport,
              importPlan?.roles.contains(where: { $0.id == id && $0.isSelectable }) == true else { return }
        if selected { importSelection.insert(id) } else { importSelection.remove(id) }
    }

    func toggleImportRole(_ id: String) { setImportRole(id, selected: !importSelection.contains(id)) }

    /// Imports the reviewed plan. If roles changed meanwhile, the plan is
    /// refreshed instead, keeping the choices still available, for another review.
    @discardableResult
    func commitImport() async -> Bool {
        guard canCommitImport, let session = importSession, let plan = importPlan, let document = importDocument,
              store.beginImportRequest(session) else { return false }
        let roleIDs = importRoleIDs
        let replaceIDs = replaceRoleIDs
        isCommittingImport = true
        importFailure = nil
        importNotice = nil
        let result: Result<AgentRolesImportPlan, any Error>
        do {
            result = .success(try await session.client.importAgentRoles(
                document: document, dryRun: false, expectedRevision: plan.revision, planDigest: plan.planDigest,
                roleIDs: roleIDs, replaceRoleIDs: replaceIDs, localSkills: importLocalSkills))
        } catch {
            result = .failure(error)
        }
        store.endImportRequest()
        isCommittingImport = false
        guard importSession?.id == session.id else { return false }
        switch result {
        case let .success(response):
            do {
                guard response.ok, !response.dryRun, let overview = response.overview,
                      overview.revision >= plan.revision else { throw APIError.invalidResponse }
                let count = response.imported.map { $0.created + $0.updated } ?? roleIDs.count
                try store.adoptImport(overview, importedCount: count, session: session)
                return true
            } catch {
                importFailure = "The import wasn't confirmed. Reload Agent Roles to see what changed. \(error.localizedDescription)"
                return false
            }
        case let .failure(error):
            if case APIError.server(409, _) = error {
                if await self.plan(session, keeping: (plan, importSelection)) {
                    importNotice = "Roles changed on \(session.machineName). Review the updated plan."
                }
                return false
            }
            importFailure = message(for: error, machine: session.machineName, fallback: "The roles weren't imported.")
            return false
        }
    }

    func closeImport() {
        importSession = nil
        importFileName = nil
        importHeader = nil
        importDocument = nil
        importLocalSkills = [:]
        importPlan = nil
        importSelection = []
        importFailure = nil
        importNotice = nil
        isPlanningImport = false
        isCommittingImport = false
    }

    /// A refreshed plan keeps the reviewed choices by role ID. Roles the earlier
    /// plan didn't show start from the companion's defaults.
    private func plan(_ session: AgentRolesShareSession,
                      keeping previous: (plan: AgentRolesImportPlan, selection: Set<String>)?) async -> Bool {
        guard let document = importDocument else { return false }
        guard store.beginImportRequest(session) else {
            if store.isCurrent(session) { importFailure = "Agent Roles are busy. Try again in a moment." }
            return false
        }
        isPlanningImport = true
        let result: Result<AgentRolesImportPlan, any Error>
        do {
            result = .success(try await session.client.importAgentRoles(
                document: document, dryRun: true, expectedRevision: nil, planDigest: nil, roleIDs: nil, replaceRoleIDs: nil,
                localSkills: importLocalSkills))
        } catch {
            result = .failure(error)
        }
        store.endImportRequest()
        guard importSession?.id == session.id else { return false }
        isPlanningImport = false
        do {
            let plan = try result.get()
            guard store.isCurrent(session) else { return false }
            guard plan.ok, plan.dryRun, !plan.planDigest.isEmpty,
                  Set(plan.roles.map(\.id)).count == plan.roles.count else { throw APIError.invalidResponse }
            let selectable = Set(plan.roles.filter(\.isSelectable).map(\.id))
            var selection = Set(plan.roles.filter { $0.isSelectable && $0.selectedByDefault }.map(\.id))
            if let previous {
                let reviewed = Set(previous.plan.roles.map(\.id))
                selection = selection.subtracting(reviewed).union(previous.selection.intersection(selectable))
            }
            importPlan = plan
            importSelection = selection
            return true
        } catch {
            importPlan = nil
            importSelection = []
            importFailure = message(for: error, machine: session.machineName,
                                    fallback: "\(session.machineName) couldn't review this file.")
            return false
        }
    }

    /// One package at a time, so each skill gets the full per-package size budget.
    /// A skill this Mac can't package is left out, and the companion treats it as absent.
    private func localSkillHashes(for ids: [String]) async -> [String: String] {
        let local = Set(store.catalog.skills.map(\.id))
        var hashes: [String: String] = [:]
        for id in ids where local.contains(id) {
            guard let bundle = (try? await store.catalog.bundles(for: [id]))?.first(where: { $0.id == id }) else { continue }
            let hash = await Task.detached(priority: .userInitiated) { AgentRoleSkillContentHash.hash(bundle) }.value
            if let hash { hashes[id] = hash }
        }
        return hashes
    }

    private static func withoutByteOrderMark(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    }

    // MARK: Messages

    private func unavailableMessage(machine: String) -> String {
        store.overview != nil && !store.supportsSharing
            ? "Update the companion on \(machine) to share roles."
            : "Agent Roles on \(machine) aren't ready. Reload, then try again."
    }

    private func connectionChangedMessage(_ machine: String, action: String) -> String {
        "The connection to \(machine) changed. Close this window and \(action) again."
    }

    /// Companion explanations such as a blocked private key are shown as sent.
    private func message(for error: any Error, machine: String, fallback: String) -> String {
        if case let APIError.server(status, message) = error {
            if [404, 405, 426].contains(status) { return "Update the companion on \(machine) to share roles." }
            if (400..<500).contains(status), !message.isEmpty { return message }
        }
        return "\(fallback) \(error.localizedDescription)"
    }
}

extension AgentRolesShareFileHeader {
    /// Files above this are refused before they're read.
    static let maxFileBytes = 16 * 1024 * 1024
}

extension AgentRolesShareFileError {
    static let tooLarge = AgentRolesShareFileError("This file is larger than 16 MB. Ask for an export with fewer roles or skills.")
}
