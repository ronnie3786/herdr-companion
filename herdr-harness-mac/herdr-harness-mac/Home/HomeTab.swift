import Foundation

enum HomeTab: String, CaseIterable, Identifiable {
    case home, reviews, watchers, chats
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .reviews: "PR Review"
        case .watchers: "Watchers"
        case .chats: "Chats"
        }
    }
    init(scope: HerdrDetailScope) {
        switch scope {
        case .home, .dashboard, .agentBoard, .activity: self = .home
        case .prReview: self = .reviews
        case .watchers: self = .watchers
        default: self = .chats
        }
    }
    var scope: HerdrDetailScope {
        switch self {
        case .home: .home
        case .reviews: .prReview
        case .watchers: .watchers
        case .chats: .session
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .reviews: "arrow.triangle.pull"
        case .watchers: "eye"
        case .chats: "bubble.left"
        }
    }
}
