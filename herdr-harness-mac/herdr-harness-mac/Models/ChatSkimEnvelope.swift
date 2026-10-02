import Foundation

struct ChatSkimEnvelope: Decodable, Sendable {
    let id: String?
    let skim: FirstMateSkim?
}

struct ChatSkimCapabilities: Decodable, Sendable {
    let enabled: Bool
    let minWords: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case minWords = "min_words"
    }
}
