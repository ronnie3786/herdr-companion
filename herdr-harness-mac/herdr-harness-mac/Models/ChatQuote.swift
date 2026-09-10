import Foundation

/// A user-approved excerpt, not an instruction until explicitly sent with a prompt.
struct ChatQuote: Codable, Equatable, Sendable {
    let text: String
    let comment: String
    let source: String

    var markdown: String {
        "# Quoted chat context\n\nSource: \(source)\n\n"
            + text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            + "\n\n## Comment\n\n\(comment)\n"
    }

    func writeAttachment() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-quote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("Quoted chat.md")
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }
}
