import Foundation

/// The chat window's demo: seven synthetic features that cover every HUD
/// status, a crew agent's message with a document card, suggested replies, and
/// long replies with ready skims. The main window keeps `features(step:)`.
///
/// Times are relative to `now` so the list reads "11:20" and "Yesterday" the
/// way the design does; before the design's newest time of day, every time
/// moves back so nothing is in the future. Every name, path, and repository
/// is invented.
extension FirstMateDemo {
    static func chatWindowFeatures(now: Date = Date(), calendar: Calendar = .current) -> [FirstMateSnapshot] {
        chatDemoFeatures.map { snapshot(for: $0, now: now, calendar: calendar) }
    }

    /// The demo's model list: two made-up models, the first the host default.
    static let modelCatalog = FirstMateModelCatalog(
        ok: true,
        models: [
            FirstMateModelOption(id: "synthetic/sample-reasoner", name: "Sample Reasoner", provider: "synthetic", reasoning: true),
            FirstMateModelOption(id: "synthetic/sample-fast", name: "Sample Fast", provider: "synthetic", reasoning: true),
        ],
        defaultModel: "synthetic/sample-reasoner",
        thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    )

    /// The demo's lead First Mate: a short conversation across the demo
    /// features, with a ready skim on its long answer and a measured context.
    static func chatWindowLead(now: Date = Date(), calendar: Calendar = .current) -> FirstMateSnapshot {
        let id = "demo-lead"
        let createdAt = chatTimestamp(daysAgo: 1, hour: 8, minute: 30, now: now, calendar: calendar)
        let answer = [
            "Three features need you. Receipt export is blocked in QA: both iPad runs failed because the share sheet has no anchor, and it's waiting on your call to ship iPhone-only or investigate iPad first.",
            "Release checklist refresh finished its review and is ready for you to approve the pull request. Review search has a question about whether results should include archived reviews.",
            "Quiet notifications and Offline sync are moving on their own. Nothing else is waiting on you.",
            "Want me to pass a decision to Receipt export?",
        ]
        let reply = answer.joined(separator: "\n\n")
        let messages = [
            FirstMateMessage(id: "\(id)-message-1", featureID: id, role: "user", text: "What needs me this morning?",
                             status: "done", createdAt: chatTimestamp(daysAgo: 0, hour: 11, minute: 22, now: now, calendar: calendar),
                             visibility: "conversation"),
            FirstMateMessage(id: "\(id)-message-2", featureID: id, role: "assistant", text: reply, status: "done",
                             createdAt: chatTimestamp(daysAgo: 0, hour: 11, minute: 23, now: now, calendar: calendar),
                             visibility: "conversation",
                             skim: skim(reply: reply, paragraphs: answer, plan: ChatDemoSkim(
                                say: [.text("Three need you: "), .link("Receipt export is blocked on iPad", paragraphs: [0]),
                                      .text(", and "), .link("two more want a decision", paragraphs: [1]), .text(".")],
                                ask: [.text("Pass a decision to Receipt export?")],
                                replies: []
                             ))),
        ]
        var feature = FirstMateFeature(
            id: id, title: "First Mate", goal: "Lead First Mate for every feature on this machine.",
            cwd: "/Users/demo", status: "ready", currentVisitID: nil, revision: 1,
            createdAt: createdAt, updatedAt: messages.last?.createdAt ?? createdAt
        )
        feature.kind = "lead"
        feature.nativeSessionID = "\(id)-session"
        feature.modelSettingsRevision = 0
        feature.coordinatorModel = "synthetic/sample-reasoner"
        feature.coordinatorThinking = "high"
        feature.modelSelection = FirstMateModelSelection(
            profile: "coordinator", requestedModel: "synthetic/sample-reasoner", requestedThinking: "high",
            actualModel: "synthetic/sample-reasoner", actualThinking: "high", source: "host_policy"
        )
        feature.coordinatorContext = FirstMateCoordinatorContext(
            nativeSessionID: "\(id)-session", status: .measured, tokens: 38_400, contextWindow: 1_000_000,
            handoffTargetTokens: 150_000, observedAt: messages.last?.createdAt
        )
        feature.usage = chatDemoUsage(tokens: 38_400, sessions: 1)
        return FirstMateSnapshot(feature: feature, visits: [], assignments: [], documents: [], messages: messages,
                                 events: [], links: [])
    }

    /// Fleet entries matching ``chatWindowFeatures(now:calendar:)``. Receipt
    /// export, Release checklist refresh, and Review search need you and are
    /// unread, so the demo Dock badge shows 3.
    static func chatWindowFleet(now: Date = Date(), calendar: Calendar = .current) -> [FirstMateFleetEntry] {
        chatDemoFeatures.map { demo in
            let value = snapshot(for: demo, now: now, calendar: calendar)
            return fleetEntry(for: demo, snapshot: value)
        }
    }

    /// The fleet entry a companion would report for one chat demo snapshot.
    static func fleetEntry(for demo: ChatDemoFeature, snapshot value: FirstMateSnapshot) -> FirstMateFleetEntry {
        let conversation = value.messages.filter(\.isConversation)
        let latest = conversation.last
        let latestFirstMate = conversation.last { $0.role == "assistant" }
        let skimSay = latest.flatMap { message -> String? in
            guard message.role == "assistant",
                  let reader = FirstMateSkimReader(skim: message.skim, reply: message.text) else { return nil }
            return reader.sentence.map(\.plainText).joined()
        }
        let percent = Int(((Double(demo.step) + demo.fraction) / Double(FirstMateChatSteps.names.count) * 100).rounded())
        return FirstMateFleetEntry(
            featureID: demo.id,
            title: demo.title,
            label: demo.label,
            emoji: demo.emoji,
            emojiSource: "user",
            status: demo.status,
            hudStatus: demo.hud,
            stepIndex: demo.step,
            stepFraction: demo.fraction,
            percent: percent,
            now: demo.now,
            latestMessage: latest.map {
                FirstMateFleetLatestMessage(id: $0.id, role: $0.role, text: String($0.text.prefix(200)),
                                            createdAt: $0.createdAt, skimSay: skimSay)
            },
            latestFirstMateMessageID: latestFirstMate?.id,
            readThroughMessageID: demo.unread ? nil : latestFirstMate?.id,
            unread: demo.unread && latestFirstMate != nil,
            workingOnReply: false,
            activityAt: latest?.createdAt,
            updatedAt: value.feature.updatedAt,
            archivedAt: nil
        )
    }

    // MARK: Model

    struct ChatDemoFeature: Sendable {
        var id: String
        var title: String
        var label: String
        var emoji: String
        var goal: String
        var status: String
        var hud: FirstMateHudStatus
        var step: Int
        var fraction: Double
        var now: String
        var unread: Bool
        var revision = 1
        var crew: [ChatDemoCrew]
        var documents: [ChatDemoDocument] = []
        var pullRequest: (number: Int, state: String)? = nil
        var messages: [ChatDemoMessage]
    }

    struct ChatDemoCrew: Sendable {
        var title: String
        var role: String
        /// A raw assignment status.
        var status: String
        var note: String
    }

    struct ChatDemoDocument: Sendable {
        var title: String
        var crew: Int?
    }

    struct ChatDemoMessage: Sendable {
        enum Author: Sendable { case firstMate, user, crew(Int) }
        var author: Author
        var daysAgo = 0
        var hour: Int
        var minute: Int
        /// Paragraphs, joined with blank lines.
        var paragraphs: [String]
        var skim: ChatDemoSkim? = nil
    }

    /// A skim written against paragraph indexes; ``skim(reply:paragraphs:plan:)``
    /// turns it into segments and anchors so the reader can verify it.
    struct ChatDemoSkim: Sendable {
        var say: [ChatDemoSkimPart]
        var ask: [ChatDemoSkimPart] = []
        var replies: [String] = []
    }

    enum ChatDemoSkimPart: Sendable {
        case text(String)
        case link(String, paragraphs: [Int])
    }

    // MARK: Building

    private static func snapshot(for demo: ChatDemoFeature, now: Date, calendar: Calendar) -> FirstMateSnapshot {
        let stageKeys = ["plan", "implement", "review", "proof", "pr", "merge"]
        let stageTitles = ["Plan", "Build", "Review", "QA", "Pull request", "Merge"]
        let createdAt = chatTimestamp(daysAgo: 2, hour: 9, minute: 0, now: now, calendar: calendar)
        let visits = (0...demo.step).map { index in
            let status: String
            if index < demo.step || demo.hud == .done || demo.hud == .ready {
                status = "completed"
            } else {
                switch demo.hud {
                case .blocked: status = "blocked"
                case .turn: status = "awaiting_direction"
                case .working: status = "running"
                default: status = "planned"
                }
            }
            return FirstMateVisit(id: "\(demo.id)-visit-\(index)", featureID: demo.id, stageKey: stageKeys[index],
                                  title: stageTitles[index], status: status, revision: 1, createdAt: createdAt,
                                  predecessorVisitID: index == 0 ? nil : "\(demo.id)-visit-\(index - 1)")
        }
        let assignments = demo.crew.enumerated().map { index, crew in
            let visit = min(visitIndex(for: crew.role), demo.step)
            var assignment = FirstMateAssignment(
                id: "\(demo.id)-crew-\(index)", featureID: demo.id, visitID: "\(demo.id)-visit-\(visit)",
                title: crew.title, role: crew.role, status: crew.status,
                verdict: crew.status == "completed" ? "passed" : nil,
                nativeSessionID: "\(demo.id)-session-\(index)", attempt: 1, generation: 1,
                inputRevision: demo.revision, updatedAt: createdAt
            )
            assignment.metadata = FirstMateAssignmentMetadata(progress: FirstMateProgress(summary: crew.note))
            return assignment
        }
        let messages = demo.messages.enumerated().map { index, message in
            let reply = message.paragraphs.joined(separator: "\n\n")
            let role: String
            var assignmentID: String?
            switch message.author {
            case .firstMate: role = "assistant"
            case .user: role = "user"
            case .crew(let crew):
                role = "assistant"
                assignmentID = "\(demo.id)-crew-\(crew)"
            }
            return FirstMateMessage(
                id: "\(demo.id)-message-\(index + 1)", featureID: demo.id, role: role, text: reply,
                status: "delivered",
                createdAt: chatTimestamp(daysAgo: message.daysAgo, hour: message.hour, minute: message.minute, now: now, calendar: calendar),
                visibility: "conversation",
                skim: message.skim.map { skim(reply: reply, paragraphs: message.paragraphs, plan: $0) },
                assignmentID: assignmentID
            )
        }
        let updatedAt = messages.last?.createdAt ?? createdAt
        let documents = demo.documents.enumerated().map { index, document in
            let assignment = document.crew.map { assignments[$0] }
            return FirstMateDocument(
                id: "\(demo.id)-document-\(index + 1)", featureID: demo.id,
                visitID: assignment?.visitID ?? visits.last?.id, assignmentID: assignment?.id,
                nativeSessionID: assignment?.nativeSessionID, title: document.title, mediaType: "text/markdown",
                contentHash: "\(demo.id)-document-\(index + 1)", createdAt: updatedAt,
                content: "# \(document.title)\n\nSynthetic demonstration notes for \(demo.title).\n\nNothing here came from a real project."
            )
        }
        let links = demo.pullRequest.map { pullRequest in
            [FirstMateLink(
                id: "\(demo.id)-pr-\(pullRequest.number)", featureID: demo.id,
                url: "https://github.com/example-org/sample-app/pull/\(pullRequest.number)", kind: "pull_request",
                title: "example-org/sample-app #\(pullRequest.number)", titleSource: pullRequest.state,
                source: "discovery", createdAt: updatedAt, updatedAt: updatedAt
            )]
        } ?? []
        let events = [FirstMateEvent(sequence: 1, id: "\(demo.id)-event-1", featureID: demo.id, type: "visit.updated",
                                     summary: demo.now, createdAt: updatedAt)]
        var feature = FirstMateFeature(
            id: demo.id, title: demo.title, goal: demo.goal, cwd: "/workspace/sample-app", status: demo.status,
            currentVisitID: visits.last?.id, revision: demo.revision, createdAt: createdAt, updatedAt: updatedAt
        )
        feature.usage = chatDemoUsage(tokens: 1_200 * (demo.step + 1) + 300 * demo.crew.count, sessions: demo.crew.count + 1)
        // Like a companion's row, so the shared composer's model pill shows.
        feature.modelSettingsRevision = 0
        var value = FirstMateSnapshot(feature: feature, visits: visits, assignments: assignments, documents: documents,
                                      messages: messages, events: events, links: links)
        var summary = FirstMateDashboardSummary.from(value)
        summary.stageCount = FirstMateChatSteps.names.count
        summary.stageCountIsEstimate = false
        summary.activityAt = updatedAt
        summary.awaitingTurn = false
        value.feature.dashboardSummary = summary
        return value
    }

    private static func visitIndex(for role: String) -> Int {
        switch role {
        case "Planner", "Researcher": 0
        case "Builder", "Designer": 1
        case "Reviewer": 2
        case "Tester": 3
        default: 0
        }
    }

    /// Segments one paragraph per blank-line block, the way the companion's
    /// segmenter does for plain prose, and links the skim's phrases to them.
    static func skim(reply: String, paragraphs: [String], plan: ChatDemoSkim) -> FirstMateSkim {
        var segments: [SkimSegment] = []
        var offset = 0
        var line = 1
        for (index, paragraph) in paragraphs.enumerated() {
            let length = paragraph.utf16.count
            let lines = paragraph.split(separator: "\n", omittingEmptySubsequences: false).count
            segments.append(SkimSegment(
                id: "s\(index + 1)", n: index + 1, kind: "paragraph", startLine: line, endLine: line + lines - 1,
                start: offset, end: offset + length, words: paragraph.split(whereSeparator: \.isWhitespace).count
            ))
            offset += length + 2
            line += lines + 1
        }
        var anchors: [SkimAnchor] = []
        func tokens(_ parts: [ChatDemoSkimPart]) -> [SkimToken] {
            parts.map { part in
                switch part {
                case .text(let value):
                    return .text(value)
                case .link(let label, let indexes):
                    let id = "a\(anchors.count + 1)"
                    let refs = indexes.map { "s\($0 + 1)" }
                    anchors.append(SkimAnchor(id: id, label: label, refs: refs, kind: "text"))
                    return .anchor(id: id, label: [.text(label)], refs: refs)
                }
            }
        }
        var blocks: [SkimBlock] = [.line(kind: "say", tokens: tokens(plan.say))]
        if !plan.ask.isEmpty { blocks.append(.line(kind: "ask", tokens: tokens(plan.ask))) }
        blocks += plan.replies.map { .line(kind: "reply", tokens: [.text($0)]) }
        let linked = Set(anchors.flatMap(\.refs))
        let rest = segments.map(\.id).filter { !linked.contains($0) }
        let skimWords = blocks.reduce(0) { total, block in
            guard case .line(_, let lineTokens) = block else { return total }
            return total + lineTokens.map(\.plainText).joined().split(whereSeparator: \.isWhitespace).count
        }
        let document = SkimDocument(
            status: plan.ask.isEmpty ? "answer" : "question", statusLabel: plan.ask.isEmpty ? "Answer" : "Question",
            blocks: blocks, rest: SkimRest(refs: rest), anchors: anchors,
            stats: SkimStats(sourceWords: reply.split(whereSeparator: \.isWhitespace).count, skimWords: skimWords)
        )
        return FirstMateSkim(status: .ready, document: document, segments: segments)
    }

    static func chatTimestamp(daysAgo: Int, hour: Int, minute: Int, now: Date, calendar: Calendar) -> String {
        let date = designDate(daysAgo: daysAgo, hour: hour, minute: minute, now: now, calendar: calendar)
        return HerdrTimestamp.string(from: date.addingTimeInterval(-chatDemoShift(now: now, calendar: calendar)))
    }

    /// The design's clock time on a day relative to `now`.
    private static func designDate(daysAgo: Int, hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// Early in the day the design's clock times are still ahead of `now`, so
    /// the whole demo moves back until its newest message is a minute old.
    /// Order and spacing stay the same; later in the day nothing moves.
    static func chatDemoShift(now: Date, calendar: Calendar) -> TimeInterval {
        let newest = chatDemoFeatures.flatMap(\.messages)
            .map { designDate(daysAgo: $0.daysAgo, hour: $0.hour, minute: $0.minute, now: now, calendar: calendar) }
            .max() ?? now
        return max(0, newest.timeIntervalSince(now) + 60)
    }

    private static func chatDemoUsage(tokens: Int, sessions: Int) -> FirstMateUsage {
        let cost = Double(tokens) * 0.000_004
        return FirstMateUsage(
            currency: "USD", costUSD: cost, status: "complete", inputTokens: tokens * 3 / 4,
            outputTokens: tokens / 4, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: tokens,
            usageRecords: sessions, missingCostRecords: 0, sessionCount: sessions, knownCostSessions: sessions,
            models: [.init(provider: "synthetic", model: "sample-reasoner", costUSD: cost, status: "complete",
                           inputTokens: tokens * 3 / 4, outputTokens: tokens / 4, cacheReadTokens: 0,
                           cacheWriteTokens: 0, totalTokens: tokens, usageRecords: sessions, missingCostRecords: 0)],
            updatedAt: timestamp
        )
    }

    private static func mention(_ name: String, feature: String, crew: Int? = nil) -> String {
        let target: FirstMateMentionTarget = crew.map { .agent(featureID: feature, assignmentID: "\(feature)-crew-\($0)") }
            ?? .feature(featureID: feature)
        return FirstMateMention.markdownLink(name: name, target: target)
    }

    // MARK: Data

    static var chatDemoFeatures: [ChatDemoFeature] {
        [receiptExport, releaseChecklist, reviewSearch, quietNotifications, offlineSync, homeWidgets, launchPolish]
    }

    private static var receiptExport: ChatDemoFeature {
        ChatDemoFeature(
            id: "demo-receipts", title: "Receipt export", label: "Receipt export", emoji: "🧾",
            goal: "Export any receipt as a PDF from the receipt screen.",
            status: "blocked", hud: .blocked, step: 3, fraction: 0.45,
            now: "QA failed twice on iPad. The export sheet never appears, so the UI test times out.",
            unread: true, revision: 2,
            crew: [
                ChatDemoCrew(title: "Export flow", role: "Builder", status: "completed", note: "Built the export flow and its PDF renderer"),
                ChatDemoCrew(title: "Device QA", role: "Tester", status: "blocked", note: "iPad run 2 of 2 failed at the export sheet"),
                ChatDemoCrew(title: "Fix review", role: "Reviewer", status: "queued", note: "Waiting for a fix to review"),
                ChatDemoCrew(title: "Export plan", role: "Planner", status: "completed", note: "Planned the export flow and its checks"),
            ],
            documents: [ChatDemoDocument(title: "Export flow notes", crew: 0), ChatDemoDocument(title: "QA failure log", crew: 1),
                        ChatDemoDocument(title: "Export plan", crew: 3)],
            messages: [
                ChatDemoMessage(author: .firstMate, hour: 10, minute: 40, paragraphs: [
                    "Export flow finished the export flow. Device QA is running QA on iPhone and iPad now.",
                ]),
                ChatDemoMessage(author: .crew(1), hour: 11, minute: 16, paragraphs: [
                    "iPad run 2 of 2 failed. The export sheet never appears, so the UI test times out after 30 seconds. iPhone passes. Details are in the QA failure log.",
                ]),
                ChatDemoMessage(author: .firstMate, hour: 11, minute: 20, paragraphs: [
                    "I stopped QA instead of trying a third time. Both iPad runs failed the same way: the export sheet never appears, so the UI test times out after 30 seconds. iPhone passed every run.",
                    "The QA failure log points at the share sheet's anchor. On iPad a share sheet needs a source view, and the export button gives it none, so the sheet never presents. That fits both failures and explains why iPhone is fine.",
                    "There are two ways forward. Ship iPhone-only now and file the iPad bug, or investigate iPad first. Investigating is about 30 minutes, and the fix probably touches only the export button.",
                    "Ship iPhone-only and file the iPad bug, or investigate iPad first?",
                ], skim: ChatDemoSkim(
                    say: [.text("QA failed twice on iPad because "), .link("the share sheet has no anchor", paragraphs: [1]),
                          .text(", so I stopped. iPhone is fine.")],
                    ask: [.text("Ship iPhone-only, or "), .link("investigate iPad first", paragraphs: [2]), .text("?")],
                    replies: ["Ship iPhone-only", "Investigate iPad"]
                )),
            ]
        )
    }

    private static var releaseChecklist: ChatDemoFeature {
        let id = "demo-release"
        return ChatDemoFeature(
            id: id, title: "Release checklist refresh", label: "Release checklist", emoji: "📋",
            goal: "Make the release checklist shorter and put the approval step where people see it.",
            status: "awaiting_direction", hud: .turn, step: 2, fraction: 0.62,
            now: "Review is done. It needs your call on where the approval checkpoint shows.",
            unread: true,
            crew: [
                ChatDemoCrew(title: "Outline review", role: "Planner", status: "completed", note: "Split the checklist into three sections"),
                ChatDemoCrew(title: "Checklist prototype", role: "Designer", status: "completed", note: "Kept the approval point between verify and handoff"),
                ChatDemoCrew(title: "Usability pass", role: "Reviewer", status: "awaiting_direction", note: "Moved the decision into its own step"),
            ],
            documents: [ChatDemoDocument(title: "Checklist outline", crew: 0), ChatDemoDocument(title: "Review summary", crew: 2),
                        ChatDemoDocument(title: "Prototype notes", crew: 1)],
            messages: [
                ChatDemoMessage(author: .firstMate, hour: 11, minute: 28, paragraphs: [
                    "I split the checklist into three sections: prepare, verify and handoff. Checklist prototype kept the approval point between verify and handoff.",
                ]),
                ChatDemoMessage(author: .user, hour: 11, minute: 31, paragraphs: [
                    "Can \(mention("Usability pass", feature: id, crew: 2)) make the review step obvious without making everything else loud?",
                ]),
                ChatDemoMessage(author: .firstMate, hour: 11, minute: 37, paragraphs: [
                    "Yes. Usability pass moved the decision into its own step and left notes for you in the Review summary.",
                ]),
                ChatDemoMessage(author: .firstMate, hour: 11, minute: 42, paragraphs: [
                    "One call for you: should the approval checkpoint show in the conversation, or only in the inspector? Nothing moves until you decide.",
                ], skim: ChatDemoSkim(
                    say: [.text("One call for you: "), .link("where the approval checkpoint shows", paragraphs: [0]), .text(".")],
                    ask: [.text("In the conversation, or only in the inspector?")],
                    replies: ["In the conversation", "Inspector only"]
                )),
            ]
        )
    }

    private static var reviewSearch: ChatDemoFeature {
        ChatDemoFeature(
            id: "demo-search", title: "Review search", label: "Review search", emoji: "🔍",
            goal: "Find a review document, its agent, and its workflow step from one search.",
            status: "awaiting_direction", hud: .ready, step: 4, fraction: 0.6,
            now: "PR #214 passed CI and all seven reviewers. It needs your approval.",
            unread: true, revision: 2,
            crew: [
                ChatDemoCrew(title: "Search index", role: "Builder", status: "completed", note: "Built the index and its query parser"),
                ChatDemoCrew(title: "Seven reviewers", role: "Reviewer", status: "completed", note: "All seven reviewers passed revision 2"),
                ChatDemoCrew(title: "CI watch", role: "Tester", status: "completed", note: "CI passed on the final run"),
            ],
            documents: [ChatDemoDocument(title: "Review roll-up", crew: 1), ChatDemoDocument(title: "PR #214 summary", crew: 2)],
            pullRequest: (214, "open"),
            messages: [
                ChatDemoMessage(author: .user, hour: 9, minute: 40, paragraphs: ["How close is search?"]),
                ChatDemoMessage(author: .firstMate, hour: 9, minute: 44, paragraphs: [
                    "PR #214 is open, and all seven reviewers passed. CI watch is watching CI.",
                ]),
                ChatDemoMessage(author: .firstMate, hour: 11, minute: 4, paragraphs: [
                    "CI passed on the final run, and all seven reviewers signed off on revision 2.",
                    "One note before you merge: the first launch after updating rebuilds the search index. On the sample library that takes about 2 seconds, and search shows a quiet progress line while it runs. Later launches reuse the index.",
                    "The PR #214 summary has the reviewer roll-up and the CI timings.",
                ], skim: ChatDemoSkim(
                    say: [.text("CI passed and "), .link("all seven reviewers signed off", paragraphs: [0]),
                          .text(". The first launch "), .link("rebuilds the index for about 2 seconds", paragraphs: [1]), .text(".")]
                )),
                ChatDemoMessage(author: .firstMate, hour: 11, minute: 5, paragraphs: ["Approve and merge, or open the PR first?"],
                                skim: ChatDemoSkim(
                                    say: [.text("Ready to merge.")],
                                    ask: [.link("Approve and merge, or open the PR first?", paragraphs: [0])],
                                    replies: ["Approve and merge", "Open the PR"]
                                )),
            ]
        )
    }

    private static var quietNotifications: ChatDemoFeature {
        let id = "demo-quiet"
        return ChatDemoFeature(
            id: id, title: "Quiet notifications", label: "Quiet notifications", emoji: "🔕",
            goal: "Keep urgent requests visible while routine updates stay quiet.",
            status: "running", hud: .working, step: 1, fraction: 0.55,
            now: "Sketching quieter defaults. Interaction checks start next.",
            unread: false,
            crew: [
                ChatDemoCrew(title: "Notification audit", role: "Researcher", status: "completed", note: "Sorted every notification into three kinds"),
                ChatDemoCrew(title: "Preference controls", role: "Designer", status: "running", note: "Keeping the settings small and easy to undo"),
                ChatDemoCrew(title: "Interaction checks", role: "Tester", status: "queued", note: "Starts when the sketch is ready"),
            ],
            documents: [ChatDemoDocument(title: "Notification inventory", crew: 0), ChatDemoDocument(title: "Quiet mode sketch", crew: 1)],
            messages: [
                ChatDemoMessage(author: .user, hour: 9, minute: 52, paragraphs: [
                    "Keep urgent requests visible. Can \(mention("Preference controls", feature: id, crew: 1)) explore quieter defaults with \(mention("Interaction checks", feature: id, crew: 2))?",
                ]),
                ChatDemoMessage(author: .firstMate, hour: 10, minute: 2, paragraphs: [
                    "Yes. I’m splitting updates into routine, important and decision-needed. Routine ones stay in the journal.",
                ]),
                ChatDemoMessage(author: .firstMate, hour: 10, minute: 18, paragraphs: [
                    "The first draft is ready to look at in the Quiet mode sketch. Preference controls kept the settings small and easy to undo, and Interaction checks starts interaction checks next.",
                ]),
            ]
        )
    }

    private static var offlineSync: ChatDemoFeature {
        ChatDemoFeature(
            id: "demo-offline", title: "Offline sync", label: "Offline sync", emoji: "📦",
            goal: "Edits made offline merge cleanly when the device reconnects.",
            status: "running", hud: .working, step: 2, fraction: 0.55,
            now: "Seven reviewers are checking revision 3. Four have reported, all passing.",
            unread: false, revision: 3,
            crew: [
                ChatDemoCrew(title: "Sync engine", role: "Builder", status: "completed", note: "Finished revision 3 of the merge rules"),
                ChatDemoCrew(title: "Conflict review", role: "Reviewer", status: "running", note: "Four of seven reviewers have reported"),
                ChatDemoCrew(title: "Edge cases", role: "Tester", status: "queued", note: "Starts after review"),
            ],
            documents: [ChatDemoDocument(title: "Merge rules", crew: 0)],
            pullRequest: (221, "draft"),
            messages: [
                ChatDemoMessage(author: .user, hour: 9, minute: 31, paragraphs: ["Ping me if any reviewer fails."]),
                ChatDemoMessage(author: .firstMate, hour: 9, minute: 58, paragraphs: [
                    "Will do. Sync engine finished revision 3, and Conflict review has seven reviewers on it. Four have reported so far, all passing.",
                ]),
            ]
        )
    }

    private static var homeWidgets: ChatDemoFeature {
        ChatDemoFeature(
            id: "demo-widgets", title: "Home screen widgets", label: "Home screen widgets", emoji: "🧩",
            goal: "Small and medium home screen widgets for the day's receipts.",
            status: "ready", hud: .idle, step: 0, fraction: 0,
            now: "Waiting for Offline sync to merge, since both touch the data store.",
            unread: false,
            crew: [ChatDemoCrew(title: "Widget plan", role: "Planner", status: "queued", note: "Waiting for Offline sync to merge")],
            messages: [
                ChatDemoMessage(author: .user, daysAgo: 1, hour: 17, minute: 32, paragraphs: [
                    "Let’s do home screen widgets next. Small and medium only.",
                ]),
                ChatDemoMessage(author: .firstMate, daysAgo: 1, hour: 17, minute: 40, paragraphs: [
                    "Noted. I’ll plan small and medium widgets once Offline sync merges, since both touch the data store.",
                ]),
            ]
        )
    }

    private static var launchPolish: ChatDemoFeature {
        let id = "demo-launch"
        return ChatDemoFeature(
            id: id, title: "Workspace launch polish", label: "Workspace launch polish", emoji: "🚀",
            goal: "Make the first workspace obvious, even without a project.",
            status: "completed", hud: .done, step: 5, fraction: 1,
            now: "Merged. The layout notes and validation summary are saved.",
            unread: false,
            crew: [
                ChatDemoCrew(title: "Flow outline", role: "Planner", status: "completed", note: "Outlined the first-run flow"),
                ChatDemoCrew(title: "Welcome layout", role: "Designer", status: "completed", note: "Drew a quiet empty state"),
                ChatDemoCrew(title: "Navigation check", role: "Reviewer", status: "completed", note: "Checked the navigation"),
            ],
            documents: [ChatDemoDocument(title: "Welcome layout notes", crew: 1), ChatDemoDocument(title: "Validation summary", crew: 2)],
            pullRequest: (198, "merged"),
            messages: [
                ChatDemoMessage(author: .user, daysAgo: 1, hour: 16, minute: 5, paragraphs: [
                    "Could \(mention("Welcome layout", feature: id, crew: 1)) make the first workspace obvious, even without a project?",
                ]),
                ChatDemoMessage(author: .firstMate, daysAgo: 1, hour: 16, minute: 13, paragraphs: [
                    "Welcome layout drew a quiet empty state with one Create workspace button, and Navigation check checked the navigation.",
                ]),
                ChatDemoMessage(author: .firstMate, daysAgo: 1, hour: 16, minute: 22, paragraphs: [
                    "Done and merged. The layout notes and the Validation summary are saved.",
                ]),
            ]
        )
    }
}
