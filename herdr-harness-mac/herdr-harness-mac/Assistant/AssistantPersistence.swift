import Foundation

actor AssistantPersistence {
    struct Snapshot: Codable, Sendable {
        var context: AssistantContext
        var draft: String
        var turns: [HeadlessAgentRun]
        var pending: AssistantRequest?
        var selectedModel: String
    }
    let url: URL
    init(url: URL) { self.url = url }
    func load() -> Snapshot? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: bytes)
    }
    func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
