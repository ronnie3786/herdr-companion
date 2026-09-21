import Foundation

/// A validated PR Review deep link. Keeping URL validation here means shell
/// navigation never accepts arbitrary server origins or malformed line targets.
struct PRReviewOpenRequest: Equatable {
    let id = UUID()
    let reviewID: String
    let serverURL: String
    let file: String?
    let line: Int?
    let side: PRReviewSide
    let tab: PRReviewTab

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "herdr",
              components.host == "pr-review",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.fragment == nil else {
            return nil
        }

        let items = components.queryItems ?? []
        let allowedNames: Set<String> = ["review_id", "server_url", "file", "line", "side", "tab"]
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ allowedNames.contains($0.name) }) else {
            return nil
        }

        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let reviewID = values["review_id"],
              !reviewID.isEmpty,
              reviewID.count <= 128,
              let server = values["server_url"],
              let origin = ServerConfiguration(urlString: server, token: "route-validation"),
              let tab = PRReviewTab(rawValue: values["tab"] ?? "files"),
              let side = PRReviewSide(rawValue: values["side"] ?? "after") else {
            return nil
        }

        let line = values["line"].flatMap(Int.init)
        guard values["line"] == nil || line.map({ $0 > 0 }) == true else {
            return nil
        }

        self.reviewID = reviewID
        serverURL = origin.baseURL.absoluteString
        file = values["file"].flatMap { $0.isEmpty ? nil : $0 }
        self.line = line
        self.side = side
        self.tab = tab
    }
}
