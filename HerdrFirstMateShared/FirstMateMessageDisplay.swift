import Foundation

/// What your own bubble shows: the text without the dictation suffix (the
/// bubble says "Sent by voice" instead) and without `Attachment:` lines, which
/// become small chips. Display only; Copy keeps the message as sent.
struct FirstMateMessageDisplay: Equatable, Sendable {
    static let dictationSuffix = "(transcribed audio, please account for incorrect names or typos)"

    var body: String
    /// Attachment paths, in order.
    var attachments: [String]
    var isVoice: Bool

    static func parse(_ text: String) -> Self {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isVoice = false
        if remaining.hasSuffix(dictationSuffix) {
            isVoice = true
            remaining = String(remaining.dropLast(dictationSuffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var attachments: [String] = []
        var lines: [Substring] = []
        for line in remaining.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = attachmentPath(in: line) {
                attachments.append(path)
            } else {
                lines.append(line)
            }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(body: body, attachments: attachments, isVoice: isVoice)
    }

    /// `Attachment: `path`` (the composer's format), else nil.
    static func attachmentPath(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "Attachment: `"
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("`"), trimmed.count > prefix.count + 1 else { return nil }
        let path = trimmed.dropFirst(prefix.count).dropLast()
        guard !path.isEmpty, !path.contains("`") else { return nil }
        return String(path)
    }

    static func fileName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// What VoiceOver reads for your bubble: the text, the attached file
    /// names, and whether it is queued or was sent by voice, leaving out
    /// empty parts.
    func accessibilityLabel(isQueued: Bool) -> String {
        var parts: [String] = []
        if !body.isEmpty { parts.append(body) }
        if !attachments.isEmpty {
            parts.append("attached " + attachments.map(Self.fileName(of:)).joined(separator: ", "))
        }
        if isQueued { parts.append("queued") }
        if isVoice { parts.append("sent by voice") }
        return "You: " + parts.joined(separator: ", ")
    }
}
