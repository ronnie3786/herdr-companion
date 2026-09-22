import Foundation

struct PaneGitWebDocument: Equatable {
    let url: URL
    let allowedOrigin: PaneGitWebOrigin
    private let nativeConfiguration: NativeConfiguration

    // Navigation identity is semantic, never the incidental order of JSON keys.
    // Only serialize when installing the script into a new web document.
    var bootstrapScript: String { Self.makeBootstrapScript(nativeConfiguration) }

    private struct NativeConfiguration: Encodable, Equatable {
        let token: String
        let serverUrl: String
        let hostIsLocal: Bool
    }

    init(
        configuration: ServerConfiguration,
        workspaceID: String,
        paneID: String
    ) {
        self.init(configuration: configuration, routeItems: [
            URLQueryItem(name: "ws", value: workspaceID),
            URLQueryItem(name: "pane", value: paneID),
        ])
    }

    init(configuration: ServerConfiguration, firstMateTarget: FirstMateGitWindowTarget) {
        self.init(configuration: configuration, routeItems: [
            URLQueryItem(name: "firstMate", value: firstMateTarget.featureID),
            URLQueryItem(name: "workspace", value: firstMateTarget.workspaceID),
        ])
    }

    private init(configuration: ServerConfiguration, routeItems: [URLQueryItem]) {
        let pageURL = configuration.baseURL.appending(
            path: "herdr-web",
            directoryHint: .isDirectory
        )
        var pageComponents = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        var routeComponents = URLComponents()
        routeComponents.queryItems = routeItems + [
            URLQueryItem(name: "view", value: "git"),
            URLQueryItem(name: "embed", value: "1"),
        ]
        pageComponents?.percentEncodedFragment = routeComponents.percentEncodedQuery

        url = pageComponents?.url ?? pageURL
        nativeConfiguration = NativeConfiguration(
            token: configuration.token,
            serverUrl: configuration.baseURL.absoluteString,
            hostIsLocal: Self.harnessRunsOnThisMachine(configuration.baseURL)
        )
        allowedOrigin = PaneGitWebOrigin(url: configuration.baseURL)
    }

    /// True when the harness this document loads from runs on the Mac in
    /// front of the user — loopback URLs and this Mac's own hostnames count.
    static func harnessRunsOnThisMachine(_ url: URL) -> Bool {
        guard let rawHost = url.host(percentEncoded: false)?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }

        let localNames = Self.localHostNames()
        if localNames.contains(host) { return true }
        // Tailnet-style URLs may name the machine with a dotted suffix.
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        return localNames.contains(firstLabel)
    }

    private static func localHostNames() -> Set<String> {
        var names: Set<String> = []
        let hostName = ProcessInfo.processInfo.hostName.lowercased()
        guard !hostName.isEmpty else { return names }
        names.insert(hostName)
        let labels = hostName.split(separator: ".")
        if let first = labels.first {
            let short = String(first)
            names.insert(short)
            names.insert("\(short).local")
        }
        return names
    }

    private static func makeBootstrapScript(_ nativeConfiguration: NativeConfiguration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try? encoder.encode(nativeConfiguration)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        Object.defineProperty(window, "__HERDR_NATIVE_CONFIG__", {
          value: Object.freeze(\(json)),
          writable: false,
          configurable: false
        });
        """
    }
}