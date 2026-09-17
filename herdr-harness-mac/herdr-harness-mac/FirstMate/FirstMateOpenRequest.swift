import Foundation

/// Navigation only. Links never send prompts, change credentials, or execute work.
struct FirstMateOpenRequest: Equatable {
    let id = UUID()
    let featureID: String
    let serverURL: String
    let tab: FirstMateInspector
    let graph: Bool

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "herdr", c.host == "first-mate", c.user == nil, c.password == nil,
              c.port == nil, c.path.isEmpty, c.fragment == nil else { return nil }
        let items = c.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["feature_id", "server_url", "tab", "view"].contains($0.name) }) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let feature = values["feature_id"], !feature.isEmpty, feature.count <= 128,
              let server = values["server_url"], let origin = ServerConfiguration(urlString: server, token: "route-validation"),
              let tab = FirstMateInspector.allCases.first(where: { $0.rawValue.lowercased() == (values["tab"] ?? "overview") }),
              values["view"] == nil || values["view"] == "graph" else { return nil }
        featureID = feature
        serverURL = origin.baseURL.absoluteString
        self.tab = tab
        graph = values["view"] == "graph"
    }
}

struct FirstMateNavigationIdentity: Equatable {
    let connection: FirstMateConnectionIdentity
    let requestID: UUID?
    let controlFeatureID: String?
}
