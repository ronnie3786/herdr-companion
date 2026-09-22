import Foundation

/// The app-wide response brief length preference.
///
/// Raw values are the wire contract shared with the companion server's
/// `responseBriefLength` request field and `responseBriefs.lengthOptions`
/// capability. Requests that omit the field deliberately keep the legacy
/// pre-preset budgets.
enum ResponseBriefLength: String, Codable, CaseIterable, Hashable, Sendable {
    case minimal
    case medium
    case long

    /// Server capability version that first advertised configurable length.
    static let policyVersion = 2
    /// Safe preference when nothing valid has been stored yet.
    static let fallback = ResponseBriefLength.minimal

    static var options: [String] { allCases.map(\.rawValue) }

    var multiplier: Int {
        switch self {
        case .minimal: 1
        case .medium: 2
        case .long: 3
        }
    }

    var displayName: String {
        switch self {
        case .minimal: "Minimal"
        case .medium: "Medium"
        case .long: "Long"
        }
    }

    /// Visible-content ceilings for one preset and source.
    struct Budgets: Equatable, Sendable {
        let length: ResponseBriefLength
        let readableCharacters: Int
        let sourceWords: Int
        let maximumVisibleCharacters: Int
        let maximumVisibleWords: Int
    }

    /// Tiny sources keep a usable nonempty summary budget at every preset.
    static let minimumVisibleCharacters = 40
    static let maximumBaseVisibleCharacters = 240
    static let maximumBaseVisibleWords = 40

    static func baseVisibleCharacters(readableCharacters: Int) -> Int {
        max(
            minimumVisibleCharacters,
            min(maximumBaseVisibleCharacters, readableCharacters / 4)
        )
    }

    static func baseVisibleWords(sourceWords: Int) -> Int {
        sourceWords < maximumBaseVisibleWords
            ? maximumBaseVisibleWords
            : min(maximumBaseVisibleWords, sourceWords / 4)
    }

    /// The largest total visible-character ceiling across presets. It must stay
    /// representable inside the structural summary bound, or Long would be
    /// unattainable. `ResponseBriefValidationTests` pins that relationship.
    static var maximumVisibleCharacters: Int {
        long.multiplier * maximumBaseVisibleCharacters
    }

    static var maximumVisibleWords: Int {
        long.multiplier * maximumBaseVisibleWords
    }

    func budgets(readableCharacters: Int, sourceWords: Int) -> Budgets {
        Budgets(
            length: self,
            readableCharacters: readableCharacters,
            sourceWords: sourceWords,
            maximumVisibleCharacters: multiplier * Self.baseVisibleCharacters(
                readableCharacters: readableCharacters
            ),
            maximumVisibleWords: multiplier * Self.baseVisibleWords(sourceWords: sourceWords)
        )
    }
}
