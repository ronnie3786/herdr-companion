import Foundation
import Observation

@MainActor @Observable
final class FirstMateProjectEditorModel: Identifiable {
    private struct Content: Equatable {
        let name: String
        let cwd: String
        let machineID: String?
        let archived: Bool?
    }
    private struct Request {
        let content: Content
        let connection: FirstMateProjectConnection
        let requestID: String
        let expectedRevision: Int?
    }

    let id = UUID()
    var name: String
    var cwd: String
    var machineID: String?
    private(set) var original: FirstMateProject?
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var isConflict = false
    @ObservationIgnored private var originalConnection: FirstMateProjectConnection?
    @ObservationIgnored private var pending: Request?

    init(choice: FirstMateProjectChoice? = nil, connection: FirstMateProjectConnection? = nil, preferredMachineID: String? = nil) {
        original = choice?.project
        name = choice?.project.name ?? ""
        cwd = choice?.project.cwd ?? ""
        machineID = choice?.host.machineID ?? preferredMachineID
        originalConnection = connection
    }

    var isEditing: Bool { original != nil }
    var isArchived: Bool { original?.isArchived == true }

    func canSave(in index: FirstMateProjectIndex) -> Bool {
        !isSaving && !isConflict && !isArchived && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.unicodeScalars.count <= 160
            && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 0x2028 || $0.value == 0x2029 })
            && (cwd.hasPrefix("/") || cwd == "~" || cwd.hasPrefix("~/"))
            && cwd.unicodeScalars.count <= 4096 && !cwd.contains("\0")
            && index.host(machineID)?.canManageProjects == true
            && (originalConnection.map(index.isCurrent) ?? true)
    }

    func changeMachine() {
        guard !isEditing, !isSaving else { return }
        cwd = ""
        pending = nil
        error = nil
        isConflict = false
    }

    func connection(in index: FirstMateProjectIndex) -> FirstMateProjectConnection? {
        let connection = originalConnection ?? index.connection(for: machineID)
        guard let connection, index.isCurrent(connection) else { return nil }
        return connection
    }

    func save(in index: FirstMateProjectIndex) async -> FirstMateProjectSelection? {
        guard canSave(in: index) else { return nil }
        return await perform(archived: nil, in: index)
    }

    func setArchived(_ archived: Bool, in index: FirstMateProjectIndex) async -> FirstMateProjectSelection? {
        guard original != nil, !isSaving, !isConflict, index.host(machineID)?.canManageProjects == true else { return nil }
        return await perform(archived: archived, in: index)
    }

    func reload(in index: FirstMateProjectIndex) async {
        guard !isSaving, let original, let machineID else { return }
        await index.refresh()
        guard let host = index.host(machineID), host.canManageProjects, host.error == nil else {
            error = "Could not reload this project. Reconnect its companion and try again. Your changes have been kept."
            return
        }
        guard let value = index.choice(.init(machineID: machineID, projectID: original.id)),
              let current = index.connection(for: machineID),
              index.isCurrent(current),
              originalConnection.map({ $0.serverID == current.serverID }) ?? true else {
            error = "This project’s owning companion is no longer available. Close this editor and reconnect it."
            return
        }
        self.original = value.project
        originalConnection = current
        name = value.project.name
        cwd = value.project.cwd
        error = nil
        isConflict = false
        pending = nil
    }

    private func perform(archived: Bool?, in index: FirstMateProjectIndex) async -> FirstMateProjectSelection? {
        guard let connection = connection(in: index) else {
            error = "This machine’s connection changed. Close the editor and open the project again."
            return nil
        }
        let content = Content(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              cwd: cwd, machineID: machineID, archived: archived)
        let request: Request
        if let pending, pending.content == content { request = pending }
        else {
            request = .init(content: content, connection: connection, requestID: UUID().uuidString, expectedRevision: original?.revision)
            pending = request
        }
        guard index.isCurrent(request.connection) else {
            error = "This request belongs to a previous connection. Check the project list before saving again."
            return nil
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let response: FirstMateProjectResponse
            if let original, let revision = request.expectedRevision {
                if let archived = content.archived {
                    response = try await request.connection.client.setFirstMateProjectArchived(
                        id: original.id, archived: archived, expectedRevision: revision, requestID: request.requestID)
                } else {
                    response = try await request.connection.client.updateFirstMateProject(
                        id: original.id, name: content.name, cwd: content.cwd, expectedRevision: revision, requestID: request.requestID)
                }
                guard response.project.id == original.id else { throw APIError.invalidResponse }
            } else {
                response = try await request.connection.client.createFirstMateProject(
                    name: content.name, cwd: content.cwd, requestID: request.requestID)
            }
            guard response.ok, !response.project.id.isEmpty else { throw APIError.invalidResponse }
            guard index.isCurrent(request.connection), !Task.isCancelled else {
                error = "The request reached \(request.connection.machineName), but the connection changed. Check its project list before saving again."
                return nil
            }
            index.receive(response.project, from: request.connection)
            pending = nil
            return .init(machineID: request.connection.machineID, projectID: response.project.id)
        } catch {
            self.error = "\(error.localizedDescription) Your changes have been kept."
            if case APIError.server(let status, _) = error, status == 409 { isConflict = true }
            return nil
        }
    }
}
