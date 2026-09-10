import CryptoKit
import Foundation

struct PiClosedSessionArchive {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herdr/closed-pi-sessions", isDirectory: true)
    }

    func fileURL(scope: String) -> URL {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    func load(scope: String) throws -> [PiClosedSession] {
        let url = fileURL(scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PiClosedSession].self, from: Data(contentsOf: url))
    }

    func save(_ sessions: [PiClosedSession], scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(sessions).write(to: fileURL(scope: scope), options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL(scope: scope).path)
    }
}
