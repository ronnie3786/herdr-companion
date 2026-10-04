import Foundation

/// Deterministic presentation from observed facts. No clocks, stores, transports,
/// user defaults, or source mutations are hidden inside the projection.
enum HomeProjection {
    /// Longer than the conservative inbox fallback, but finite after inactivity.
    static let sourceFreshnessLimit: TimeInterval = 10 * 60

    static func project(_ input: HomeInput, now: Date, calendar: Calendar) -> HomeSnapshot {
        let machines = Dictionary(input.machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let features = unique(input.features.filter {
            machines[$0.machineID] != nil && !$0.isLead && !$0.isArchived && $0.state != .closed
        }, id: \.id)
        let reviews = unique(input.reviews.filter {
            machines[$0.machineID] != nil && !$0.isArchived && !$0.isClosed
        }, id: \.id)
        let prepared = Set(reviews.compactMap(\.pullRequest))
        let requests = unique(input.reviewRequests.filter {
            $0.isOpen && !$0.isDraft && !prepared.contains($0.pullRequest)
        }, id: { $0.pullRequest.id })
        let watchers = unique(input.watchers.filter { machines[$0.machineID] != nil }, id: \.id)
        let chats = unique(input.chats.filter {
            machines[$0.machineID] != nil && !$0.isReservedShell && !$0.isWorker
                && ($0.isWaiting || $0.isUnreadCompletion)
        }, id: \.paneID).sorted {
            if $0.isWaiting != $1.isWaiting { return $0.isWaiting }
            return newestFirst($0.activityAt, $1.activityAt, $0.paneID, $1.paneID)
        }

        var snapshot = HomeSnapshot()
        snapshot.availability = availability(input, now: now)
        snapshot.isLoading = snapshot.availability == .loading || input.sources.contains { $0.state == .loading }
        snapshot.greeting = greeting(now: now, calendar: calendar)
        snapshot.dateLine = now.formatted(Date.FormatStyle(locale: calendar.locale ?? Locale(identifier: "en_US"),
                                                          calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day())
        snapshot.firstMateStatus = input.leadAvailable ? "Ready when you are" : "Connect a lead First Mate to chat"
        snapshot.coverageLine = input.coverageLine
        snapshot.notices = unique(input.sources.compactMap(\.notice), id: { $0 })
        if input.sources.contains(where: { expired($0, now: now) }) {
            snapshot.notices.append("Some information hasn't been refreshed recently. Showing the last known state.")
        }
        if !input.machines.isEmpty, !input.leadAvailable {
            snapshot.notices.append("Home chat needs a companion with lead First Mate support.")
        }
        let hasUnknownWork = features.contains { $0.state == .unknown }
            || reviews.contains { !$0.isOwnPR && ($0.state == .unknown || !$0.userAttentionKnown) }
        if hasUnknownWork { snapshot.notices.append("Some work has an unknown status. Open its source to check it.") }

        snapshot.focus = machineFocus(input.machines) + featureFocus(features) + reviewFocus(reviews) + requestFocus(requests)
        snapshot.focus.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return newestFirst($0.updatedAt, $1.updatedAt, $0.id, $1.id)
        }
        snapshot.focusCount = snapshot.focus.count(where: { !$0.isIdea })
        snapshot.reviewCount = reviews.count { !$0.isOwnPR && $0.state == .ready && $0.needsUser } + requests.count
        snapshot.reviewNeedsAttention = reviews.contains { !$0.isOwnPR && $0.state == .failed }
        snapshot.watcherNeedsAttention = watchers.contains { $0.attention?.isEmpty == false }
        snapshot.radar = watcherRadar(watchers)
        snapshot.chats = chats.map { chat in
            let route = HomeRoute.chat(paneID: chat.paneID)
            return HomeChatItem(id: chat.paneID, title: chat.title,
                                reason: chat.isWaiting ? "Waiting for your input" : "New completed reply",
                                location: chat.location, quote: chat.preview, colorHex: chat.colorHex,
                                actions: [openAction(route, title: "Open chat")], route: route,
                                isWaiting: chat.isWaiting, isStale: chat.isStale, evidenceID: chat.evidenceID)
        }
        snapshot.waitingChatCount = chats.count(where: \.isWaiting)
        snapshot.chatsTitle = snapshot.waitingChatCount > 0 ? "Chats waiting on you" : "Worth a look"
        snapshot.recap = recap(input, machineIDs: Set(machines.keys), now: now, calendar: calendar)
        snapshot.recapTitle = input.previousVisit == nil ? "Recent updates" : "While you were away"
        snapshot.canShowAllClear = snapshot.availability == .current && !hasUnknownWork
            && snapshot.focusCount == 0 && snapshot.waitingChatCount == 0 && !snapshot.watcherNeedsAttention
        snapshot.statusLine = statusLine(snapshot)
        snapshot.summary = summary(snapshot, machineCount: machines.count)
        snapshot.moving = moving(features)
        snapshot.mood = mood(snapshot)
        snapshot.suggestions = suggestions(snapshot, now: now, calendar: calendar)
        if snapshot.canShowAllClear {
            snapshot.focusTitle = "If you have a little time"
            snapshot.focus = ideas(features, leadAvailable: input.leadAvailable)
        }
        // Successful poll timestamps change even when the evidence does not.
        // Show meaningful activity here and publish staleness through availability.
        snapshot.updatedAt = (features.compactMap(\.activityAt) + reviews.compactMap(\.activityAt)
                              + chats.compactMap(\.activityAt) + snapshot.recap.compactMap(\.date)).max()
        return snapshot
    }

    private static func availability(_ input: HomeInput, now: Date) -> HomeAvailability {
        guard !input.machines.isEmpty else { return .noMachines }
        if input.machines.allSatisfy({ $0.state == .offline }) { return .disconnected }
        guard !input.sources.isEmpty else { return .loading }
        if input.sources.allSatisfy({ $0.state == .loading }) { return .loading }
        if input.machines.contains(where: { $0.state != .online })
            || input.sources.contains(where: { $0.state != .current || expired($0, now: now) }) { return .stale }
        return .current
    }

    private static func expired(_ source: HomeSourceFact, now: Date) -> Bool {
        guard source.state == .current, let updated = source.updatedAt else { return false }
        return now.timeIntervalSince(updated) > sourceFreshnessLimit
    }

    private static func machineFocus(_ machines: [HomeMachineFact]) -> [HomeFocusItem] {
        unique(machines, id: \.id).filter { $0.state == .offline && $0.needsAttention }.map { machine in
            let id = HomeIdentity.scoped(kind: "machine", machineID: machine.id, entityID: "connection")
            let route = HomeRoute.machine(machineID: machine.id)
            let detail = machine.notice ?? "The companion is unreachable. Check its connection in Machines."
            return HomeFocusItem(id: id, title: "\(machine.name) needs a look", reason: "Machine unreachable",
                                 body: HomeText(detail), symbol: "wifi.exclamationmark", tone: .alert,
                                 actions: [openAction(route, title: "Open Machines")],
                                 route: route, isStale: true, updatedAt: machine.failureBeganAt, priority: 0,
                                 fingerprint: HomeIdentity.fingerprint([id, machine.state.rawValue, detail,
                                                                       machine.failureBeganAt.map { String($0.timeIntervalSince1970) } ?? ""]))
        }
    }

    private static func featureFocus(_ features: [HomeFeatureFact]) -> [HomeFocusItem] {
        features.filter { $0.state == .blocked || $0.state == .needsDecision }.map { feature in
            let blocked = feature.state == .blocked
            let reason = blocked ? "Blocked on \(feature.machineName)" : "Your turn on \(feature.machineName)"
            return HomeFocusItem(id: feature.id, title: feature.title, reason: reason,
                                 body: HomeText(feature.preview.isEmpty ? "Open the conversation to see what needs your input." : feature.preview),
                                 symbol: blocked ? "exclamationmark.bubble" : "bubble.left.and.bubble.right",
                                 emoji: feature.emoji, tone: blocked ? .alert : .attention,
                                 actions: [openAction(feature.route, title: "Open conversation")],
                                 route: feature.route, isStale: feature.isStale, updatedAt: feature.activityAt,
                                 priority: blocked ? 10 : 20,
                                 fingerprint: HomeIdentity.fingerprint([feature.id, feature.state.rawValue,
                                                                       feature.evidenceID, feature.preview]))
        }
    }

    private static func reviewFocus(_ reviews: [HomeReviewFact]) -> [HomeFocusItem] {
        reviews.filter { !$0.isOwnPR && ($0.state == .failed || ($0.state == .ready && $0.needsUser)) }.map { review in
            let failed = review.state == .failed
            let detail = failed ? (review.error ?? "Review preparation failed. Open it to inspect the failure and retry.")
                : "The prepared review is waiting for your review on \(review.machineName)."
            return HomeFocusItem(id: review.id, title: review.title,
                                 reason: failed ? "Preparation needs attention" : "Ready for your review",
                                 body: HomeText(detail), symbol: "arrow.triangle.pull", tone: failed ? .alert : .signal,
                                 actions: [openAction(review.route, title: "Open review")],
                                 route: review.route, isStale: review.isStale, updatedAt: review.activityAt,
                                 priority: failed ? 30 : 40,
                                 fingerprint: HomeIdentity.fingerprint([review.id, review.state.rawValue,
                                                                       review.evidenceID, review.error ?? ""]))
        }
    }

    private static func requestFocus(_ requests: [HomeReviewRequestFact]) -> [HomeFocusItem] {
        requests.map { request in
            let id = "request:" + request.pullRequest.id
            let route = HomeRoute.reviewRequest(url: request.pullRequest.url)
            return HomeFocusItem(id: id, title: request.title, reason: "Review requested",
                                 body: HomeText("\(request.pullRequest.label) is waiting in the configured GitHub inbox."),
                                 symbol: "arrow.triangle.pull", tone: .accent,
                                 actions: [openAction(route, title: "Prepare this review")],
                                 route: route, isStale: request.isStale, priority: 50,
                                 fingerprint: HomeIdentity.fingerprint([id, "open", request.title, request.author]))
        }
    }

    private static func watcherRadar(_ watchers: [HomeWatcherFact]) -> [HomeRadarItem] {
        watchers.filter { $0.attention?.isEmpty == false || $0.isWorking }.sorted {
            let left = $0.attention?.isEmpty == false, right = $1.attention?.isEmpty == false
            return left != right ? left : $0.id < $1.id
        }.map { watcher in
            let tone: HomeTone = watcher.attention?.isEmpty == false ? .attention : .brandBlue
            let chip = HomeChip(id: watcher.id, title: watcher.title, symbol: "eye", watcherAvatar: watcher.avatar,
                                tone: tone, route: watcher.route)
            let detail = watcher.attention ?? (watcher.summary.isEmpty ? "is working now" : watcher.summary)
            let stale = watcher.isStale ? " Last known state." : ""
            return HomeRadarItem(id: watcher.id, body: HomeText(runs: [.chip(chip), .text(" · \(detail).\(stale)")]),
                                 symbol: "eye", watcherAvatar: watcher.avatar, tone: tone,
                                 actions: [openAction(watcher.route, title: "Open watcher")],
                                 fingerprint: HomeIdentity.fingerprint([watcher.id, watcher.evidenceID, detail]))
        }
    }

    private static func ideas(_ features: [HomeFeatureFact], leadAvailable: Bool) -> [HomeFocusItem] {
        var items = features.filter { $0.state == .ready && !$0.isStale }.sorted {
            newestFirst($0.activityAt, $1.activityAt, $0.id, $1.id)
        }.prefix(3).map { feature in
            HomeFocusItem(id: "idea:" + feature.id, title: feature.title, reason: "Pick up where you left off",
                          body: "Open this conversation to decide what comes next.", emoji: feature.emoji,
                          actions: [openAction(feature.route, title: "Open conversation")], route: feature.route,
                          isIdea: true, updatedAt: feature.activityAt,
                          fingerprint: HomeIdentity.fingerprint([feature.id, feature.state.rawValue, feature.evidenceID]))
        }
        if leadAvailable, items.count < 3 {
            items.append(HomeFocusItem(id: "idea:new-feature", title: "Start something new", reason: "When you're ready",
                                       body: "Bring an idea to your First Mate and work out the next step together.",
                                       actions: [.init(id: "draft-idea", title: "Talk it through", style: .primary,
                                                       command: .ask("I'd like to start something new. Help me shape the idea.", context: nil))],
                                       route: .firstMateLead, isIdea: true, fingerprint: "new-feature-v1"))
        }
        return items
    }

    private static func recap(_ input: HomeInput, machineIDs: Set<String>, now: Date, calendar: Calendar) -> [HomeRecapItem] {
        var merged: [String: HomeRecapFact] = [:]
        for item in input.historicalRecap { merged[item.id] = item }
        // Current source state wins even if an older history response arrived last.
        for item in input.currentRecap { merged[item.id] = item }
        let cutoff = input.previousVisit ?? calendar.startOfDay(for: now)
        let time = Date.FormatStyle(locale: calendar.locale ?? Locale(identifier: "en_US"), calendar: calendar,
                                   timeZone: calendar.timeZone).hour().minute()
        return merged.values.filter {
            guard machineIDs.contains($0.machineID), let date = $0.date else { return false }
            return date > cutoff && date <= now
        }.sorted { newestFirst($0.date, $1.date, $0.id, $1.id) }.prefix(30).map { item in
            let body: HomeText
            if let route = item.route {
                body = HomeText(runs: [.chip(HomeChip(id: item.id, title: item.title, symbol: item.symbol,
                                                     tone: item.tone, route: route)),
                                      .text(item.detail.isEmpty ? "" : " · \(item.detail)")])
            } else {
                body = HomeText(item.title + (item.detail.isEmpty ? "" : " · \(item.detail)"))
            }
            return HomeRecapItem(id: item.id, date: item.date, timeLabel: item.date?.formatted(time) ?? "",
                                 symbol: item.symbol, tone: item.tone, body: body, route: item.route)
        }
    }

    private static func summary(_ snapshot: HomeSnapshot, machineCount: Int) -> [HomeText] {
        switch snapshot.availability {
        case .noMachines: return ["Connect a machine to see your work here. First Mate, reviews, watchers, and chats will appear as their companions report in."]
        case .loading: return ["Checking your machines for current work. I'll show confirmed updates as they arrive."]
        case .disconnected:
            return ["Your machines are unreachable right now. Any work shown below is its last known state. Open Machines to reconnect."]
        case .current, .stale: break
        }
        var paragraphs: [HomeText] = []
        if let first = snapshot.focus.first {
            let chip = HomeChip(id: first.id, title: first.title, symbol: first.symbol, emoji: first.emoji,
                                watcherAvatar: first.watcherAvatar, tone: first.tone, route: first.route)
            let more = snapshot.focusCount > 1 ? " There \(snapshot.focusCount == 2 ? "is 1 other item" : "are \(snapshot.focusCount - 1) other items") to look at." : ""
            paragraphs.append(HomeText(runs: [.chip(chip), .text(" needs a look.\(more)")]))
        } else if snapshot.canShowAllClear {
            paragraphs.append("Nothing is waiting on your input in the available sources.")
        } else if snapshot.waitingChatCount > 0 {
            paragraphs.append(HomeText("\(snapshot.waitingChatCount) \(snapshot.waitingChatCount == 1 ? "chat is" : "chats are") waiting for your input."))
        } else {
            paragraphs.append("There are no confirmed decisions to show yet. Some source information still needs a check.")
        }
        if snapshot.availability == .stale {
            paragraphs.append("Some sources haven't checked in. Their last known work stays visible below.")
        } else if snapshot.waitingChatCount > 0, !snapshot.focus.isEmpty {
            paragraphs.append(HomeText("\(snapshot.waitingChatCount) \(snapshot.waitingChatCount == 1 ? "chat also needs" : "chats also need") your input."))
        }
        return paragraphs
    }

    private static func moving(_ features: [HomeFeatureFact]) -> HomeText {
        let working = features.filter { $0.state == .working }.sorted { newestFirst($0.activityAt, $1.activityAt, $0.id, $1.id) }
        var runs: [HomeTextRun] = []
        for (offset, feature) in working.prefix(3).enumerated() {
            if offset > 0 { runs.append(.text(", ")) }
            runs.append(.chip(HomeChip(id: feature.id, title: feature.title, emoji: feature.emoji,
                                      tone: .working, route: feature.route)))
            runs.append(.text(feature.isStale ? " was working when last seen" : " is moving"))
        }
        if working.count > 3 { runs.append(.text(", and \(working.count - 3) more")) }
        return HomeText(runs: runs)
    }

    private static func statusLine(_ snapshot: HomeSnapshot) -> String {
        switch snapshot.availability {
        case .noMachines: return "Start by connecting a machine"
        case .loading: return "Checking in with your machines"
        case .disconnected: return "Machines are unreachable"
        case .stale: return "Some sources need a check"
        case .current:
            if snapshot.canShowAllClear { return "All clear for now" }
            if snapshot.focusCount > 0 { return "\(snapshot.focusCount) \(snapshot.focusCount == 1 ? "thing needs" : "things need") your attention" }
            return "Your work at a glance"
        }
    }

    private static func mood(_ snapshot: HomeSnapshot) -> HomeMood {
        if snapshot.isLoading && snapshot.focus.isEmpty { return .thinking }
        if snapshot.availability == .disconnected || snapshot.focus.contains(where: { $0.tone == .alert }) { return .concerned }
        if snapshot.focusCount > 0 || snapshot.waitingChatCount > 0 || snapshot.watcherNeedsAttention { return .attentive }
        return snapshot.canShowAllClear ? .happy : .calm
    }

    private static func greeting(now: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: now) {
        case 5..<12: "Good morning."
        case 12..<18: "Good afternoon."
        default: "Good evening."
        }
    }

    private static func suggestions(_ snapshot: HomeSnapshot, now: Date, calendar: Calendar) -> [String] {
        if snapshot.mood == .concerned { return ["What happened?", "Is anything lost?", "Fix what you can"] }
        if snapshot.canShowAllClear { return ["Wrap up my week", "What runs over the weekend?", "Start something new"] }
        if calendar.component(.hour, from: now) < 12 {
            return ["What did I miss overnight?", "Plan my morning", "What's everyone working on?"]
        }
        return ["What changed since this morning?", "Anything to check before the deploy?", "Start something new"]
    }

    private static func openAction(_ route: HomeRoute, title: String) -> HomeAction {
        HomeAction(id: "open", title: title, style: .primary, command: .open(route))
    }

    private static func newestFirst(_ left: Date?, _ right: Date?, _ leftID: String, _ rightID: String) -> Bool {
        if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
        return leftID < rightID
    }

    private static func unique<T>(_ items: [T], id: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(id($0)).inserted }
    }
}
