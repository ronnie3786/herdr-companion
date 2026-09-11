import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Response pane hyperlinks")
struct PaneResponseLinkTests {
    private func pane(machine: String = "desktop", id: String = "w3:p9", terminal: String = "term-1") throws -> HerdrPane {
        try JSONDecoder().decode(HerdrPane.self, from: Data("""
        {"pane_id":"\(id)","terminal_id":"\(terminal)","workspace_id":"w3","tab_id":"w3:t1"}
        """.utf8)).stamped(machineID: machine)
    }

    private var machines: [HerdrMachine] {
        [HerdrMachine(id: "desktop", name: "Desktop", urlString: "https://desktop.example.invalid:8461"),
         HerdrMachine(id: "laptop", name: "Laptop", urlString: "https://laptop.example.invalid")]
    }

    private func catalog(source: String? = "desktop", panes: [HerdrPane]? = nil) throws -> PaneResponseLinkCatalog {
        PaneResponseLinkCatalog(panes: try panes ?? [pane(), pane(machine: "laptop")], machines: machines, sourceMachineID: source)
    }

    private func links(_ source: AttributedString) -> [URL] { source.runs.compactMap(\.link) }

    @Test("Bare IDs use the response machine, never an unrelated machine with the same ID")
    func rawMachineScoping() throws {
        let desktop = try catalog()
        #expect(desktop.target(for: "w3:p9")?.scopedID == "desktop|w3:p9")
        #expect(desktop.target(for: "laptop|w3:p9")?.scopedID == "laptop|w3:p9")
        #expect(try catalog(source: nil).target(for: "w3:p9") == nil)
        #expect(try catalog(source: "missing").target(for: "w3:p9") == nil)
        #expect(desktop.target(for: "w3:p404") == nil)
        #expect(desktop.target(for: "unknown|w3:p9") == nil)
        #expect(try catalog(source: nil, panes: [pane()]).target(for: "w3:p9")?.machineID == "desktop")
    }

    @Test("Custom and registered universal links resolve percent-encoded paths and query aliases")
    func deeplinks() throws {
        let context = try catalog()
        for raw in ["herdr://pane/w3%3Ap9", "herdr://pane?pane_id=w3%3Ap9", "herdr://pane?paneId=w3:p9", "herdr://pane?pane=w3:p9"] {
            #expect(context.target(for: raw)?.scopedID == "desktop|w3:p9")
        }
        #expect(context.target(for: "https://laptop.example.invalid/open/pane/w3%3Ap9")?.scopedID == "laptop|w3:p9")
        #expect(context.target(for: "https://desktop.example.invalid:8461/open/pane?pane_id=w3:p9")?.scopedID == "desktop|w3:p9")
        #expect(context.target(for: "herdr://pane/laptop%7Cw3%3Ap9")?.scopedID == "laptop|w3:p9")
        #expect(context.target(for: "herdr://pane/w3:p9?machineId=laptop")?.scopedID == "laptop|w3:p9")
    }

    @Test("Ambiguous, conflicting, malformed, unknown-origin, and credential-bearing links are rejected")
    func rejectsUnsafeLinks() throws {
        let context = try catalog()
        for raw in [
            "https://other.example.invalid/open/pane/w3:p9",
            "https://desktop.example.invalid/open/pane/w3:p9", // Wrong port.
            "https://laptop.example.invalid/open/pane/desktop%7Cw3:p9",
            "herdr://pane/w3:p9?pane_id=w3:p8",
            "herdr://pane?pane=w3:p9&pane_id=w3:p9",
            "herdr://pane/desktop%7Cw3:p9?machine=laptop",
            "herdr://pane/w3:p9/extra", "herdr://pi?pane=w3:p9",
            "herdr://credentials@pane/w3:p9", "w3:p9.swift", "xw3:p9", "w3:p9|extra",
        ] {
            #expect(context.target(for: raw) == nil, "Unexpected target for \(raw)")
        }
        let ambiguous = PaneResponseLinkCatalog(panes: try [pane(), pane(machine: "laptop")], machines: [
            HerdrMachine(id: "desktop", name: "One", urlString: "https://shared.example.invalid"),
            HerdrMachine(id: "laptop", name: "Two", urlString: "https://shared.example.invalid"),
        ], sourceMachineID: "desktop")
        #expect(ambiguous.target(for: "https://shared.example.invalid/open/pane/w3:p9") == nil)
    }

    @Test("Prose and inline code link without changing copied text or Markdown formatting")
    func styledTextAndUnicode() throws {
        let source = PiMarkdownText.render("📁 Open **w3:p9**, then `laptop|w3:p9`. Unknown w3:p404 stays plain.")
        let result = PaneResponseLinker.link(source, catalog: try catalog())
        #expect(String(result.characters) == String(source.characters))
        #expect(links(result).count == 2)
        #expect(result.runs.contains { $0.link != nil && $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(result.runs.contains { $0.link != nil && $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let targets = links(result).compactMap { try? catalog().target(for: $0)?.scopedID }
        #expect(targets == ["desktop|w3:p9", "laptop|w3:p9"])
    }

    @Test("IDs embedded in paths, URLs, larger tokens and examples are not partially linked")
    func tokenBoundaries() throws {
        let source = AttributedString("xw3:p9 /tmp/w3:p9 w3:p9.swift x-w3:p9 w3:p9-more foo|w3:p9 https://else.example.invalid/?pane=w3:p9 ftp://else.example.invalid/?pane=w3:p9")
        #expect(links(PaneResponseLinker.link(source, catalog: try catalog())).isEmpty)
        let valid = PaneResponseLinker.link(AttributedString("(w3:p9), w3:p9.\nw3:p9!"), catalog: try catalog())
        #expect(links(valid).count == 3)
    }

    @Test("Plain deep links trim trailing sentence punctuation and bind to their own origin")
    func plainURLs() throws {
        let result = PaneResponseLinker.link(AttributedString("See https://laptop.example.invalid/open/pane/w3:p9). Or herdr://pane/w3:p9."), catalog: try catalog())
        #expect(links(result).count == 2)
        let context = try catalog()
        #expect(links(result).compactMap { context.target(for: $0)?.machineID } == ["laptop", "desktop"])
    }

    @Test("Explicit pane links keep their labels; invalid destinations never retarget their label")
    func existingMarkdownLinks() throws {
        let source = PiMarkdownText.render("[Open chat](herdr://pane/w3:p9) [w3:p9](herdr://pane/w3:p404) [w3:p9](https://example.invalid)")
        let result = PaneResponseLinker.link(source, catalog: try catalog())
        #expect(String(result.characters) == String(source.characters))
        #expect(links(result).count == 2)
        #expect(links(result).last?.absoluteString == "https://example.invalid")
    }

    @Test("Closed panes lose links and terminal replacement invalidates an already-rendered href")
    func staleTargets() throws {
        let before = try catalog()
        let url = try #require(before.target(for: "w3:p9")?.url)
        #expect(before.target(for: url)?.terminalID == "term-1")
        let closed = try catalog(panes: [])
        #expect(closed.target(for: url) == nil)
        #expect(links(PaneResponseLinker.link(AttributedString("w3:p9"), catalog: closed)).isEmpty)
        let changed = try catalog(panes: [pane(terminal: "replacement")])
        #expect(changed.target(for: url) == nil)
        #expect(changed.target(for: "w3:p9")?.terminalID == "replacement")
    }

    @Test("A rendered selectable link opens in-app and rechecks a pane closed after rendering")
    func renderedLinkDispatch() async throws {
        let suite = "PaneResponseLinkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = machines
        model.machineStates["desktop"] = .live
        model.workspaces = [HerdrWorkspace(workspaceID: "w3", number: 1, label: "Project", focused: true,
                                          paneCount: 1, tabCount: 1, activeTabID: "w3:t1", agentStatus: .idle,
                                          panes: [try pane()]).stamped(machineID: "desktop")]
        var opened: [String] = []
        let host = NSHostingView(rootView: PiMarkdownText("Open `w3:p9`.")
            .environment(\.detectsPaneResponseLinks, true)
            .environment(\.saveChatQuote, { _ in })
            .paneResponseLinks(model: model, sourceMachineID: "desktop", openPane: { opened.append($0) })
            .frame(width: 320, height: 80))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let text = try #require(descendants(host).compactMap { $0 as? ChatSelectionTextView }.first)
        let range = (text.string as NSString).range(of: "w3:p9")
        let href = try #require(text.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
        text.clicked(onLink: href, at: range.location)
        #expect(opened == ["desktop|w3:p9"])
        model.workspaces = []
        text.clicked(onLink: href, at: range.location)
        #expect(opened == ["desktop|w3:p9"])
        #expect(model.toastMessage?.contains("no longer available") == true)
    }

    @Test("TextKit quoted messages use the SwiftUI link handler, including after updates")
    func textKitDispatch() throws {
        var opened: [URL] = []
        let delegate = ChatTextLinkDelegate(openURL: OpenURLAction { url in opened.append(url); return .handled })
        let text = ChatSelectionTextView()
        let url = try #require(URL(string: "herdr://pane/w3:p9"))
        #expect(delegate.textView(text, clickedOnLink: url, at: 0))
        #expect(opened == [url])
        delegate.openURL = OpenURLAction { _ in return .handled }
        #expect(delegate.textView(text, clickedOnLink: url.absoluteString, at: 0))
        #expect(opened == [url])
        #expect(!delegate.textView(text, clickedOnLink: 123, at: 0))
    }
}
