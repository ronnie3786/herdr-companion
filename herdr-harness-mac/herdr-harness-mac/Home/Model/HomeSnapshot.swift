import Foundation

/// Coverage of the evidence, independent of filters and local presentation choices.
enum HomeAvailability: String, Equatable, Sendable {
    case loading, noMachines, current, stale, disconnected
}

struct HomeSnapshot: Equatable, Sendable {
    var availability: HomeAvailability = .loading
    /// True only after every applicable source answered and no unresolved work remains.
    var canShowAllClear = false
    var mood: HomeMood = .calm
    var greeting = "Welcome home."
    var dateLine = ""
    var statusLine = "Checking in with your machines."
    var firstMateStatus = "Ready when you are"
    var summary: [HomeText] = []
    var moving: HomeText = ""
    var focusTitle = "Start with these"
    var focus: [HomeFocusItem] = []
    var radar: [HomeRadarItem] = []
    var chatsTitle = "Chats waiting on you"
    var chats: [HomeChatItem] = []
    var recapTitle = "While you were away"
    var recap: [HomeRecapItem] = []
    var suggestions: [String] = []
    var focusCount = 0
    var reviewCount = 0
    var waitingChatCount = 0
    var watcherNeedsAttention = false
    var reviewNeedsAttention = false
    var isLoading = false
    var notices: [String] = []
    var coverageLine = ""
    var updatedAt: Date? = nil
}

struct HomeFocusItem: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var reason: String
    var body: HomeText
    var symbol = "sparkles"
    var emoji: String? = nil
    var watcherAvatar: String? = nil
    var tone: HomeTone = .accent
    var actions: [HomeAction] = []
    var route: HomeRoute
    var isIdea = false
    var isStale = false
    var updatedAt: Date? = nil
    /// Lower numbers come first. Machine outages precede blocked work and reviews.
    var priority = 50
    /// Only meaningful source evidence changes this; background polling never does.
    var fingerprint = ""
}

struct HomeRadarItem: Equatable, Identifiable, Sendable {
    var id: String
    var body: HomeText
    var symbol = "eye"
    var emoji: String? = nil
    var watcherAvatar: String? = nil
    var tone: HomeTone = .brandBlue
    var actions: [HomeAction] = []
    var fingerprint = ""
}

struct HomeChatItem: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var reason: String
    var location: String
    var quote: String
    var colorHex: String? = nil
    var actions: [HomeAction] = []
    var route: HomeRoute
    var isWaiting = true
    var isStale = false
}

struct HomeRecapItem: Equatable, Identifiable, Sendable {
    var id: String
    var date: Date?
    var timeLabel: String
    var symbol: String
    var tone: HomeTone = .idle
    var body: HomeText
    var route: HomeRoute? = nil
}
