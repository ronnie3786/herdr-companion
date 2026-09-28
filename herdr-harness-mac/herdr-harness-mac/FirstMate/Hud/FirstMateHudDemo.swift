import Foundation

/// The HUD's demo fleet: the chat window's demo host, resized with
/// `-HerdrFirstMateHudDemoCount` to 6, 10, or 14 features for visual checks.
/// Every name and message is made up.
enum FirstMateHudDemo {
    private struct Extra {
        let id: String
        let title: String
        let emoji: String
        let status: String
        let hud: FirstMateHudStatus
        let step: Int?
        let fraction: Double
        let now: String
        let message: String?
    }

    /// Features added past the chat demo's own, all with multi-word names.
    private static let extras: [Extra] = [
        Extra(id: "demo-hud-tokens", title: "Theme tokens cleanup", emoji: "🎨", status: "running", hud: .working, step: 1, fraction: 0.5,
              now: "Moving the last hard-coded colors onto tokens.", message: nil),
        Extra(id: "demo-hud-locale", title: "Localization pass", emoji: "🌱", status: "running", hud: .working, step: 3, fraction: 0.3,
              now: "QA is checking German strings for truncation.", message: nil),
        Extra(id: "demo-hud-a11y", title: "Accessibility audit", emoji: "🔔", status: "awaiting_direction", hud: .turn, step: 2, fraction: 0,
              now: "Should the audit cover the widget gallery too?", message: "Should the audit cover the widget gallery too, or only the main app?"),
        Extra(id: "demo-hud-onboarding", title: "Onboarding checklist", emoji: "📚", status: "coordinating", hud: .working, step: 2, fraction: 0.6,
              now: "Two reviewers are reading the new first-run flow.", message: nil),
        Extra(id: "demo-hud-crash", title: "Crash report triage", emoji: "🔧", status: "ready", hud: .idle, step: 0, fraction: 0,
              now: "Ready to plan.", message: nil),
        Extra(id: "demo-hud-email", title: "Billing email refresh", emoji: "💡", status: "running", hud: .working, step: 4, fraction: 0.2,
              now: "Opening the pull request.", message: nil),
        Extra(id: "demo-hud-shortcuts", title: "Keyboard shortcuts sheet", emoji: "🧰", status: "running", hud: .working, step: 1, fraction: 0.8,
              now: "Building the sheet's search field.", message: nil),
        Extra(id: "demo-hud-export", title: "Calendar export", emoji: "🪁", status: "running", hud: .working, step: 3, fraction: 0.7,
              now: "Proof is checking the exported file in two calendar apps.", message: nil),
    ]

    /// The demo host with `count` features: the chat demo's first ones in
    /// HUD order, or all of them plus made-up extras.
    static func host(base: FirstMateFleetHost, count: Int?, now: Date) -> FirstMateFleetHost {
        guard let count else { return base }
        var host = base
        var entries = base.fleetEntries ?? [:]
        // What the HUD shows, which leaves out the demo's long-merged feature.
        let shown = FirstMateHudRoster.items(hosts: [base], readState: FirstMateReadState(), now: now)
        let baseCount = shown.count
        if count < baseCount {
            let keep = Set(shown.prefix(count).map(\.id.featureID))
            entries = entries.filter { keep.contains($0.key) }
            host.features = base.features.filter { keep.contains($0.id) }
        } else {
            for (index, extra) in extras.prefix(max(0, count - baseCount)).enumerated() {
                let at = HerdrTimestamp.string(from: now.addingTimeInterval(-Double(index + 1) * 900))
                let message = extra.message.map {
                    FirstMateFleetLatestMessage(id: "\(extra.id)-message-1", role: "assistant", text: $0, createdAt: at)
                }
                entries[extra.id] = FirstMateFleetEntry(
                    featureID: extra.id, title: extra.title, emoji: extra.emoji, emojiSource: "user",
                    status: extra.status, hudStatus: extra.hud, stepIndex: extra.step, stepFraction: extra.fraction,
                    percent: FirstMateHudProgress.percent(status: extra.hud, step: extra.step, fraction: extra.fraction),
                    now: extra.now, latestMessage: message, latestFirstMateMessageID: message?.id,
                    unread: message != nil, activityAt: at, updatedAt: at
                )
            }
        }
        host.fleetEntries = entries
        return host
    }
}
