import Foundation
import UserNotifications

/// The banner for a walkthrough that finished, or failed, on the companion.
///
/// The companion publishes `pr_review.walkthrough` once per walkthrough when
/// it settles, whether or not a review window was watching. Choosing the
/// banner opens the review through the validated `herdr://pr-review` link.
enum PRReviewWalkthroughNotification {
    static let routeKey = "pr_review_url"
    /// A replayed event older than this only updates the badge.
    static let freshness: TimeInterval = 30 * 60

    struct Event: Equatable, Sendable {
        var machineID: String
        var reviewID: String
        var guideID: String
        var succeeded: Bool
        var title: String
        var owner: String
        var repo: String
        var number: Int?
        var generatedAt: Date?

        init?(machineID: String, payload: JSONValue?) {
            guard case let .object(values) = payload,
                  case let .string(reviewID) = values["review_id"], !reviewID.isEmpty,
                  case let .string(guideID) = values["guide_id"], !guideID.isEmpty,
                  case let .string(state) = values["state"], state == "finished" || state == "failed"
            else { return nil }
            func text(_ key: String) -> String {
                if case let .string(value) = values[key] { return value }
                return ""
            }
            self.machineID = machineID
            self.reviewID = reviewID
            self.guideID = guideID
            succeeded = state == "finished"
            title = text("title")
            owner = text("owner")
            repo = text("repo")
            if case let .number(value) = values["number"] { number = Int(value) } else { number = nil }
            generatedAt = HerdrTimestamp.date(from: text("generatedAt"))
        }

        func isFresh(now: Date = Date()) -> Bool {
            guard let generatedAt else { return true }
            return now.timeIntervalSince(generatedAt) <= PRReviewWalkthroughNotification.freshness
        }
    }

    static func identifier(guideID: String) -> String { "pr-review-walkthrough-\(guideID)" }

    /// The review's deep link, or nil when the host has no valid URL.
    static func routeURL(reviewID: String, machineURL: String) -> URL? {
        guard let origin = ServerConfiguration(urlString: machineURL, token: "route-validation") else { return nil }
        var components = URLComponents()
        components.scheme = "herdr"
        components.host = "pr-review"
        components.queryItems = [
            URLQueryItem(name: "review_id", value: reviewID),
            URLQueryItem(name: "server_url", value: origin.baseURL.absoluteString),
            URLQueryItem(name: "tab", value: PRReviewTab.files.rawValue),
        ]
        return components.url
    }

    static func content(for event: Event, route: URL?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.succeeded ? "Walkthrough ready" : "Walkthrough couldn’t finish"
        let pullRequest = [event.owner.isEmpty || event.repo.isEmpty ? nil : "\(event.owner)/\(event.repo)",
                           event.number.map { "#\($0)" }].compactMap { $0 }.joined(separator: " ")
        let detail = [pullRequest.isEmpty ? nil : pullRequest, event.title.isEmpty ? nil : event.title]
            .compactMap { $0 }.joined(separator: " · ")
        content.body = event.succeeded
            ? (detail.isEmpty ? "Your PR walkthrough is ready." : detail)
            : (detail.isEmpty ? "Open the review to start a new walkthrough." : detail + " · Open the review to try again.")
        content.sound = .default
        content.threadIdentifier = "pr-review-walkthroughs"
        var userInfo: [String: String] = ["machine_id": event.machineID, "pr_review_id": event.reviewID]
        if let route { userInfo[routeKey] = route.absoluteString }
        content.userInfo = userInfo
        return content
    }
}
