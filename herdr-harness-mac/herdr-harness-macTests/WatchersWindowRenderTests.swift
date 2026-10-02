import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Whole-window renders of Watchers over the dusk backdrop, for comparison
/// with the approved prototype (`avatars-v1-chips.html`, "Dusk glass"). The
/// fixture is the prototype's twelve synthetic watchers in the companion's
/// list payload shape, served by a stub client so the store runs its real
/// refresh path.
@Suite("Watchers window renders", .serialized)
@MainActor
struct WatchersWindowRenderTests {
    @Test("Grid at the prototype's 1440×900 frame")
    func grid() async throws {
        let result = try await render("watchers-window-1440.png", size: CGSize(width: 1440, height: 900))
        result.expectSubstantial()
    }

    @Test("Grid at the Mono study's 1280×800 frame")
    func compact() async throws {
        let result = try await render("watchers-window-1280.png", size: CGSize(width: 1280, height: 800))
        result.expectSubstantial()
    }

    @Test("Every card, a working run, attention and the resting section", arguments: [CGFloat(1190), 1520, 880, 600])
    func everyCard(width: CGFloat) async throws {
        let store = try await Self.store(working: true)
        let height: CGFloat = width < 650 ? 6_400 : width < 950 ? 3_400 : 2_400
        let result = try await HerdrRenderHarness.render("watchers-all-\(Int(width)).png", size: CGSize(width: width, height: height)) {
            ZStack { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true); WatchersView(store: store) }.environment(\.herdrGlassActive, true)
        }
        result.expectSubstantial()
    }

    private static func store(working: Bool) async throws -> WatchersStore {
        let store = WatchersStore()
        store.configure(["Desktop", "Laptop"].map { WatchersSource(machineID: $0.lowercased(), machineName: $0, client: WatchersRenderClient(machine: $0, working: working)) }, identity: UUID(), demo: false)
        await store.refresh()
        #expect(store.entries.count == 12)
        return store
    }

    private func render(_ name: String, size: CGSize, working: Bool = false) async throws -> HerdrRenderHarness.RenderResult {
        let store = try await Self.store(working: working)
        let model = HerdrRenderFixtures.demoModel()
        let shell = MonoRenderFixtures.shell(sidebarOnHome: true)
        shell.show(.watchers, model: model)
        return try await HerdrRenderHarness.renderWindow(name, size: size) {
            MonoRenderFixtures.window(model: model, shell: shell, detail: AnyView(WatchersView(store: store)))
        }
    }
}

/// Synthetic companion: capabilities, the list and an empty inbox.
private struct WatchersRenderClient: WatchersClient {
    var machine: String
    var working = false

    func watchersRequest(_ path: [String], method: String, body: [String: PiJSONValue]?, query: [URLQueryItem]) async throws -> [String: PiJSONValue] {
        switch path.first {
        case "capabilities": ["ok": .bool(true), "enabled": .bool(true)]
        case "inbox": ["ok": .bool(true), "unread_count": .number(0), "items": .array([])]
        default: ["ok": .bool(true), "watchers": .array(WatchersRenderFixture.watchers(machine: machine, working: working).map(PiJSONValue.object))]
        }
    }
}

enum WatchersRenderFixture {
    private typealias Step = [String: PiJSONValue]
    private static func script(_ id: String, _ title: String, _ file: String) -> Step { ["id": .string(id), "kind": .string("script"), "title": .string(title), "file": .string(file)] }
    private static func gate(_ id: String, _ title: String) -> Step { ["id": .string(id), "kind": .string("gate"), "title": .string(title)] }
    private static func agent(_ name: String, _ skill: String, _ title: String) -> Step { ["id": .string(skill), "kind": .string("agent"), "display_name": .string(name), "skill": .string(skill), "title": .string(title)] }
    private static func deliver(_ title: String) -> Step { ["id": .string("deliver"), "kind": .string("deliver"), "title": .string(title)] }

    /// The prototype's `seed()`, with schedule phrases from the companion's `schedule_summary`.
    private static let seed: [(name: String, avatar: String, machine: String, schedule: String, once: Bool, minutes: Int?, runs: Int, summary: String, steps: [Step])] = [
        ("PR radar", "hoot", "Desktop", "every 15 min", false, 8, 5, "{time}, I look for {gh:open PRs that request your review}. When one is new or updated, {agent:Sol} runs {skill:pr-review-triage} and I post the results to {slack:#agentic-monitoring}.",
         [script("find", "Find PRs that request your review", "find-review-requests.sh"), gate("gate", "Continue only when a PR is new or updated"), agent("Sol", "pr-review-triage", "Triage what changed"), deliver("Post to #agentic-monitoring")]),
        ("Morning briefing", "lumen", "Desktop", "weekdays at 7:00 AM", false, 1_330, 2, "{time}, {agent:Astra} runs {skill:morning-brief} over overnight builds, open PRs, and today’s calendar. I post a short briefing to {slack:#team-digest}.",
         [agent("Astra", "morning-brief", "Write the briefing"), deliver("Post to #team-digest")]),
        ("Repository pulse", "gauge", "Desktop", "every 2 hours", false, 113, 3, "{time}, {script:repo-pulse.sh} checks builds and stale PRs in {repo:Companion}. I only ping {inbox:your Watcher inbox} when something is red.",
         [script("pulse", "Check builds and stale PRs", "repo-pulse.sh"), gate("gate", "Continue only when a check fails"), deliver("Save to your Watcher inbox")]),
        ("Keep the docs honest", "quill", "Laptop", "weekdays at 9:30 AM", false, 38, 1, "{time}, {script:merged-today.sh} lists merged changes, then {agent:Sol} runs {skill:docs-check} against {repo:Documentation}. I leave a checklist in {inbox:your Watcher inbox}.",
         [script("merged", "List changes merged since yesterday", "merged-today.sh"), agent("Sol", "docs-check", "Find pages that drifted"), deliver("Save to your Watcher inbox")]),
        ("Release readiness", "atlas", "Desktop", "Thursday at 12:00 PM", true, 3_000, 0, "Just once, {time}, {agent:Astra} runs {skill:release-check} on the candidate build and open blockers. I post a readiness summary to {slack:#releases}. Nothing gets published.",
         [agent("Astra", "release-check", "Check the candidate"), deliver("Post to #releases")]),
        ("CI flake watch", "tally", "Laptop", "every 30 min, weekdays 8 AM–6 PM", false, 8, 2, "{time}, {script:failed-runs.sh} collects failed CI runs. If there are new ones, {agent:Luna} runs {skill:ci-triage} and I post likely flakes to {slack:#ci-health}.",
         [script("failed", "Collect failed CI runs", "failed-runs.sh"), gate("gate", "Continue only when there are new failures"), agent("Luna", "ci-triage", "Separate flakes from real failures"), deliver("Post to #ci-health")]),
        ("End-of-day handoff", "juno", "Desktop", "weekdays at 6:00 PM", false, 540, 1, "{time}, {agent:Luna} runs {skill:daily-handoff} to sum up what got done and where to pick up tomorrow. It lands in {inbox:your Watcher inbox}.",
         [agent("Luna", "daily-handoff", "Write the handoff"), deliver("Save to your Watcher inbox")]),
        ("Simulator cleanup", "cog", "Laptop", "every night at 2:00 AM", false, 1_020, 2, "{time}, {script:prune-simulators.sh} removes simulators you haven’t opened in 30 days and stale build caches on {pc:Laptop}. I note the space it freed in {inbox:your Watcher inbox}.",
         [script("prune", "Remove unused simulators and caches", "prune-simulators.sh"), deliver("Save to your Watcher inbox")]),
        ("Backup check", "hourglass", "Desktop", "every night at 3:30 AM", false, 1_110, 1, "{time}, {script:check-backup.sh} makes sure the latest backup is less than a day old. I only speak up in {slack:#ops-alerts} if it isn’t.",
         [script("backup", "Check the latest backup", "check-backup.sh"), gate("gate", "Continue only when the backup is stale"), deliver("Post to #ops-alerts")]),
        ("Dependency check", "sprout", "Desktop", "Mondays at 10:00 AM", false, 5_800, 1, "{time}, {agent:Sol} runs {skill:dependency-review} on {repo:Companion} and opens a draft PR for safe updates. You’ll find it in {inbox:your Watcher inbox}.",
         [agent("Sol", "dependency-review", "Review available updates"), deliver("Save to your Watcher inbox")]),
        ("Weekly project digest", "kit", "Laptop", "Fridays at 4:00 PM", false, nil, 1, "{time}, {agent:Astra} runs {skill:project-digest} and posts outcomes, blockers, and next steps to {slack:#project-updates}.",
         [agent("Astra", "project-digest", "Write the digest"), deliver("Post to #project-updates")]),
        ("Certificate expiry", "beacon", "Desktop", "Sundays at 8:00 AM", false, nil, 1, "{time}, {script:cert-expiry.sh} checks signing certificates and profiles. If anything expires within 30 days, I post to {slack:#ios-release}.",
         [script("certs", "Check certificates and profiles", "cert-expiry.sh"), gate("gate", "Continue only when something expires soon"), deliver("Post to #ios-release")]),
    ]

    static func watchers(machine: String? = nil, working: Bool = false, now: Date = .now) -> [[String: PiJSONValue]] {
        seed.enumerated().filter { machine == nil || $0.element.machine == machine }.map { index, item in
            var value: [String: PiJSONValue] = [
                "id": .string("render-\(index)"), "name": .string(item.name), "avatar": .string(item.avatar), "summary": .string(item.summary),
                "summary_tokens": .array(tokens(item.summary, schedule: item.schedule)), "state": .string(item.minutes == nil ? "paused" : "active"),
                "revision": .number(1), "timezone": .string("America/Chicago"), "runs_count": .number(Double(item.runs)),
                "schedule": .object(["kind": .string(item.once ? "once" : "daily"), "summary": .string(item.schedule)]),
                "steps": .array(item.steps.map(PiJSONValue.object)), "live": .null, "attention": .null,
            ]
            if let minutes = item.minutes { value["next_fire_at"] = .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(minutes * 60) - 30))) }
            if item.name == "CI flake watch" { value["attention"] = .object(["reason": .string("ci-triage isn’t installed on Laptop.")]) }
            if working, item.name == "Keep the docs honest" {
                value["live"] = .object(["run_id": .string("run-render"), "step_index": .number(1), "step_count": .number(3), "step_id": .string("docs-check"), "step_title": .string("Find pages that drifted"), "started_at": .string(ISO8601DateFormatter().string(from: now))])
            }
            return value
        }
    }

    /// Mirrors the companion's `summary_tokens`: text runs and chips, `{time}` filled and capitalized at a sentence start.
    private static func tokens(_ summary: String, schedule: String) -> [PiJSONValue] {
        let expression = try! NSRegularExpression(pattern: #"\{([a-z]+)(?::([^{}]*))?\}"#)
        let source = summary as NSString
        var result: [PiJSONValue] = []; var last = 0
        for match in expression.matches(in: summary, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > last { result.append(.object(["kind": .string("text"), "text": .string(source.substring(with: NSRange(location: last, length: match.range.location - last)))])) }
            let kind = source.substring(with: match.range(at: 1))
            var value = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
            if kind == "time" {
                let before = source.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                value = before.isEmpty || before.hasSuffix(".") ? schedule.prefix(1).uppercased() + schedule.dropFirst() : schedule
            }
            result.append(.object(["kind": .string("chip"), "chip": .string(kind), "value": .string(value)]))
            last = NSMaxRange(match.range)
        }
        if last < source.length { result.append(.object(["kind": .string("text"), "text": .string(source.substring(from: last))])) }
        return result
    }
}
