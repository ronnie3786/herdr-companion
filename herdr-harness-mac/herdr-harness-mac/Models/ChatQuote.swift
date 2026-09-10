import Foundation

/// User-approved text context. Kept as a previewable chip until explicitly sent.
struct ChatQuote: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let comment: String
    let source: String

    init(id: UUID = UUID(), text: String, comment: String, source: String) {
        self.id = id
        self.text = text
        self.comment = comment
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, text, comment, source }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try values.decode(String.self, forKey: .text)
        comment = try values.decode(String.self, forKey: .comment)
        source = try values.decode(String.self, forKey: .source)
    }

    static func prompt(_ draft: String, quotes: [ChatQuote]) -> String {
        guard !quotes.isEmpty else { return draft }
        let segments = quotes.map { quote in
            quote.text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
                + "\n\nUser’s message: \(quote.comment)"
        }.joined(separator: "\n\n")
        return [draft, "Quoted response segments:\n\n" + segments]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
