import Foundation

/// Local user locations only. Companion package paths are never picker sources.
enum AgentRoleSkillLocations {
    static var userHome: URL? {
        // NSHomeDirectory() can be the app's sandbox container.
        NSHomeDirectoryForUser(NSUserName()).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func defaults(home: URL) -> [AgentRoleCatalogSource] {
        [
            ("agents", "Agent skills", ".agents/skills"),
            ("codex", "Codex", ".codex/skills"),
            ("claude", "Claude", ".claude/skills"),
            ("dox-agent", "Dox Agent", ".config/dox-agent/skills"),
            ("point-free", "Point-Free", ".pfw/skills"),
            ("pi", "Pi", ".pi/agent/skills"),
        ].map { id, name, path in
            AgentRoleCatalogSource(id: id, name: name, path: home.appendingPathComponent(path).path, automatic: true)
        }
    }

    static func label(for url: URL, home: URL?) -> String {
        guard let home else { return url.lastPathComponent }
        return defaults(home: home).first { URL(fileURLWithPath: $0.path).standardizedFileURL == url.standardizedFileURL }?.name
            ?? url.lastPathComponent
    }
}
