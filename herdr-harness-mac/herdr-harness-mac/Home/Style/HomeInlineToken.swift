import Foundation

enum HomeInlineToken: Equatable {
    case text(String), space(String), lineBreak(String), chip(HomeChip)

    var sourceText: String {
        switch self {
        case .text(let value), .space(let value), .lineBreak(let value): value
        case .chip(let chip): chip.title
        }
    }

    var isSpace: Bool {
        if case .space = self { true } else { false }
    }

    static func tokenize(_ text: HomeText) -> [HomeInlineToken] {
        var tokens: [HomeInlineToken] = []
        for run in text.runs {
            switch run {
            case .chip(let chip): tokens.append(.chip(chip))
            case .text(let text):
                var buffer = ""
                var wasSpace = false
                func flush() {
                    guard !buffer.isEmpty else { return }
                    tokens.append(wasSpace ? .space(buffer) : .text(buffer))
                    buffer = ""
                }
                for character in text {
                    if character.isNewline {
                        flush()
                        tokens.append(.lineBreak(String(character)))
                    } else {
                        let space = character.isWhitespace
                        if !buffer.isEmpty, wasSpace != space { flush() }
                        wasSpace = space
                        buffer.append(character)
                    }
                }
                flush()
            }
        }
        return tokens
    }
}
