import Foundation

/// Entirely synthetic snapshots. No captured sessions, configuration, or network access.
enum HomeFixtures {
    enum Moment: String, CaseIterable, Sendable {
        case morning, afternoon, clear, trouble, loading, disconnected, stale
    }

    static var requestedMoment: Moment? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-HerdrDemoMode"),
              let index = arguments.firstIndex(of: "-HerdrHomeMoment"),
              index + 1 < arguments.count else { return nil }
        return Moment(rawValue: arguments[index + 1])
    }

    static func snapshot(_ moment: Moment) -> HomeSnapshot {
        var value = morning
        switch moment {
        case .morning: break
        case .afternoon:
            value.mood = .calm
            value.greeting = "Good afternoon."
            value.dateLine = "Friday, October 2 · 1:42 PM · Last here 25 minutes ago"
            value.summary = [rich([.text("You’re in a good rhythm. Since this morning "), .chip(docs),
                                   .text(" got unstuck and opened its PR, and you approved "), .chip(review88), .text(".")]),
                             "Just one question is waiting on you."]
            value.focus = [focus("retry-question", title: "Retry-After support", reason: "Your call",
                                 body: "Retry-After works for 429s and 503s now. How many retries before giving up: 3 or 5?",
                                 emoji: "⏳", tone: .attention, route: retry.route)]
            value.focusTitle = "Waiting on you"
            value.chatsTitle = "Worth a look"
            value.chats = [chat("index", title: "Ledger index", reason: "Finished 5 min ago", location: "ledger on Dev",
                                quote: "Rebuilt the ledger index. Queries are faster. The summary is in the chat.", waiting: false)]
            value.radar = [HomeRadarItem(id: "ci", body: rich([.chip(ci), .text(" found 2 new failures. Both are in the snapshot files "),
                                                            .chip(snap), .text(" is already fixing.")]),
                                        watcherAvatar: "tally", tone: .brandBlue,
                                        actions: [open("Show me", route: ci.route), HomeAction(id: "dismiss", title: "Thanks", command: .dismiss("ci"))]),
                           HomeRadarItem(id: "merged", body: rich([.chip(review88), .text(" merged a few minutes ago. The review is complete.")]),
                                         symbol: "checkmark.circle", tone: .signal)]
            value.recapTitle = "Since this morning"
            value.recap = recap([("9:06 AM", "checkmark", "Docs search continued QA."),
                                 ("9:08 AM", "checkmark", "Passkey sign-in resumed building."),
                                 ("10:05 AM", "checkmark", "The Ledger CSV export review was approved."),
                                 ("1:20 PM", "checkmark.circle", "Ledger CSV export merged.")])
            value.suggestions = ["What changed since this morning?", "Anything to check before the deploy?", "Start something new"]
            value.reviewCount = 1
            value.watcherNeedsAttention = false
        case .clear:
            value.mood = .happy
            value.greeting = "Good evening."
            value.dateLine = "Friday, October 2 · 6:10 PM · Last here an hour ago"
            value.summary = [rich([.text("You’re all caught up. "), .chip(retry), .text(", "), .chip(passkey),
                                   .text(" and "), .chip(cache), .text(" are working on their own.")]),
                             "If you have a few minutes before the weekend, here are some ideas."]
            value.focusTitle = "If you have a minute"
            value.focus = [focus("plan", title: "Plan Deep link router", reason: "Ready since yesterday",
                                 body: "The project is ready to plan. Open its conversation to decide the next step.",
                                 emoji: "🧭", tone: .accent, route: deepLink.route, idea: true),
                           focus("release-notes", title: "Release notes for 4.12", reason: "Watcher paused",
                                 body: "The release notes watcher is paused. You can review its schedule and settings.",
                                 emoji: nil, tone: .accent, route: .watcher(machineID: "fixture-dev", watcherID: "notes"), idea: true)]
            value.radar = [HomeRadarItem(id: "good-week", body: rich([.text("A good finish to the week. "), .chip(csv),
                                                                    .text(" and "), .chip(docs), .text(" both merged today.")]),
                                        symbol: "sparkles", tone: .signal)]
            value.chatsTitle = "Pick up where you left off"
            value.chats = [chat("copy", title: "Onboarding copy", reason: "You stopped mid-draft · 3h", location: "lumen on Work",
                                quote: "Screen 2 of 5 done. Next: the permissions screen.", waiting: false)]
            value.recapTitle = "Today"
            value.recap = recap([("10:05 AM", "checkmark", "Ledger CSV export was approved."),
                                 ("1:20 PM", "checkmark.circle", "Ledger CSV export merged."),
                                 ("3:00 PM", "shippingbox", "Lumen 4.12.0 was released."),
                                 ("4:45 PM", "checkmark.circle", "Docs search merged."),
                                 ("5:30 PM", "checkmark.circle", "Snapshot test flakes merged.")])
            value.suggestions = ["Wrap up my week", "What runs over the weekend?", "Start something new"]
            value.reviewCount = 0
            value.watcherNeedsAttention = false
        case .trouble:
            value.mood = .concerned
            value.greeting = "Heads up."
            value.dateLine = "Friday, October 2 · 8:40 PM · Last here 2 hours ago"
            value.summary = [rich([.text("Two machines need you before anything else. "), .chip(studio),
                                   .text(" went offline 25 minutes ago, and "), .chip(dev), .text(" reported a storage problem.")]),
                             "The latest known work is below. Check the affected machines before continuing."]
            value.focusTitle = "Fix these first"
            value.focus = [HomeFocusItem(id: "dev-storage", title: "Check storage on Dev", reason: "Storage problem",
                                        body: rich([.chip(csv), .text(" reported that it cannot save progress. Open the machine’s cleanup tools to inspect available space.")]),
                                        symbol: "internaldrive", tone: .alert,
                                        actions: [open("Open machine", route: dev.route, primary: true)], route: dev.route),
                           focus("studio-offline", title: "Studio is offline", reason: "Last seen 25m ago",
                                 body: "Image cache was mid-review there. Its last known state is preserved while the machine is unreachable.",
                                 emoji: nil, tone: .alert, route: studio.route), morning.focus[1]]
            value.radar = [HomeRadarItem(id: "crash", body: rich([.chip(crash), .text(" failed twice because its GitHub token expired. Open the watcher to reconnect it.")]),
                                        watcherAvatar: "beacon", tone: .alert,
                                        actions: [open("Open watcher", route: crash.route)]),
                           HomeRadarItem(id: "review-failed", body: "A review could not check out its branch on Dev. Inspect the preparation error before retrying.",
                                         symbol: "arrow.triangle.pull", tone: .brandBlue,
                                         actions: [open("Show review", route: .review(machineID: "fixture-dev", reviewID: "r311"))])]
            value.moving = rich([.chip(retry), .text(" is building on Work, and "), .chip(docs), .text(" has its PR open.")])
            value.recapTitle = "In the last hour"
            value.recap = recap([("8:12 PM", "checkmark", "Image cache saved a checkpoint on Studio."),
                                 ("8:15 PM", "exclamationmark.triangle", "Studio stopped responding."),
                                 ("8:31 PM", "internaldrive", "Dev reported a storage problem."),
                                 ("8:33 PM", "exclamationmark.triangle", "Review preparation failed on Dev."),
                                 ("8:36 PM", "eye", "Crash watch reported its second failure.")])
            value.suggestions = ["What happened?", "Is anything lost?", "Fix what you can"]
            value.reviewNeedsAttention = true
        case .loading:
            value = HomeSnapshot()
            value.mood = .thinking
            value.greeting = "Welcome home."
            value.dateLine = "Friday, October 2 · 9:04 AM"
            value.summary = ["I’m checking your connected machines for current work."]
            value.isLoading = true
            value.firstMateStatus = "Connecting"
        case .disconnected:
            value = HomeSnapshot()
            value.mood = .concerned
            value.greeting = "Let’s reconnect."
            value.dateLine = "Friday, October 2 · 9:04 AM"
            value.statusLine = "Your machines are currently unreachable."
            value.firstMateStatus = "Connection unavailable"
            value.summary = ["I can’t check your work while the configured machines are unreachable. Open a machine to inspect its connection."]
            value.focus = [focus("disconnected", title: "Dev is unreachable", reason: "Connection unavailable",
                                 body: "Check that its companion is running and the machine is connected.",
                                 emoji: nil, tone: .alert, route: dev.route)]
            value.notices = ["Current work may be missing. This is not a complete snapshot."]
        case .stale:
            value.mood = .concerned
            value.greeting = "Here’s the last update."
            value.summary = ["Some machines haven’t refreshed yet. The last usable work is still here, with its original owners."]
            value.notices = ["Dev is unreachable. Its items show the last known state from 8:42 AM."]
            value.focus = value.focus.map { item in var stale = item; stale.isStale = true; return stale }
            value.chats = value.chats.map { item in var stale = item; stale.isStale = true; return stale }
        }
        value.focusCount = value.focus.filter { !$0.isIdea }.count
        value.waitingChatCount = value.chats.filter(\.isWaiting).count
        value.availability = switch moment {
        case .loading: .loading
        case .disconnected: .disconnected
        case .stale: .stale
        default: .current
        }
        value.canShowAllClear = moment == .clear
        value.coverageLine = moment == .stale ? "Partial coverage · last usable results retained" : ""
        return value
    }

    private static var morning: HomeSnapshot {
        var value = HomeSnapshot()
        value.mood = .attentive
        value.greeting = "Good morning."
        value.dateLine = "Friday, October 2 · 9:04 AM · You were away 13 hours"
        value.statusLine = "Keeping an eye on 7 First Mates, 8 watchers and 3 machines."
        value.firstMateStatus = "3 working · 3 need you"
        value.summary = [rich([.text("Mostly a quiet night. "), .chip(csv), .text(" finished and its PR is green, and "),
                               .chip(snap), .text(" is down to three stubborn tests.")]),
                         "Two things got stuck while you were away, so they’re first."]
        value.moving = rich([.chip(retry), .text(" is building, "), .chip(snap), .text(" is in QA and "), .chip(cache),
                             .text(" is in review. "), .chip(deepLink), .text(" is ready to plan whenever you are.")])
        value.focus = [focus("docs", title: "Docs search", reason: "Blocked since 2:14 AM",
                             body: "Staging rejected the new search schema. It needs the staging admin token to retry the migration, then it can finish QA.",
                             emoji: "📚", tone: .alert, route: docs.route),
                       focus("passkey", title: "Passkey sign-in", reason: "Your call",
                             body: "About 8% of sign-ins come from devices that can’t create passkeys. Give them a magic-link fallback, or keep passwords for now?",
                             emoji: "🔑", tone: .attention, route: passkey.route),
                       focus("review88", title: "Review PR #88 · Ledger CSV export", reason: "Ready for review",
                             body: "9 files and CI passed. Open the walkthrough to review the streaming writer.",
                             emoji: nil, tone: .signal, route: review88.route),
                       focus("review1284", title: "#1284 Update request signing", reason: "Requested by mk",
                             body: "The walkthrough is ready, with 5 chapters and 2 draft comments.",
                             emoji: nil, tone: .attention, route: .review(machineID: "fixture-work", reviewID: "r1284")),
                       focus("request1291", title: "#1291 Rotate webhook signing keys", reason: "Requested 40 min ago",
                             body: "No walkthrough yet. Open PR Review to choose a machine and prepare it.",
                             emoji: nil, tone: .attention, route: .reviewRequest(url: "https://github.com/example/fixture/pull/1291"))]
        value.radar = [HomeRadarItem(id: "crash", body: rich([.chip(crash), .text(" is out. Its GitHub token expired at 3:02 AM, so it’s missed 6 runs. Open it to reconnect.")]),
                                    watcherAvatar: "beacon", tone: .alert,
                                    actions: [open("Open watcher", route: crash.route), HomeAction(id: "dismiss", title: "Dismiss", command: .dismiss("crash"))]),
                       HomeRadarItem(id: "storage", body: rich([.chip(dev), .text(" reported low storage. Open its cleanup tools to review what can be removed.")]),
                                     symbol: "internaldrive", tone: .attention, actions: [open("Show me", route: dev.route)])]
        value.chats = [chat("snap", title: "Snapshot test flakes", reason: "Waiting on you · 12m", location: "lumen-ios on Work",
                            quote: "Quarantine the 3 flaky tests, or keep retrying them?"),
                       chat("webhook", title: "Webhook key rotation", reason: "Asking permission · 40m", location: "ledger on Dev",
                            quote: "May I run the key rotation script against staging?")]
        value.recap = recap([("1:20 AM", "arrow.triangle.pull", "Ledger CSV export opened PR #88. CI passed."),
                             ("2:00 AM", "eye", "Simulator cleanup deleted 3 idle simulators."),
                             ("2:14 AM", "exclamationmark.triangle", "Docs search got blocked in QA."),
                             ("3:02 AM", "exclamationmark.triangle", "Crash watch reported an expired token."),
                             ("6:00 AM", "eye", "Dependency check found 3 updates."),
                             ("6:40 AM", "shippingbox", "Lumen 4.12.0 is ready to install."),
                             ("7:00 AM", "sun.max", "Morning briefing finished.")])
        value.suggestions = ["What did I miss overnight?", "Plan my morning", "What’s everyone working on?"]
        value.reviewCount = 3
        value.watcherNeedsAttention = true
        value.updatedAt = Date(timeIntervalSince1970: 1_791_000_240)
        return value
    }

    private static func rich(_ runs: [HomeTextRun]) -> HomeText { HomeText(runs: runs) }
    private static func open(_ title: String, route: HomeRoute, primary: Bool = false) -> HomeAction {
        HomeAction(id: "open", title: title, style: primary ? .primary : .secondary, command: .open(route))
    }
    private static func focus(_ id: String, title: String, reason: String, body: String, emoji: String?, tone: HomeTone,
                              route: HomeRoute, idea: Bool = false) -> HomeFocusItem {
        let label: String = switch route {
        case .review: "Open review"
        case .reviewRequest: "Prepare review"
        case .machine: "Open machine"
        case .watcher: "Open watcher"
        default: idea ? "Open project" : "Open conversation"
        }
        var actions = [open(label, route: route, primary: true)]
        if !idea { actions.append(HomeAction(id: "later", title: "Later", command: .snooze(id))) }
        return HomeFocusItem(id: id, title: title, reason: reason, body: HomeText(body), symbol: "arrow.triangle.pull", emoji: emoji,
                             tone: tone, actions: actions, route: route, isIdea: idea)
    }
    private static func chat(_ id: String, title: String, reason: String, location: String, quote: String,
                             waiting: Bool = true) -> HomeChatItem {
        let route = HomeRoute.chat(paneID: "fixture-work::\(id)")
        return HomeChatItem(id: id, title: title, reason: reason, location: location, quote: quote,
                            colorHex: id == "snap" ? "AAA6F4" : "9CCDB9",
                            actions: [HomeAction(id: "open", title: waiting ? "Open chat" : "Read summary", style: .reply, command: .open(route))],
                            route: route, isWaiting: waiting)
    }
    private static func recap(_ rows: [(String, String, String)]) -> [HomeRecapItem] {
        rows.enumerated().map { index, row in
            HomeRecapItem(id: "recap-\(index)", timeLabel: row.0, symbol: row.1,
                          tone: row.1 == "exclamationmark.triangle" ? .alert : .idle, body: HomeText(row.2))
        }
    }

    private static let docs = HomeChip(id: "docs", title: "Docs search", emoji: "📚", tone: .alert, route: .firstMate(machineID: "fixture-dev", featureID: "docs"))
    private static let csv = HomeChip(id: "csv", title: "Ledger CSV export", emoji: "📊", tone: .signal, route: .firstMate(machineID: "fixture-dev", featureID: "csv"))
    private static let snap = HomeChip(id: "snap", title: "Snapshot test flakes", emoji: "📸", tone: .working, route: .firstMate(machineID: "fixture-work", featureID: "snap"))
    private static let retry = HomeChip(id: "retry", title: "Retry-After support", emoji: "⏳", tone: .working, route: .firstMate(machineID: "fixture-work", featureID: "retry"))
    private static let passkey = HomeChip(id: "passkey", title: "Passkey sign-in", emoji: "🔑", tone: .attention, route: .firstMate(machineID: "fixture-work", featureID: "passkey"))
    private static let cache = HomeChip(id: "cache", title: "Image cache", emoji: "🖼️", tone: .signal, route: .firstMate(machineID: "fixture-studio", featureID: "cache"))
    private static let deepLink = HomeChip(id: "deep-link", title: "Deep link router", emoji: "🧭", tone: .idle, route: .firstMate(machineID: "fixture-dev", featureID: "deep-link"))
    private static let review88 = HomeChip(id: "pr88", title: "#88", symbol: "arrow.triangle.pull", tone: .signal, route: .review(machineID: "fixture-dev", reviewID: "r88"))
    private static let crash = HomeChip(id: "crash", title: "Crash watch", symbol: "eye", watcherAvatar: "beacon", tone: .alert, route: .watcher(machineID: "fixture-dev", watcherID: "crash"))
    private static let ci = HomeChip(id: "ci", title: "CI flake watch", symbol: "eye", watcherAvatar: "tally", tone: .brandBlue, route: .watcher(machineID: "fixture-work", watcherID: "ci"))
    private static let dev = HomeChip(id: "dev", title: "Dev", symbol: "desktopcomputer", tone: .attention, route: .machine(machineID: "fixture-dev"))
    private static let studio = HomeChip(id: "studio", title: "Studio", symbol: "desktopcomputer", tone: .alert, route: .machine(machineID: "fixture-studio"))
}
