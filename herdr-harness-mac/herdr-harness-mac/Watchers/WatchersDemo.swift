import Foundation

@MainActor enum WatchersDemo {
    static let entries: [WatcherEntry] = {
        let examples: [(String, String, String)] = [
            ("CI flake watch", "tally", "{time}, {script:failed-runs.sh} collects failed CI runs. If there are new ones, {agent:Luna} runs {skill:ci-triage} and I post likely flakes to {slack:#ci-health}."),
            ("PR radar", "hoot", "{time}, I look for {gh:open PRs that request your review}. When one is new or updated, {agent:Sol} runs {skill:pr-review-triage} and I post results to {inbox:your Watcher inbox}."),
            ("Keep the docs honest", "quill", "{time}, {script:merged-today.sh} lists merged changes, then {agent:Sol} runs {skill:docs-check} against {repo:Documentation}. I leave a checklist in {inbox:your Watcher inbox}."),
            ("Repository pulse", "gauge", "{time}, {script:repo-pulse.sh} checks builds and stale PRs in {repo:Companion}. I only ping you when something changes."),
            ("Release readiness", "atlas", "Just once, {time}, {agent:Astra} runs {skill:release-check} on the candidate build and open issues."),
            ("End-of-day handoff", "juno", "{time}, {agent:Luna} runs {skill:daily-handoff} to sum up what got done and where to pick up tomorrow."),
            ("Clean build cache", "cog", "{time}, I run {script:clean-cache.sh} on {pc:Desktop}."),
            ("Service heartbeat", "beacon", "{time}, I check service health and leave changes in {inbox:your Watcher inbox}."),
            ("Nightly snapshot", "terminal", "{time}, I run {script:snapshot.sh} and keep the result in {inbox:your Watcher inbox}."),
            ("Weekly reading", "pip", "{time}, {agent:Sol} collects a short reading list from {repo:Research}."),
            ("Dependency check", "relay", "{time}, {script:dependencies.sh} checks {gh:dependency updates}."),
            ("Workspace tidy", "valve", "{time}, I run {script:tidy.sh} on {pc:Laptop}.")
        ]
        return examples.enumerated().map { index, example in
            let agent = WatcherAvatar.characters.contains(example.1)
            var value: [String: PiJSONValue] = ["id": .string("demo-\(index)"), "name": .string(example.0), "avatar": .string(example.1), "summary": .string(example.2), "state": .string(index > 9 ? "paused" : "active"), "revision": .number(1), "timezone": .string("Etc/UTC"), "schedule": .object(["kind": .string(index == 4 ? "once" : "interval"), "every_minutes": .number(15), "summary": .string(index == 2 ? "weekdays at 9:30 AM" : "every 15 min")]), "runs_count": .number(Double(index + 1)), "steps": .array([.object(["id": .string("check"), "title": .string("Check for changes"), "kind": .string(agent ? "agent" : "script"), "display_name": .string("Sol"), "file": .string("check.sh")])])]
            if index < 10 { value["next_fire_at"] = .string(ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(Double(index + 1) * 480))) }
            if index == 0 { value["attention"] = .object(["reason": .string("The last check could not finish.")]) }
            return WatcherEntry(machineID: "demo", machineName: index % 3 == 0 ? "Laptop" : "Desktop", watcher: Watcher(value))
        }
    }()
}
