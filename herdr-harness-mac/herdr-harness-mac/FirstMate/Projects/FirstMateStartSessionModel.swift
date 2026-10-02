import Foundation
import Observation

@MainActor @Observable
final class FirstMateStartSessionModel {
    private struct Draft: Equatable {
        let mode: FirstMateStartMode
        let selection: FirstMateProjectSelection?
        let machineID: String?
        let title: String
        let cwd: String
        let prompt: String
    }
    private struct Submission {
        let draft: Draft
        let connection: FirstMateProjectConnection
        let project: FirstMateProject?
        let requestID: String
    }

    var mode: FirstMateStartMode = .project
    var selectedProject: FirstMateProjectSelection?
    var manualMachineID: String?
    var manualTitle = ""
    var manualPath = ""
    var prompt = ""
    private(set) var isSending = false
    private(set) var error: String?
    private(set) var needsProjectReload = false
    @ObservationIgnored private var submission: Submission?

    private var draft: Draft {
        .init(mode: mode, selection: mode == .project ? selectedProject : nil,
              machineID: mode == .manual ? manualMachineID : selectedProject?.machineID,
              title: mode == .project ? Self.title(for: prompt) : manualTitle.trimmingCharacters(in: .whitespacesAndNewlines),
              cwd: mode == .manual ? manualPath : "", prompt: prompt)
    }

    private var pendingSubmission: Submission? {
        submission.flatMap { $0.draft == draft ? $0 : nil }
    }

    static func title(for prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        return String(firstLine.prefix(120))
    }

    func unavailableReason(in index: FirstMateProjectIndex) -> String? {
        // A lost response may hide an already-created session. Replaying that
        // exact request must not depend on the project's current catalog row.
        if !needsProjectReload, let pending = pendingSubmission {
            guard index.isCurrent(pending.connection), let host = index.host(pending.connection.machineID) else {
                return "The connection changed after this request was prepared. Check that machine’s sessions before clearing this form and starting again."
            }
            if !host.hasLoaded { return "Connecting to \(host.machineName)…" }
            if !host.isReachable {
                return "\(host.machineName) is unavailable. Reconnect it to retry the original request. Your prompt is kept here."
            }
            return nil
        }
        if mode == .project {
            guard let selectedProject else { return nil }
            guard let choice = index.choice(selectedProject) else { return "This project is no longer available. Choose a project to continue." }
            if choice.project.isArchived { return "This project is archived. Restore it in Projects or choose another project." }
            if !choice.host.hasLoaded { return "Connecting to \(choice.host.machineName)…" }
            if !choice.host.isReachable { return "\(choice.host.machineName) is unavailable. Reconnect it or choose another project. Your prompt is kept here." }
            if !choice.host.supportsProjects { return "Update this machine’s companion to use projects, or use Manual setup." }
            if let error = choice.host.error { return error }
        } else if let host = index.host(manualMachineID), host.hasLoaded, !host.isReachable {
            return "\(host.machineName) is unavailable. Reconnect it or choose another machine. Your prompt is kept here."
        }
        return nil
    }

    func canStart(in index: FirstMateProjectIndex) -> Bool {
        guard !isSending, !needsProjectReload, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= 200_000, !prompt.contains("\0"), unavailableReason(in: index) == nil else { return false }
        if pendingSubmission != nil { return true }
        if mode == .project {
            guard let choice = index.choice(selectedProject) else { return false }
            return choice.host.canManageProjects && !choice.project.isArchived
        }
        return !draft.title.isEmpty && draft.title.count <= 300 && draft.cwd.hasPrefix("/")
            && draft.cwd.count <= 4096 && !draft.cwd.contains("\0")
            && index.host(manualMachineID)?.isReachable == true
    }

    func chooseProject(_ selection: FirstMateProjectSelection) {
        guard !isSending else { return }
        // Selecting the same row is not a new request and must not lose an
        // unknown outcome's idempotency identity.
        guard mode != .project || selectedProject != selection else { return }
        selectedProject = selection
        mode = .project
        submission = nil
        needsProjectReload = false
        error = nil
    }

    func changeManualMachine() {
        guard !isSending else { return }
        manualPath = ""
        submission = nil
        error = nil
    }

    func clearErrorAfterEditing() {
        guard !isSending else { return }
        if submission?.draft != draft { submission = nil; error = nil; needsProjectReload = false }
    }

    func prepare(preferredMachineID: String? = nil) {
        if manualMachineID == nil { manualMachineID = preferredMachineID }
        error = nil
    }

    func reset() {
        guard !isSending else { return }
        prompt = ""
        manualTitle = ""
        manualPath = ""
        submission = nil
        error = nil
        needsProjectReload = false
    }

    func reloadProject(in index: FirstMateProjectIndex) async {
        guard !isSending, needsProjectReload else { return }
        await index.refresh()
        // Keep the known rejection visible until current project data can
        // actually be loaded. A failed refresh cannot authorize a new request.
        guard let choice = index.choice(selectedProject), choice.host.canManageProjects else { return }
        submission = nil
        needsProjectReload = false
        error = nil
    }

    func start(in index: FirstMateProjectIndex) async -> FirstMateStartedSession? {
        guard canStart(in: index) else { return nil }
        let currentDraft = draft
        let request: Submission
        if let pending = submission, pending.draft == currentDraft {
            request = pending
        } else {
            guard let connection = index.connection(for: currentDraft.machineID) else { return nil }
            request = .init(draft: currentDraft, connection: connection,
                            project: mode == .project ? index.choice(selectedProject)?.project : nil,
                            requestID: UUID().uuidString)
            submission = request
        }
        guard index.isCurrent(request.connection) else {
            error = "The connection changed after this request was prepared. Check the session list before starting again, then reselect the project or clear this form."
            return nil
        }
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            let value: FirstMateSnapshot
            if let project = request.project {
                value = try await request.connection.client.createFirstMateFeature(
                    title: request.draft.title, goal: request.draft.prompt, projectID: project.id,
                    expectedProjectRevision: project.revision, requestID: request.requestID
                )
                guard value.feature.projectID == project.id, value.feature.projectRevision == project.revision,
                      value.feature.cwd == project.cwd else { throw APIError.invalidResponse }
            } else {
                value = try await request.connection.client.createFirstMateFeature(
                    title: request.draft.title, goal: request.draft.prompt,
                    cwd: request.draft.cwd, requestID: request.requestID
                )
            }
            guard value.ok, !value.feature.id.isEmpty else { throw APIError.invalidResponse }
            guard index.isCurrent(request.connection), !Task.isCancelled else {
                error = "The request reached \(request.connection.machineName), but its connection changed. Check that machine’s sessions before starting again."
                return nil
            }
            submission = nil
            prompt = ""
            manualTitle = ""
            return .init(connection: request.connection, snapshot: value)
        } catch {
            self.error = error.localizedDescription
            if case APIError.server(let status, _) = error, status == 409, request.project != nil {
                needsProjectReload = true
            } else if !(error is CancellationError) {
                self.error = "\(error.localizedDescription) Your prompt has been kept. Retry sends the same request."
            }
            return nil
        }
    }
}
