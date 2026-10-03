import Foundation

enum HomeTone: String, Sendable { case accent, attention, alert, signal, working, idle, brandBlue }
enum HomeMood: String, Sendable { case attentive, calm, happy, concerned, thinking }

struct HomeChip: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var symbol: String = "sparkles"
    var emoji: String? = nil
    var watcherAvatar: String? = nil
    var tone: HomeTone = .accent
    var route: HomeRoute
}

enum HomeTextRun: Equatable, Sendable {
    case text(String)
    case chip(HomeChip)
}

struct HomeText: Equatable, Sendable, ExpressibleByStringLiteral {
    var runs: [HomeTextRun]
    init(_ text: String) { runs = [.text(text)] }
    init(runs: [HomeTextRun]) { self.runs = runs }
    init(stringLiteral value: String) { self.init(value) }
    var plainText: String {
        runs.map { switch $0 { case let .text(text): text; case let .chip(chip): chip.title } }.joined()
    }
}
