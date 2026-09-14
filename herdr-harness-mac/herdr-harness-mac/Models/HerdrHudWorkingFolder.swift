import Foundation

/// A HUD folder is an opaque path owned by the selected companion machine.
///
/// `~` is a transport-neutral home-folder choice. It is deliberately not
/// expanded here: the companion that receives a request owns the filesystem,
/// and expanding it on this Mac would point a remote chat at the wrong user.
struct HerdrHudWorkingFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let homePath = "~"
    static let home = HerdrHudWorkingFolder(path: homePath)

    let path: String

    var id: String { path }
    var isHome: Bool { path == Self.homePath }

    /// The existing agent-run contract treats an omitted cwd as the target
    /// machine's home folder. Keep that distinction from a custom absolute
    /// path in one place.
    var requestPath: String? { isHome ? nil : path }

    init(path: String) {
        self.path = path
    }

    static func normalizedPath(_ rawPath: String) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        if path == homePath { return homePath }
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    static func displayPath(_ path: String, for machine: HerdrMachine?) -> String {
        guard path != homePath, isLocalMachine(machine) else { return path }
        let localHome = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == localHome || path.hasPrefix(localHome + "/") else { return path }
        return "~" + String(path.dropFirst(localHome.count))
    }

    func displayPath(for machine: HerdrMachine?) -> String {
        Self.displayPath(path, for: machine)
    }

    static func isLocalMachine(_ machine: HerdrMachine?) -> Bool {
        guard let machine else { return false }
        if let role = machine.role?.lowercased(), ["local", "this_mac", "thismac"].contains(role) {
            return true
        }
        guard let components = URLComponents(string: machine.urlString),
              let host = components.host?.lowercased()
        else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}
