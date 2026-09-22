import Foundation
import SwiftUI
import Testing
import WebKit
@testable import herdr_harness_mac

@MainActor
struct PaneGitNavigationDelegateTests {
    @Test("Rebuilt Git documents do not reload WebKit during native refreshes", arguments: [false, true])
    func repeatedNativeRefresh(firstMate: Bool) throws {
        let configuration = try #require(
            ServerConfiguration(urlString: "https://git.example.invalid", token: "synthetic-token")
        )
        let webView = GitLoadRecordingWebView()
        let delegate = PaneGitNavigationDelegate(phase: .constant(.ready))
        var retainedScripts: [String] = []

        for index in 0..<100 {
            let document = firstMate
                ? PaneGitWebDocument(
                    configuration: configuration,
                    firstMateTarget: .init(machineID: "desktop", featureID: "feature-one", workspaceID: "project")
                )
                : PaneGitWebDocument(configuration: configuration, workspaceID: "w1", paneID: "w1:p1")
            // Vary retained allocations and serialize, as a live app does, rather
            // than relying on a quiet JSON loop to expose key-order instability.
            retainedScripts.append(document.bootstrapScript + String(repeating: "x", count: index))
            if retainedScripts.count > 20 { retainedScripts.removeFirst() }
            delegate.load(document, in: webView)
        }

        #expect(webView.requests.count == 1)
        #expect(delegate.loadedDocument?.url == webView.requests.first?.url)
    }

    @Test("Credential and target changes reload once without losing origin enforcement")
    func meaningfulChangesReload() throws {
        let configuration = try #require(
            ServerConfiguration(urlString: "https://git.example.invalid", token: "synthetic-token")
        )
        let rotated = try #require(
            ServerConfiguration(urlString: configuration.baseURL.absoluteString, token: "rotated-synthetic-token")
        )
        let moved = try #require(
            ServerConfiguration(urlString: "https://other.example.invalid", token: rotated.token)
        )
        let project = FirstMateGitWindowTarget(machineID: "desktop", featureID: "feature-one", workspaceID: "project")
        let worker = FirstMateGitWindowTarget(machineID: "desktop", featureID: "feature-one", workspaceID: "worker-one")
        let otherFeature = FirstMateGitWindowTarget(machineID: "desktop", featureID: "feature-two", workspaceID: "project")
        let inputs = [
            (configuration, project), (rotated, project), (rotated, worker),
            (rotated, otherFeature), (moved, otherFeature),
        ]
        let webView = GitLoadRecordingWebView()
        let delegate = PaneGitNavigationDelegate(phase: .constant(.ready))
        for (index, input) in inputs.enumerated() {
            for _ in 0..<3 {
                delegate.load(PaneGitWebDocument(configuration: input.0, firstMateTarget: input.1), in: webView)
            }
            #expect(webView.requests.count == index + 1)
        }
        #expect(delegate.loadedDocument?.allowedOrigin.contains(moved.baseURL) == true)
        #expect(delegate.loadedDocument?.allowedOrigin.contains(configuration.baseURL) == false)
    }
}

/// Exercises the real navigation guard without contacting a server or storing
/// credentials. Full-page reloads are counted at WebKit's load boundary.
@MainActor
private final class GitLoadRecordingWebView: WKWebView {
    private(set) var requests: [URLRequest] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    required init?(coder: NSCoder) { nil }

    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        return nil
    }
}
