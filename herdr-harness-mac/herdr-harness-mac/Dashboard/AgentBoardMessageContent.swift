import Foundation

/// Reads the existing PromptComposerSubmission attachment marker. Paths are
/// display metadata only: the board routes chips to the feature's full view and
/// never treats message content as permission to open a local file or URL.
struct AgentBoardMessageContent: Equatable {
    struct Attachment: Identifiable, Equatable {
        let id: String
        let filename: String
    }

    let text: String
    let attachments: [Attachment]

    static func parse(_ source: String) -> Self {
        var prose: [String] = []
        var attachments: [Attachment] = []
        var seen = Set<String>()
        var fence: (marker: Character, length: Int)?
        let prefix = "Attachment: `"

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix { $0 == marker }.count
                if length >= 3 {
                    if let current = fence {
                        if current.marker == marker, length >= current.length,
                           trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty {
                            fence = nil
                        }
                    } else {
                        fence = (marker, length)
                    }
                    prose.append(line)
                    continue
                }
            }

            guard fence == nil, line.hasPrefix(prefix), trimmed.hasSuffix("`") else {
                prose.append(line)
                continue
            }
            let path = String(trimmed.dropFirst(prefix.count).dropLast())
            guard !path.isEmpty, !path.contains("`") else {
                prose.append(line)
                continue
            }
            if seen.insert(path).inserted {
                let filename = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
                attachments.append(.init(id: path, filename: filename))
            }
        }
        return Self(text: prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
    }
}
