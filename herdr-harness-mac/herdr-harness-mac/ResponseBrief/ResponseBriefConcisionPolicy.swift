import Foundation

struct ResponseBriefConcisionPolicy: Equatable, Sendable {
    struct SourceMetrics: Equatable, Sendable {
        let readableCharacters: Int
        let sourceWords: Int
        let maximumVisibleCharacters: Int
        let maximumVisibleWords: Int

        var shouldGenerate: Bool { readableCharacters > 160 }
    }

    let metrics: SourceMetrics

    init(source: String) {
        let readable = Self.readableSourceText(source)
        let readableCharacters = readable.unicodeScalars.count(where: Self.isLetterOrNumber)
        let sourceWords = Self.wordCount(readable)
        metrics = SourceMetrics(
            readableCharacters: readableCharacters,
            sourceWords: sourceWords,
            maximumVisibleCharacters: min(240, readableCharacters / 4),
            maximumVisibleWords: sourceWords < 40 ? 40 : min(40, sourceWords / 4)
        )
    }

    func validate(_ brief: ResponseBrief) throws {
        guard brief.points.count <= 1, brief.details.count <= 2 else {
            throw ResponseBriefValidationError.notConcise
        }
        guard brief.points.allSatisfy({ Self.wordCount($0.text) <= 12 }),
              brief.details.allSatisfy({
                  Self.wordCount($0.label) <= 4
                      && Self.nonWhitespaceScalarCount($0.label) <= 28
              })
        else {
            throw ResponseBriefValidationError.notConcise
        }

        let visible = brief.visibleGeneratedStrings.joined(separator: " ")
        guard Self.wordCount(visible) <= metrics.maximumVisibleWords,
              Self.nonWhitespaceScalarCount(visible) <= metrics.maximumVisibleCharacters
        else {
            throw ResponseBriefValidationError.notConcise
        }
    }

    func accepts(_ brief: ResponseBrief) -> Bool {
        do {
            try validate(brief)
            return true
        } catch {
            return false
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { token in
            token.unicodeScalars.contains(where: isLetterOrNumber)
        }
    }

    static func nonWhitespaceScalarCount(_ text: String) -> Int {
        text.unicodeScalars.count { !$0.properties.isWhitespace }
    }

    static func readableSourceText(_ source: String) -> String {
        let value = replacing(
            #"^[ \t]{0,3}\[[^\]\r\n]+\]:[^\r\n]*$"#,
            in: source.replacing("\r\n", with: "\n"),
            options: [.anchorsMatchLines]
        )
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            if startsWith("<!--", in: scalars, at: index) {
                if let end = firstIndex(of: "-->", in: scalars, after: index + 4) {
                    index = end + 3
                } else {
                    index = scalars.count
                }
                continue
            }

            let scalar = scalars[index]
            if scalar == "<", let end = htmlTagEnd(in: scalars, start: index) {
                index = end + 1
                continue
            }

            if scalar == "\\", index + 1 < scalars.count {
                result.append(scalar)
                result.append(scalars[index + 1])
                index += 2
                continue
            }

            let isImage = scalar == "!"
                && index + 1 < scalars.count
                && scalars[index + 1] == "["
            let bracketStart = isImage ? index + 1 : index
            if (isImage || scalar == "["),
               let labelEnd = balancedEnd(
                   in: scalars,
                   start: bracketStart,
                   opening: "[",
                   closing: "]"
               ) {
                if !isImage {
                    result.append(contentsOf: scalars[(bracketStart + 1)..<labelEnd])
                }
                let suffix = labelEnd + 1
                if suffix < scalars.count, scalars[suffix] == "(" {
                    index = balancedEnd(
                        in: scalars,
                        start: suffix,
                        opening: "(",
                        closing: ")"
                    ).map { $0 + 1 } ?? scalars.count
                    continue
                }
                if suffix < scalars.count, scalars[suffix] == "[" {
                    index = balancedEnd(
                        in: scalars,
                        start: suffix,
                        opening: "[",
                        closing: "]"
                    ).map { $0 + 1 } ?? scalars.count
                    continue
                }
                index = suffix
                continue
            }

            result.append(scalar)
            index += 1
        }
        return String(result)
    }

    private static func balancedEnd(
        in scalars: [Unicode.Scalar],
        start: Int,
        opening: Unicode.Scalar,
        closing: Unicode.Scalar
    ) -> Int? {
        var depth = 0
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                index += 2
                continue
            }
            if scalar == opening {
                depth += 1
            } else if scalar == closing {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func htmlTagEnd(in scalars: [Unicode.Scalar], start: Int) -> Int? {
        var next = start + 1
        guard next < scalars.count else { return nil }
        if scalars[next] == "/" {
            next += 1
            guard next < scalars.count, isLetter(scalars[next]) else { return nil }
        } else if !isLetter(scalars[next]) && scalars[next] != "!" && scalars[next] != "?" {
            return nil
        }

        var quote: Unicode.Scalar?
        var index = next
        while index < scalars.count {
            let scalar = scalars[index]
            if let activeQuote = quote {
                if scalar == activeQuote { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return index
            }
            index += 1
        }
        return scalars.count - 1
    }

    private static func startsWith(
        _ needle: String,
        in scalars: [Unicode.Scalar],
        at index: Int
    ) -> Bool {
        let target = Array(needle.unicodeScalars)
        guard index + target.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + target.count)]) == target
    }

    private static func firstIndex(
        of needle: String,
        in scalars: [Unicode.Scalar],
        after start: Int
    ) -> Int? {
        var index = start
        while index < scalars.count {
            if startsWith(needle, in: scalars, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
             .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [],
        template: String = ""
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return ""
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}

extension ResponseBrief {
    var visibleGeneratedStrings: [String] {
        [summary] + points.map(\.text) + details.map(\.label)
    }

    func conformsToConcisionPolicy(source: String) -> Bool {
        ResponseBriefConcisionPolicy(source: source).accepts(self)
    }
}
