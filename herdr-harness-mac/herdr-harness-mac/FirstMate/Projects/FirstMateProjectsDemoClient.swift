import Foundation

/// A complete, in-memory project flow for demo mode and native render tests.
/// It never enumerates the local filesystem or connects to a companion.
actor FirstMateProjectsDemoClient: FirstMateClient {
    static let home = "/Users/developer"
    private var projects: [FirstMateProject] = [
        .init(id: "demo-ios", name: "iOS App", cwd: home + "/Projects/ios-app", revision: 1, createdAt: FirstMateDemo.timestamp, updatedAt: FirstMateDemo.timestamp),
        .init(id: "demo-web", name: "Web App", cwd: home + "/Projects/web-app", revision: 1, createdAt: FirstMateDemo.timestamp, updatedAt: FirstMateDemo.timestamp),
    ]
    private var sessions: [String: FirstMateSnapshot] = [:]
    private var projectReceipts: [String: FirstMateProject] = [:]
    private var sessionReceipts: [String: FirstMateSnapshot] = [:]

    func fetchFirstMateCapabilities() async throws -> FirstMateCapabilities {
        .init(ok: true, capabilities: ["first-mate-projects-v1", "directory-browser-v1"], serverID: "synthetic-demo-server")
    }
    func fetchFirstMateProjects(scope: FirstMateFeatureScope) async throws -> FirstMateProjectList {
        .init(ok: true, serverID: "synthetic-demo-server", projects: projects.filter {
            scope == .all || (scope == .archived ? $0.isArchived : !$0.isArchived)
        })
    }
    func createFirstMateProject(name: String, cwd: String, requestID: String) async throws -> FirstMateProjectResponse {
        if let cached = projectReceipts[requestID] { return .init(ok: true, project: cached) }
        let folder = try await fetchDirectories(path: cwd, showHidden: false, cursor: nil)
        let project = FirstMateProject(id: UUID().uuidString, name: name, cwd: folder.path, revision: 1,
                                       createdAt: FirstMateDemo.timestamp, updatedAt: FirstMateDemo.timestamp)
        projects.append(project)
        projectReceipts[requestID] = project
        return .init(ok: true, project: project)
    }
    func updateFirstMateProject(id: String, name: String, cwd: String, expectedRevision: Int, requestID: String) async throws -> FirstMateProjectResponse {
        if let cached = projectReceipts[requestID] { return .init(ok: true, project: cached) }
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].revision == expectedRevision else {
            throw APIError.server(status: 409, message: "The project changed. Reload it before saving.")
        }
        let folder = try await fetchDirectories(path: cwd, showHidden: false, cursor: nil)
        projects[index].name = name
        projects[index].cwd = folder.path
        projects[index].revision += 1
        projectReceipts[requestID] = projects[index]
        return .init(ok: true, project: projects[index])
    }
    func setFirstMateProjectArchived(id: String, archived: Bool, expectedRevision: Int, requestID: String) async throws -> FirstMateProjectResponse {
        if let cached = projectReceipts[requestID] { return .init(ok: true, project: cached) }
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].revision == expectedRevision else {
            throw APIError.server(status: 409, message: "The project changed. Reload it before saving.")
        }
        projects[index].archivedAt = archived ? FirstMateDemo.timestamp : nil
        projects[index].revision += 1
        projectReceipts[requestID] = projects[index]
        return .init(ok: true, project: projects[index])
    }
    func fetchDirectories(path: String?, showHidden: Bool, cursor: String?) async throws -> FirstMateDirectoryList {
        let folder = (path ?? Self.home).replacingOccurrences(of: "~/", with: Self.home + "/")
        let children: [String]
        switch folder {
        case Self.home: children = ["Projects", "Documents", "Private", ".config"]
        case Self.home + "/Projects": children = ["ios-app", "web-app", "design-system"]
        case Self.home + "/Private": throw APIError.server(status: 403, message: "Herdr cannot read this folder. Choose another folder or update the companion’s access in System Settings.")
        case Self.home + "/Documents", Self.home + "/.config": children = []
        default:
            let roots = ["ios-app", "web-app", "design-system"].map { Self.home + "/Projects/" + $0 }
            if roots.contains(folder) { children = ["Sources", "Tests", "docs", ".git"] }
            else if roots.contains(where: { root in ["Sources", "Tests", "docs", ".git"].contains { folder == root + "/" + $0 } }) { children = [] }
            else { throw APIError.server(status: 404, message: "This folder is unavailable in the synthetic demo. Choose Home to browse the example folders.") }
        }
        return .init(ok: true, path: folder, parentPath: folder == Self.home ? nil : String(folder[..<folder.lastIndex(of: "/")!]),
                     homePath: Self.home, entries: children.filter { showHidden || !$0.hasPrefix(".") }.map {
            .init(name: $0, path: folder + "/" + $0, resolvedPath: folder + "/" + $0, isSymlink: false, canOpen: $0 != "Private")
        }, nextCursor: nil)
    }
    func createFirstMateFeature(title: String, goal: String, projectID: String, expectedProjectRevision: Int, requestID: String) async throws -> FirstMateSnapshot {
        if let cached = sessionReceipts[requestID] { return cached }
        guard let project = projects.first(where: { $0.id == projectID }), project.revision == expectedProjectRevision, !project.isArchived else {
            throw APIError.server(status: 409, message: "The project changed. Choose it again before starting.")
        }
        var snapshot = FirstMateDemo.newFeature(title: title, goal: goal, cwd: project.cwd)
        snapshot.feature.projectID = project.id
        snapshot.feature.projectName = project.name
        snapshot.feature.projectRevision = project.revision
        sessions[snapshot.feature.id] = snapshot
        sessionReceipts[requestID] = snapshot
        return snapshot
    }
    func createFirstMateFeature(title: String, goal: String, cwd: String, requestID: String) async throws -> FirstMateSnapshot {
        if let cached = sessionReceipts[requestID] { return cached }
        let folder = try await fetchDirectories(path: cwd, showHidden: false, cursor: nil)
        let snapshot = FirstMateDemo.newFeature(title: title, goal: goal, cwd: folder.path)
        sessions[snapshot.feature.id] = snapshot
        sessionReceipts[requestID] = snapshot
        return snapshot
    }
    func fetchFirstMateFeatures() async throws -> FirstMateFeatureList { .init(ok: true, features: sessions.values.map(\.feature)) }
    func fetchFirstMateFeature(_ id: String) async throws -> FirstMateSnapshot {
        guard let snapshot = sessions[id] else { throw APIError.invalidResponse }
        return snapshot
    }
    func sendFirstMateMessage(featureID: String, text: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func performFirstMateAction(featureID: String, action: String, requestID: String) async throws -> FirstMateSnapshot { throw APIError.invalidResponse }
    func fetchFirstMateDocument(_ id: String) async throws -> FirstMateDocumentResponse { throw APIError.invalidResponse }
    func fetchFirstMateSession(_ id: String, before: Int?) async throws -> FirstMateSessionResponse { throw APIError.invalidResponse }
}
