import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import herdr_harness_mac

@Suite("Watchers summaries")
struct WatchersSummaryTests {
    @Test("Schedule phrases capitalize only at a sentence start and punctuation stays on its chip")
    func punctuation() {
        #expect(WatchersSummary.parse("{time}, run {script:check.sh}. Then {time}!", schedule: "every hour") == [
            .chip(kind: "time", value: "Every hour", punctuation: ","), .word("run"),
            .chip(kind: "script", value: "check.sh", punctuation: "."), .word("Then"), .chip(kind: "time", value: "every hour", punctuation: "!")
        ])
        #expect(WatchersSummary.parse("Ready. {time}.", schedule: "weekdays at 9 AM").last == .chip(kind: "time", value: "Weekdays at 9 AM", punctuation: "."))
    }
    @Test("All nine chip kinds survive parsing without interpolating arbitrary markup")
    func grammar() {
        let markup = "{time} {slack:#example} {gh:open PRs} {skill:check} {agent:Sol} {script:check.sh} {inbox:Watcher inbox} {repo:Sample} {pc:Laptop}"
        #expect(WatchersSummary.parse(markup).count == 9)
        #expect(WatchersSummary.parse("{unknown:x} {agent} {script:}") == [.word("{unknown:x}"), .word("{agent}"), .word("{script:}")])
        #expect(WatchersSummary.parse("Hello 👋 {repo:日本語}!").last == .chip(kind: "repo", value: "日本語", punctuation: "!"))
    }
    @Test("Server-mismatched chips remain text, valid chips glue a following text token's punctuation")
    func validatedTokens() {
        let tokens: [PiJSONValue] = [.object(["kind": .string("chip"), "chip": .string("time"), "value": .string("every hour")]), .object(["kind": .string("text"), "text": .string(", I use ")]), .object(["kind": .string("text"), "text": .string("missing.sh")])]
        #expect(WatchersSummary.parseTokens(tokens) == [.chip(kind: "time", value: "Every hour", punctuation: ","), .word("I"), .word("use"), .word("missing.sh")])
        #expect(WatchersSummary.accessibilityText([.chip(kind: "slack", value: "#example", punctuation: ".")]) == "Slack channel #example.")
    }
    @Test("Watchers navigation round trips through persisted history")
    func navigation() {
        #expect(HerdrDestinationRecord(.watchers)?.kind == "watchers")
        #expect(HerdrDestinationRecord(kind: "watchers", id: nil).destination == .watchers)
    }
    @Test("Editing a projection removes response metadata without losing definition extensions")
    func losslessDefinition() {
        let watcher = Watcher(["id": .string("wat_a"), "revision": .number(3), "state": .string("draft"), "name": .string("Example"), "summary_tokens": .array([]), "summary_text": .string("Example"), "schedule": .object(["kind": .string("interval"), "every_minutes": .number(15), "summary": .string("every 15 min")]), "source_prompt": .string("Keep an eye on a synthetic file"), "steps": .array([])])
        #expect(watcher.definition["id"] == nil)
        #expect(watcher.definition["summary_tokens"] == nil)
        #expect(watcher.definition["schedule"]?.objectValue?["summary"] == nil)
        #expect(watcher.definition["source_prompt"] == .string("Keep an eye on a synthetic file"))
    }
}

@MainActor @Suite("Watchers fleet")
struct WatchersStoreTests {
    @Test("Working and attention precede schedules; resting and done stay last")
    func ordering() {
        let active = entry("active", next: "2030-01-01T00:05:00Z")
        let sooner = entry("sooner", next: "2030-01-01T00:01:00Z")
        let working = entry("working", live: ["run_id": .string("run_a")])
        let attention = entry("attention", attention: "Failed")
        let paused = entry("paused", state: "paused", next: "2020-01-01T00:00:00Z")
        #expect(WatchersStore.ordered([paused, active, attention, working, sooner]).map(\.watcher.id) == ["working", "attention", "sooner", "active", "paused"])
        #expect(WatchersStore.nextToWake([paused, active, working, sooner])?.watcher.id == "sooner")
    }
    @Test("Duplicate watcher IDs stay scoped to each machine and partial errors remain visible", arguments: [404, 501, 503])
    func hosts(status: Int) async {
        let store = WatchersStore()
        let a = WatchersStub(watchers: [entry("same").watcher.fields])
        let b = WatchersStub(watchers: [entry("same").watcher.fields])
        let offline = WatchersStub(error: APIError.server(status: status, message: "Synthetic unavailable"))
        store.configure([source("a", a), source("b", b), source("c", offline)], identity: 1, demo: false)
        await store.refresh()
        #expect(Set(store.entries.map(\.id)) == ["a:same", "b:same"])
        #expect(store.notices["c"] != nil)
        #expect(store.enabledMachines == ["a", "b"])
    }
    @Test("A late response cannot repopulate a replaced roster")
    func generationGuard() async {
        let gate = WatchersGate(); let old = WatchersStub(watchers: [entry("old").watcher.fields], gate: gate)
        let store = WatchersStore(); store.configure([source("old-host", old)], identity: 1, demo: false)
        let request = Task { await store.refresh() }
        await gate.waitUntilStarted()
        store.configure([], identity: 2, demo: false)
        await gate.release(); await request.value
        #expect(store.entries.isEmpty); #expect(store.enabledMachines.isEmpty)
    }
    @Test("Actions route to the owner and activation carries the person's confirmation")
    func actionOwner() async {
        let a = WatchersStub(); let b = WatchersStub(); let store = WatchersStore()
        store.configure([source("a", a), source("b", b)], identity: 1, demo: false)
        await store.action("activate", entry: entry("wat_a", machine: "b", state: "draft"))
        #expect(await a.mutations.isEmpty)
        let request = await b.mutations.first
        #expect(request?.0 == ["wat_a", "actions"])
        #expect(request?.1["confirmed_by"] == .string("user"))
    }
    private func source(_ id: String, _ client: WatchersStub) -> WatchersSource { .init(machineID: id, machineName: id.uppercased(), client: client) }
    private func entry(_ id: String, machine: String = "a", state: String = "active", next: String? = nil, live: [String: PiJSONValue]? = nil, attention: String? = nil) -> WatcherEntry {
        var value: [String: PiJSONValue] = ["id": .string(id), "name": .string(id), "state": .string(state)]
        if let next { value["next_fire_at"] = .string(next) }; if let live { value["live"] = .object(live) }; if let attention { value["attention"] = .object(["reason": .string(attention)]) }
        return .init(machineID: machine, machineName: machine, watcher: Watcher(value))
    }
}
private actor WatchersGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var start: CheckedContinuation<Void, Never>?
    private var started = false
    func wait() async { started = true; start?.resume(); start = nil; await withCheckedContinuation { pending = $0 } }
    func waitUntilStarted() async { if started { return }; await withCheckedContinuation { start = $0 } }
    func release() { pending?.resume(); pending = nil }
}
private actor WatchersStub: WatchersClient {
    let watchers: [[String: PiJSONValue]]
    let error: APIError?
    let gate: WatchersGate?
    var mutations: [([String], [String: PiJSONValue])] = []
    init(watchers: [[String: PiJSONValue]] = [], error: APIError? = nil, gate: WatchersGate? = nil) { self.watchers = watchers; self.error = error; self.gate = gate }
    func watchersRequest(_ path: [String], method: String, body: [String: PiJSONValue]?, query: [URLQueryItem]) async throws -> [String: PiJSONValue] {
        if let error { throw error }
        if path == ["schedule", "preview"] { return ["next": .array(["2030-01-02T15:00:00Z", "2030-01-03T15:00:00Z", "2030-01-04T15:00:00Z"].map(PiJSONValue.string))] }
        if method != "GET" { mutations.append((path, body ?? [:])); return ["ok": .bool(true)] }
        if path == ["capabilities"] { return ["enabled": .bool(true)] }
        if path.isEmpty { if let gate { await gate.wait() }; return ["watchers": .array(watchers.map(PiJSONValue.object))] }
        return ["items": .array([])]
    }
}

@Suite("Watchers client contract", .serialized)
struct WatchersClientTests {
    @Test("All routes retain the auth prefix, exact methods, query encoding and request receipts")
    func routes() async throws {
        let config = try #require(ServerConfiguration(urlString: "https://example.invalid/prefix", token: "synthetic-token"))
        let urlConfig = URLSessionConfiguration.ephemeral; urlConfig.protocolClasses = [WatchersURLProtocol.self]
        let client = HerdrAPIClient(configuration: config, session: URLSession(configuration: urlConfig))
        let routes: [([String], String)] = [([], "GET"), (["capabilities"], "GET"), (["wat_a"], "GET"), ([], "POST"), (["wat_a"], "PATCH"), (["wat_a", "scripts", "check"], "PUT"), (["wat_a", "actions"], "POST"), (["wat_a", "runs"], "GET"), (["runs", "run_a"], "GET"), (["runs", "run_a", "logs"], "GET"), (["runs", "run_a", "stop"], "POST"), (["inbox"], "GET"), (["inbox", "item_a", "read"], "POST"), (["schedule", "preview"], "POST"), (["builder", "sessions"], "POST"), (["builder", "sessions", "wb_a", "messages"], "POST"), (["builder", "sessions", "wb_a"], "GET")]
        for (path, method) in routes {
            WatchersURLProtocol.requests.withLock { $0.removeAll() }
            _ = try await client.watchersRequest(path, method: method, body: method == "GET" ? nil : ["request_id": .string("synthetic-request")], query: method == "GET" ? [.init(name: "step", value: "a+b")] : [])
            let request = try #require(WatchersURLProtocol.requests.withLock { $0.first })
            #expect(request.httpMethod == method)
            let suffix = path.isEmpty ? "" : "/" + path.joined(separator: "/")
            let expectedPath = "/prefix/api/v1/watchers" + suffix
            #expect(request.url?.path == expectedPath)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
            if method == "GET" { #expect(request.url?.absoluteString.contains("a%2Bb") == true) }
        }
    }
    @Test("Opaque path components cannot escape the Watchers namespace")
    func pathRejection() async throws {
        let config = try #require(ServerConfiguration(urlString: "https://example.invalid", token: "synthetic-token"))
        let client = HerdrAPIClient(configuration: config)
        for value in ["..", "a/b", "%2e%2e", "", "a?x=1"] { await #expect(throws: APIError.self) { _ = try await client.watchersGet([value]) } }
    }
    @Test("Named Watchers events retain their payload")
    func sse() {
        var parser = HerdrSSEParser(); _ = parser.consume(line: "event: watchers.inbox")
        let event = parser.consume(line: #"data: {"item":{"id":"item_a","title":"Ready"}}"#)
        #expect(event?.event == "watchers.inbox")
        #expect(event?.data != .null)
    }
}
private final class WatchersURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Suite("Watchers rendering", .serialized)
struct WatchersRenderTests {
    @Test("Grid wraps at the approved three, two and one column breakpoints", arguments: [CGFloat(1240), 850, 600])
    func grid(width: CGFloat) async throws {
        let store = WatchersStore(); store.configure([], identity: "demo", demo: true)
        let result = try await HerdrRenderHarness.render("watchers-grid-\(Int(width)).png", size: CGSize(width: width, height: 1000)) { ZStack { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true); WatchersView(store: store) }.environment(\.herdrGlassActive, true) }
        result.expectSubstantial()
        #expect(WatchersView.columnCount(width: width) == (width == 1240 ? 3 : width == 850 ? 2 : 1))
    }
    @Test("Builder draft renders smart chips, pipeline, and human activation")
    func builder() async throws {
        let store = WatchersStore()
        store.configure([.init(machineID: "preview-machine", machineName: "Workstation", client: WatchersStub())], identity: "builder-preview", demo: false)
        await store.refresh()
        var draft = WatchersDemo.entries[1].watcher.fields; draft["state"] = .string("draft")
        let snapshot: [String: PiJSONValue] = ["draft": .object(draft), "messages": .array([.object(["role": .string("user"), "text": .string("Keep an eye on pull requests that need my review.")]), .object(["role": .string("assistant"), "text": .string("Here's the draft. {time}, I check {gh:open PRs}. Review the steps before creating your watcher.")])])]
        let result = try await HerdrRenderHarness.render("watchers-builder.png", size: CGSize(width: 1080, height: 740)) {
            ZStack { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true); WatcherBuilderSheet(store: store, entry: nil, initialSnapshot: snapshot) }.environment(\.herdrGlassActive, true)
        }
        result.expectSubstantial()
    }
    @Test("Every card state and chip punctuation render without placeholder avatars")
    func states() async throws {
        let states = ["draft", "active", "paused", "done", "working", "attention"]
        let result = try await HerdrRenderHarness.render("watchers-card-states.png", size: CGSize(width: 1200, height: 1020)) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                ForEach(states, id: \.self) { state in
                    let sample = WatchersDemo.entries[1]
                    var fields = sample.watcher.fields
                    let _ = { fields["state"] = .string(state == "working" || state == "attention" ? "active" : state); if state == "working" { fields["live"] = .object(["step_index": .number(1), "step_count": .number(4), "step_title": .string("Checking what changed")]) }; if state == "attention" { fields["attention"] = .object(["reason": .string("A synthetic run needs attention")]) } }()
                    WatcherCard(entry: .init(machineID: sample.machineID, machineName: sample.machineName, watcher: Watcher(fields)))
                }
            }.padding(20)
        }
        result.expectSubstantial()
        for avatar in WatcherAvatar.characters + WatcherAvatar.instruments { #expect(NSImage(named: "Watcher-\(avatar)-idle") != nil) }
    }
}
