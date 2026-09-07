import AppKit
import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("terminal application activation")
struct TerminalApplicationActivatorTests {
    @Test("Resolves terminal and requests foreground activation")
    func activatesExistingApplication() async throws {
        let expectedURL = URL(fileURLWithPath: "/Applications/ExampleTerminal.app")
        var resolvedBundleIdentifier: String?
        var openedURL: URL?
        var activates = false
        var addsToRecentItems = true

        try await TerminalApplicationActivator.activate(
            bundleIdentifier: "org.example.terminal",
            resolveApplicationURL: { bundleIdentifier in
                resolvedBundleIdentifier = bundleIdentifier
                return expectedURL
            },
            openApplication: { applicationURL, configuration in
                openedURL = applicationURL
                activates = configuration.activates
                addsToRecentItems = configuration.addsToRecentItems
            }
        )

        #expect(resolvedBundleIdentifier == "org.example.terminal")
        #expect(openedURL == expectedURL)
        #expect(activates)
        #expect(!addsToRecentItems)
    }

    @Test("Reports when terminal is not installed")
    func reportsMissingApplication() async {
        do {
            try await TerminalApplicationActivator.activate(
            bundleIdentifier: "org.example.terminal",
                resolveApplicationURL: { _ in nil },
                openApplication: { _, _ in }
            )
            Issue.record("Expected terminal activation to fail")
        } catch let error as TerminalApplicationActivator.ActivationError {
            #expect(error == .applicationNotFound(bundleIdentifier: "org.example.terminal"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
