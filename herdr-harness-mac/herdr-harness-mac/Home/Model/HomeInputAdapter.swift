import Foundation

/// Captures lightweight authoritative state only. It never creates per-feature
/// stores, fetches transcripts, changes selected targets, or acknowledges messages.
@MainActor
enum HomeInputAdapter {
    static func make(model: HerdrAppModel, shell: HerdrShellState, previousVisit: Date? = nil) -> HomeInput {
        let hosts = model.isDemoMode ? [shell.firstMateChatDemo.host] : shell.firstMateFleet.hosts
        let hostByID = Dictionary(hosts.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        var machines = model.machines.map { machine in
            let connection = model.connectionState(forMachine: machine.id)
            let state: HomeMachineFact.State = switch connection {
            case .live, .demo: .online
            case .connecting: .connecting
            case .disconnected, .failed: .offline
            }
            return HomeMachineFact(id: machine.id, name: machine.name, state: state,
                                   needsAttention: connection == .failed,
                                   failureBeganAt: model.connectionFailureBeganAt(forMachine: machine.id))
        }
        // The existing First Mate demo uses a separate synthetic machine ID.
        if model.isDemoMode {
            for host in hosts where !machines.contains(where: { $0.id == host.machineID }) {
                machines.append(.init(id: host.machineID, name: host.machineName, state: .online))
            }
        }
        var sources = sourceFacts(model: model, shell: shell, hosts: hosts)
        let features = featureFacts(hosts: hosts, readState: shell.firstMateFleet.readState)
        let reviews = shell.prReviewFleet.active.map { entry in
            let review = entry.review
            return HomeReviewFact(
                machineID: entry.machineID, machineName: entry.machineName, reviewID: review.id, title: review.title,
                pullRequest: HomePullRequestIdentity(url: review.url, repository: "\(review.owner)/\(review.repo)", number: review.number),
                state: HomeReviewFact.State(rawValue: review.status.rawValue) ?? .unknown,
                needsUser: review.viewerReview?.needsAttention == true,
                userAttentionKnown: review.viewerReview.map {
                    ["pending", "re_review_requested", "approved", "changes_requested", "commented", "not_reviewed"].contains($0.state)
                        && $0.error == nil
                } ?? false,
                isOwnPR: review.viewerReview?.isOwnPR == true,
                isArchived: review.archivedAt != nil, isClosed: ["closed", "merged"].contains(review.githubState.lowercased()),
                isStale: review.viewerReview?.error != nil || shell.prReviewFleet.notices.contains { $0.machineID == entry.machineID }, error: review.error,
                activityAt: (review.preparedAt ?? review.updatedAt).flatMap(HerdrTimestamp.date),
                evidenceID: [review.headSHA, String(review.revision), review.viewerReview?.state ?? "unknown"].joined(separator: ":")
            )
        }
        let requestSection = shell.workInbox.response.reviewRequests
        let requests = requestSection.items.compactMap { request -> HomeReviewRequestFact? in
            guard let identity = HomePullRequestIdentity(url: request.url, repository: request.repository, number: request.number) else { return nil }
            return .init(pullRequest: identity, title: request.title, isDraft: request.isDraft,
                         isOpen: request.state.lowercased() == "open", isStale: shell.workInbox.error(for: .github) != nil,
                         author: request.author)
        }
        if requests.count < requestSection.items.count {
            sources.append(.init(id: "github-invalid-identities", state: .stale,
                                 notice: "Some GitHub requests have an unverified pull request identity. Open the inbox to inspect them."))
        }
        let watchers = shell.watchers.entries.map { entry in
            let watcher = entry.watcher
            return HomeWatcherFact(machineID: entry.machineID, machineName: entry.machineName,
                                   watcherID: watcher.id, title: watcher.name, summary: watcher.summary, avatar: watcher.avatar,
                                   attention: watcher.attention, isWorking: watcher.live != nil,
                                   isStale: shell.watchers.notices[entry.machineID] != nil,
                                   evidenceID: "\(watcher.revision):\(watcher.runsCount):\(watcher.state)")
        }
        let chats = chatFacts(model: model, shell: shell, hosts: hosts)
        let existingPanes = Set(model.workspaces.flatMap(\.panes).map(\.id))
        func recap(_ alert: HerdrAlert) -> HomeRecapFact {
            HomeRecapFact(machineID: alert.machineID, eventID: alert.rawID, date: alert.createdDate,
                          title: alert.title, detail: alert.message,
                          symbol: alert.status == .blocked ? "bubble.left.and.bubble.right" : "checkmark.circle",
                          tone: alert.status == .blocked ? .attention : .signal,
                          route: existingPanes.contains(alert.scopedPaneID) ? .chat(paneID: alert.scopedPaneID) : nil)
        }
        let primaryName = model.machines.first { $0.id == model.workInboxConnectionIdentity.machineID }?.name ?? "configured companion"
        return HomeInput(machines: machines, sources: sources, features: features, reviews: reviews,
                         reviewRequests: requests, watchers: watchers, chats: chats,
                         currentRecap: model.alerts.map(recap), historicalRecap: model.activityHistoryAlerts.map(recap),
                         previousVisit: previousVisit, leadAvailable: hostByID.values.contains(where: \.supportsLead),
                         coverageLine: "GitHub requests: \(primaryName) only. Recent activity is a bounded history.")
    }

    private static func featureFacts(hosts: [FirstMateFleetHost], readState: FirstMateReadState) -> [HomeFeatureFact] {
        let hostByID = Dictionary(hosts.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        return FirstMateConversationList.build(hosts: hosts, readState: readState).map { conversation in
            let host = hostByID[conversation.machineID]
            let feature = host?.features.first { $0.id == conversation.featureID }
            let entry = host?.fleetEntries?[conversation.featureID]
            let state: HomeFeatureFact.State
            if ["completed", "cancelled", "archived"].contains(conversation.featureStatus) { state = .closed }
            else if conversation.featureStatus == "blocked" || conversation.hudStatus == .blocked { state = .blocked }
            else if FirstMateAttention.needsHumanDecision(status: conversation.featureStatus)
                        || feature?.dashboardSummary?.awaitingTurn == true || conversation.hudStatus.needsYou { state = .needsDecision }
            else if conversation.isWorkingOnReply || conversation.hudStatus == .working { state = .working }
            else if ["ready", "paused", "idle"].contains(conversation.featureStatus) { state = .ready }
            else { state = .unknown }
            // Meaningful source activity is preferred; telemetry updated_at is
            // not used for a fingerprint and cannot undo a local snooze.
            let evidence = entry?.latestFirstMateMessageID ?? entry?.latestMessage?.id
                ?? feature?.dashboardSummary?.latestMessageAt ?? feature?.currentVisitID ?? ""
            return HomeFeatureFact(machineID: conversation.machineID, machineName: conversation.machineName,
                                   featureID: conversation.featureID, title: conversation.name,
                                   preview: conversation.previewText, state: state, emoji: conversation.emoji,
                                   isLead: feature?.isLead == true || host?.lead?.feature.id == conversation.featureID,
                                   isArchived: conversation.isArchived, isStale: host?.error != nil,
                                   activityAt: (entry?.activityAt ?? entry?.latestMessage?.createdAt
                                                ?? feature?.dashboardSummary?.activityAt
                                                ?? feature?.dashboardSummary?.latestMessageAt).flatMap(HerdrTimestamp.date),
                                   evidenceID: evidence)
        }
    }

    private static func sourceFacts(model: HerdrAppModel, shell: HerdrShellState, hosts: [FirstMateFleetHost]) -> [HomeSourceFact] {
        if model.isDemoMode { return [.init(id: "synthetic-demo", state: .current)] }
        var sources: [HomeSourceFact] = []
        for machine in model.machines {
            let host = hosts.first { $0.machineID == machine.id }
            let state: HomeSourceFact.State
            if host?.unsupported == true { state = .unsupported }
            else if host?.error != nil { state = host?.lastUpdated == nil ? .unavailable : .stale }
            else if host?.lastUpdated == nil { state = .loading }
            else { state = .current }
            sources.append(.init(id: "first-mate:" + machine.id, state: state,
                                 updatedAt: shell.firstMateFleet.lastSuccessfulContact(machineID: machine.id) ?? host?.lastUpdated,
                                 notice: host?.error.map { "\(machine.name): \($0)" }
                                    ?? (state == .unsupported ? "\(machine.name) needs companion support for First Mate." : nil)))
            let watcherState = shell.watchers.state(for: machine.id)
            let watcherSource: HomeSourceFact.State = switch watcherState {
            case .checking: .loading
            case .on: shell.watchers.loaded ? .current : .loading
            case .off: .current
            case .needsUpdate: .unsupported
            case .unreachable: shell.watchers.entries.contains { $0.machineID == machine.id } ? .stale : .unavailable
            }
            sources.append(.init(id: "watchers:" + machine.id, state: watcherSource,
                                 updatedAt: shell.watchers.lastSuccessfulRefreshAt,
                                 notice: shell.watchers.notices[machine.id]
                                    ?? (watcherSource == .unsupported ? "\(machine.name) needs companion support for Watchers." : nil)))
        }
        let reviewState: HomeSourceFact.State
        if !shell.prReviewFleet.notices.isEmpty { reviewState = shell.prReviewFleet.active.isEmpty ? .unavailable : .stale }
        else if !shell.prReviewFleet.hasLoaded { reviewState = .loading }
        else { reviewState = .current }
        sources.append(.init(id: "prepared-reviews", state: reviewState, updatedAt: shell.prReviewFleet.lastSuccessfulRefreshAt,
                             notice: shell.prReviewFleet.notices.isEmpty ? nil : shell.prReviewFleet.notices.map { "\($0.machineName): \($0.message)" }.joined(separator: "\n")))
        let inbox = shell.workInbox
        let requestState: HomeSourceFact.State
        if inbox.error(for: .github) != nil { requestState = inbox.reviewRequestsUpdatedAt == nil ? .unavailable : .stale }
        else if inbox.reviewRequestsUpdatedAt == nil { requestState = .loading }
        else { requestState = .current }
        let primaryName = model.machines.first { $0.id == model.workInboxConnectionIdentity.machineID }?.name ?? "the configured companion"
        sources.append(.init(id: "github-requests", state: requestState, updatedAt: inbox.reviewRequestsUpdatedAt,
                             notice: inbox.error(for: .github).map { "GitHub inbox on \(primaryName): \($0)" }))
        if let error = model.activityFeedError {
            sources.append(.init(id: "recap", state: .stale, notice: "Some recent history is unavailable: \(error)"))
        } else {
            sources.append(.init(id: "recap", state: model.activityHistoryLoaded ? .current : .loading))
        }
        return sources
    }

    private static func chatFacts(model: HerdrAppModel, shell: HerdrShellState, hosts: [FirstMateFleetHost]) -> [HomeChatFact] {
        let reviews = shell.prReviewFleet.active + shell.prReviewFleet.archived
        let reviewWorkspaces = Set(reviews.compactMap { entry in
            entry.review.workspaceID.map { HomeIdentity.scoped(kind: "workspace", machineID: entry.machineID, entityID: $0) }
        })
        let reviewTabs = Set(reviews.compactMap { entry in
            entry.review.tabID.map { MachineScopedID.compose(machineID: entry.machineID, rawID: $0) }
        })
        let coordinatorSessions = Set(hosts.flatMap { host in
            host.features.compactMap { feature in
                feature.nativeSessionID.map { HomeIdentity.scoped(kind: "session", machineID: host.machineID, entityID: $0) }
            }
        })
        let alerts = Dictionary(grouping: model.alerts, by: \.scopedPaneID)
        let unread = model.unreadPaneIDs
        let names = Dictionary(model.machines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return model.workspaces.flatMap { workspace in
            workspace.panes.map { pane in
                let isReviewWorker = reviewWorkspaces.contains(HomeIdentity.scoped(kind: "workspace", machineID: pane.machineID, entityID: pane.workspaceID))
                    || reviewTabs.contains(pane.scopedTabID)
                let isFirstMateWorker = [pane.piSemantic?.sessionID, pane.piSemantic?.parentSessionID].compactMap { $0 }.contains {
                    coordinatorSessions.contains(HomeIdentity.scoped(kind: "session", machineID: pane.machineID, entityID: $0))
                }
                let relevantAlert = alerts[pane.id]?.filter {
                    $0.status == pane.agentStatus && ($0.createdDate ?? .distantPast) >= (pane.lastActivityAt ?? .distantPast)
                }.max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
                let preview = relevantAlert.flatMap { $0.message.isEmpty ? nil : $0.message } ?? pane.sessionActivity ?? ""
                let connection = model.connectionState(forMachine: pane.machineID)
                let color = model.chatTabColors.color(for: pane.scopedTabID).map { String(format: "#%06X", $0.rgb) }
                return HomeChatFact(paneID: pane.id, machineID: pane.machineID, title: pane.displayTitle,
                                    location: "\(workspace.label) on \(names[pane.machineID] ?? "Machine")", preview: preview,
                                    isWaiting: pane.agentStatus == .blocked,
                                    isUnreadCompletion: pane.agentStatus == .done && unread.contains(pane.id),
                                    isReservedShell: pane.reservedShell, isWorker: isReviewWorker || isFirstMateWorker,
                                    isStale: connection != .live && connection != .demo, colorHex: color,
                                    activityAt: pane.lastActivityAt ?? pane.firstSeenAt, evidenceID: pane.episodeKey)
            }
        }
    }
}
