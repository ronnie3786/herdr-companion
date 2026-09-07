import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD session chips")
struct HerdrHudSessionChipsTests {
    @Test("Chat name, activity, emoji and status stay independent through decoding and privacy")
    func sessionIdentity() throws {
        let data = Data(#"{"pane_id":"p1","workspace_id":"w1","tab_id":"t1","agent_status":"working","title":"Upload bug investigation","session_title":"Fix image uploads","session_activity":"Inspecting UploadManager.swift","session_emoji":"📷","pi_semantic":{"available":true,"protocol_version":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(HerdrPane.self, from: data)
        let roundTrip = try JSONDecoder().decode(HerdrPane.self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip.sessionTitle == "Fix image uploads")
        #expect(roundTrip.sessionActivity == "Inspecting UploadManager.swift")
        #expect(roundTrip.sessionEmoji == "📷")
        let panes = [decoded.stamped(machineID: "m1")]
        let visible = HerdrHudSessionChips.chips(panes: panes, mutedPaneIDs: [], dismissed: [:], revealTitles: true)
        #expect(visible.chips.first?.title == "Upload bug investigation")
        #expect(visible.chips.first?.activity == "Inspecting UploadManager.swift")
        #expect(visible.chips.first?.emoji == "📷")
        #expect(visible.chips.first?.statusLabel == "Running")
        #expect(visible.chips.first?.statusSymbol == "bolt.circle.fill")
        let privateState = HerdrHudSessionChips.chips(panes: panes, mutedPaneIDs: [], dismissed: [:], revealTitles: false)
        #expect(privateState.chips.first?.title == "session 1")
        #expect(privateState.chips.first?.activity == "Activity hidden")
        #expect(privateState.chips.first?.emoji == "💬")
        #expect(privateState.chips.first?.statusLabel == "Running")
    }

    @Test("Missing or blank activity falls back to the topic without replacing the chat name")
    func activityFallbacks() throws {
        let topicPane = try pane(id: "p1", status: .working, title: "Actual chat", sessionTitle: "Fix uploads", sessionActivity: "  ")
        #expect(HerdrHudSessionChips.activity(for: topicPane) == "Fix uploads")
        let noDetails = try pane(id: "p2", status: .working, sessionTitle: " ", sessionActivity: "\n")
        #expect(HerdrHudSessionChips.activity(for: noDetails) == "Activity details unavailable")
        let legacy = try pane(id: "p3", status: .working, title: "Legacy chat")
        #expect(legacy.sessionActivity == nil)
        #expect(HerdrHudSessionChips.activity(for: legacy) == "Activity details unavailable")
    }

    @Test("A finished session never claims its previous action is still running")
    func staleActivityStopsAtCompletion() throws {
        let done = try pane(id: "p1", status: .done, title: "Actual chat", sessionTitle: "Fix uploads", sessionActivity: "Running tests")
        let projection = HerdrHudSessionChips.chips(panes: [done], mutedPaneIDs: [], dismissed: [:], revealTitles: true)
        #expect(projection.chips.first?.title == "Actual chat")
        #expect(projection.chips.first?.activity == "Fix uploads")
        #expect(projection.chips.first?.statusLabel == "Finished")
        #expect(projection.chips.first?.statusSymbol == "checkmark.circle.fill")
    }

    @Test("Activity changes invalidate pane projections even when the revision is unchanged")
    func activityParticipatesInPaneEquality() throws {
        let before = try pane(id: "p1", status: .working, sessionActivity: "Reading files")
        let after = try pane(id: "p1", status: .working, sessionActivity: "Running tests")
        #expect(!before.isEqualIgnoringRevision(to: after))
    }

    @Test("Working chip glow is static, so collapsed HUD chips do not animate")
    func chipMotionPolicy() {
        #expect(HerdrHudChipMotion.showsStaticGlow(for: .working))
        #expect(!HerdrHudChipMotion.showsStaticGlow(for: .blocked))
        #expect(!HerdrHudChipMotion.showsStaticGlow(for: .done))
        #expect(HerdrHudChipMotion.workingGlowOpacity > 0)
        #expect(HerdrHudChipMotion.workingGlowOpacity < 1)
    }

    @Test("Only blocked, done, and working Pi sessions qualify")
    func filtersStatusesAndNonPiPanes() throws {
        let result = HerdrHudSessionChips.chips(
            panes: [
                try pane(id: "blocked", status: .blocked),
                try pane(id: "done", status: .done),
                try pane(id: "working", status: .working),
                try pane(id: "idle", status: .idle),
                try pane(id: "unknown", status: .unknown),
                try pane(id: "shell", status: .working, piCapable: false),
            ],
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            limit: 10
        )

        #expect(Set(result.chips.map(\.id)) == ["m1|blocked", "m1|done", "m1|working"])
    }

    @Test("Chips sort by attention rank, activity, revision, then id")
    func sortsDeterministically() throws {
        let newer = Date(timeIntervalSince1970: 200)
        let older = Date(timeIntervalSince1970: 100)
        let result = HerdrHudSessionChips.chips(
            panes: [
                try pane(id: "working", status: .working, revision: 1, workingSince: newer),
                try pane(id: "done-older", status: .done, revision: 99, lastActivityAt: older),
                try pane(id: "blocked-low", status: .blocked, revision: 1, lastActivityAt: newer),
                try pane(id: "blocked-high", status: .blocked, revision: 3, lastActivityAt: newer),
                try pane(id: "blocked-id-a", status: .blocked, revision: 3, lastActivityAt: newer),
                try pane(id: "done-newer", status: .done, revision: 1, lastActivityAt: newer),
            ],
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            limit: 10
        )

        #expect(result.chips.map(\.id) == [
            "m1|blocked-high",
            "m1|blocked-id-a",
            "m1|blocked-low",
            "m1|done-newer",
            "m1|done-older",
            "m1|working",
        ])
    }

    @Test("Dismissal suppresses only the matching current status")
    func dismissalIsStatusScoped() throws {
        let done = try pane(id: "transition", status: .done)
        let working = try pane(id: "transition", status: .working)
        let dismissed = [done.id: dismissal(done)]

        #expect(
            HerdrHudSessionChips.chips(
                panes: [done], mutedPaneIDs: [], dismissed: dismissed, revealTitles: true
            ).chips.isEmpty
        )
        #expect(
            HerdrHudSessionChips.chips(
                panes: [working], mutedPaneIDs: [], dismissed: dismissed, revealTitles: true
            ).chips.map(\.id) == [working.id]
        )
    }

    @Test("Mute hides progress states but keeps blocked sessions visible")
    func muteIsStatusScopedAndBlockedRemainsReversible() throws {
        let working = try pane(id: "working", status: .working)
        let done = try pane(id: "done", status: .done)
        let blocked = try pane(id: "blocked", status: .blocked)
        let result = HerdrHudSessionChips.chips(
            panes: [working, done, blocked],
            mutedPaneIDs: [working.id, done.id, blocked.id],
            dismissed: [:],
            revealTitles: true
        )

        #expect(result.chips.map(\.id) == [blocked.id])
        #expect(result.chips.first?.isMuted == true)
    }

    @Test("Redaction hides titles without redacting the routable pane id")
    func redactsOnlyDisplayTitle() throws {
        let pane = try pane(id: "secret-work", status: .working, title: "Confidential launch plan")
        let result = HerdrHudSessionChips.chips(
            panes: [pane], mutedPaneIDs: [], dismissed: [:], revealTitles: false
        )
        let chip = try #require(result.chips.first)

        #expect(chip.title == "session 1")
        #expect(!chip.title.localizedCaseInsensitiveContains("confidential"))
        #expect(chip.id == "m1|secret-work")
    }

    @Test("Limit caps chips and returns the exact remainder as overflow")
    func reportsOverflow() throws {
        let panes = try (1...5).map { index in
            try pane(id: "pane-\(index)", status: .working, revision: index)
        }
        let result = HerdrHudSessionChips.chips(
            panes: panes, mutedPaneIDs: [], dismissed: [:], revealTitles: true, limit: 2
        )

        #expect(result.chips.count == 2)
        #expect(result.overflow == 3)
    }

    /// What the `+N` control does: the same projection at the expanded limit
    /// returns every candidate and nothing left over.
    @Test("The expanded limit reveals every grouped session")
    func expandedLimitRevealsGroupedSessions() throws {
        let panes = try (1...5).map { index in
            try pane(id: "pane-\(index)", status: .working, revision: index)
        }
        let grouped = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            limit: HerdrHudPlacement.maxChips
        )
        let revealed = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            limit: HerdrHudPlacement.maxExpandedChips
        )

        #expect(grouped.chips.count == HerdrHudPlacement.maxChips)
        #expect(grouped.overflow == panes.count - HerdrHudPlacement.maxChips)
        #expect(revealed.chips.count == panes.count)
        #expect(revealed.overflow == 0)
        #expect(revealed.chips.prefix(grouped.chips.count).map(\.id) == grouped.chips.map(\.id))
    }

    @Test("A dismissed chip returns once its agent finishes again")
    func dismissalSilencesOneEpisodeNotTheStatus() throws {
        let working = try pane(id: "a", status: .working)
        let done = try pane(id: "a", status: .done)

        // The user clicked the chip while the agent was finished, which both
        // opens the pane and dismisses the chip.
        var dismissed: [String: HudChipDismissal] = ["m1|a": dismissal(done)]
        #expect(HerdrHudSessionChips.chips(
            panes: [done],
            mutedPaneIDs: [],
            dismissed: dismissed,
            revealTitles: true
        ).chips.isEmpty)

        // The agent picks the work back up: the dismissal no longer applies.
        dismissed = HerdrHudSessionChips.prunedDismissals(dismissed, machineID: "m1", panes: [working])
        #expect(dismissed.isEmpty)

        // ...and when it finishes again the chip is back, which is the bug that
        // had completed agents disappearing from the HUD one session at a time.
        dismissed = HerdrHudSessionChips.prunedDismissals(dismissed, machineID: "m1", panes: [done])
        #expect(HerdrHudSessionChips.chips(
            panes: [done],
            mutedPaneIDs: [],
            dismissed: dismissed,
            revealTitles: true
        ).chips.map(\.id) == ["m1|a"])
    }

    @Test("A dismissal survives while its pane stays in the dismissed status")
    func dismissalSurvivesUnchangedStatus() throws {
        let done = try pane(id: "a", status: .done)
        let pruned = HerdrHudSessionChips.prunedDismissals(
            ["m1|a": dismissal(done)],
            machineID: "m1",
            panes: [done]
        )
        #expect(pruned == ["m1|a": dismissal(done)])
    }

    @Test("Pruning drops vanished panes but never another machine's dismissals")
    func pruningIsScopedToTheRefreshedMachine() throws {
        let gone = try pane(id: "gone", status: .done)
        let other = HudChipDismissal(status: .done, episode: "1", dismissedAt: Self.stamp)
        let pruned = HerdrHudSessionChips.prunedDismissals(
            ["m1|gone": dismissal(gone), "m2|other": other],
            machineID: "m1",
            panes: []
        )
        #expect(pruned == ["m2|other": other])
    }

    @Test("A silenced session does not move its result onto the orb")
    func unviewedResultDocksToOrbWhenItsChipIsSilenced() throws {
        let idle = try pane(id: "finished", status: .idle)
        let resultArtifact = artifact(id: "artifact-1", originID: "finished")

        let result = HerdrHudSessionChips.chips(
            panes: [idle],
            mutedPaneIDs: [idle.id],
            dismissed: [idle.id: dismissal(idle)],
            revealTitles: true,
            artifacts: [resultArtifact]
        )

        #expect(result.chips.isEmpty)
        #expect(result.detachedArtifacts.isEmpty)
    }

    /// The exact user-reported repro: a finished session that produced a result,
    /// clicked once, must stay gone.
    @Test("A dismissed chip with an unopened result stays dismissed")
    func dismissedChipWithResultStaysDismissed() throws {
        let done = try pane(id: "finished", status: .done)
        let resultArtifact = artifact(id: "artifact-1", originID: "finished")

        let result = HerdrHudSessionChips.chips(
            panes: [done],
            mutedPaneIDs: [],
            dismissed: [done.id: dismissal(done)],
            revealTitles: true,
            artifacts: [resultArtifact]
        )

        #expect(result.chips.isEmpty)
        #expect(result.detachedArtifacts.isEmpty)
    }

    @Test("Muting a session keeps its result off the orb")
    func mutedSessionWithResultShowsNoChip() throws {
        let done = try pane(id: "finished", status: .done)
        let resultArtifact = artifact(id: "artifact-1", originID: "finished")

        let result = HerdrHudSessionChips.chips(
            panes: [done],
            mutedPaneIDs: [done.id],
            dismissed: [:],
            revealTitles: true,
            artifacts: [resultArtifact]
        )

        #expect(result.chips.isEmpty)
        #expect(result.detachedArtifacts.isEmpty)
    }

    /// The episode-not-status guarantee, and what makes persisting a dismissal
    /// safe: a pane reads `.done` both before AND after it answers again, so a
    /// restored dismissal must not silence tomorrow's answer.
    @Test("A new answer at the same status brings the chip back")
    func newAnswerAtSameStatusReturnsTheChip() throws {
        let first = try pane(id: "a", status: .done, lastActivityAt: Date(timeIntervalSince1970: 100))
        let answeredAgain = try pane(id: "a", status: .done, lastActivityAt: Date(timeIntervalSince1970: 500))
        let dismissed = [first.id: dismissal(first)]

        #expect(HerdrHudSessionChips.chips(
            panes: [first], mutedPaneIDs: [], dismissed: dismissed, revealTitles: true
        ).chips.isEmpty)

        #expect(HerdrHudSessionChips.chips(
            panes: [answeredAgain], mutedPaneIDs: [], dismissed: dismissed, revealTitles: true
        ).chips.map(\.id) == ["m1|a"])

        // ...and the prune agrees, so a restored map cannot silence it either.
        #expect(HerdrHudSessionChips.prunedDismissals(
            dismissed, machineID: "m1", panes: [answeredAgain]
        ).isEmpty)
    }

    /// `.blocked` never self-heals through the server's ack projection the way
    /// `.done` does, so its dismissal has to survive every refresh — otherwise
    /// nothing the user can do ever quiets a stuck session.
    @Test("A blocked session stays dismissed across repeated pruning")
    func blockedPaneStaysDismissedAcrossPrune() throws {
        let blocked = try pane(id: "stuck", status: .blocked, lastActivityAt: Date(timeIntervalSince1970: 10))
        var dismissed = [blocked.id: dismissal(blocked)]

        for _ in 0..<5 {
            dismissed = HerdrHudSessionChips.prunedDismissals(dismissed, machineID: "m1", panes: [blocked])
        }

        #expect(dismissed == [blocked.id: dismissal(blocked)])
        #expect(HerdrHudSessionChips.chips(
            panes: [blocked], mutedPaneIDs: [], dismissed: dismissed, revealTitles: true
        ).chips.isEmpty)
    }

    @Test("The persisted dismissal store is capped newest-first")
    func cappedKeepsNewestDismissals() {
        let dismissals = (1...10).reduce(into: [String: HudChipDismissal]()) { store, index in
            store["m1|pane-\(index)"] = HudChipDismissal(
                status: .done,
                episode: "\(index)",
                dismissedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let capped = HerdrHudSessionChips.capped(dismissals, limit: 3)

        #expect(capped.count == 3)
        #expect(Set(capped.keys) == ["m1|pane-8", "m1|pane-9", "m1|pane-10"])
        #expect(HerdrHudSessionChips.capped(dismissals, limit: 50) == dismissals)
    }

    @Test("Only headless outputs belong to the HUD orb")
    func detachedResultsDockToOrb() throws {
        let livePane = try pane(id: "live", status: .done)
        let headless = artifact(
            id: "run-result",
            originType: .agentRun,
            originID: "run-1"
        )
        let vanished = artifact(id: "pane-result", originID: "gone")

        let result = HerdrHudSessionChips.chips(
            panes: [livePane],
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            artifacts: [headless, vanished]
        )

        #expect(Set(result.detachedArtifacts.map(\.id)) == [headless.id])
    }

    @Test("An overflowed result stays associated with its session")
    func overflowedResultRemainsVisible() throws {
        let panes = try (1...4).map { index in
            try pane(id: "blocked-\(index)", status: .blocked, revision: index)
        }
        let overflowed = artifact(id: "overflowed", originID: "blocked-1")

        let grouped = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            artifacts: [overflowed],
            limit: 3
        )
        let revealed = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissed: [:],
            revealTitles: true,
            artifacts: [overflowed],
            limit: 4
        )

        #expect(grouped.detachedArtifacts.isEmpty)
        #expect(grouped.overflow == 1)
        #expect(revealed.detachedArtifacts.isEmpty)
        #expect(revealed.chips.last?.artifacts.map(\.id) == [overflowed.id])
    }

    @Test("Unread documents keep an idle session in the HUD until read")
    func idleSessionWithUnreadDocuments() throws {
        let idle = try pane(id: "finished", status: .idle)
        let output = artifact(id: "output", originID: "finished")
        let visible = HerdrHudSessionChips.chips(
            panes: [idle], mutedPaneIDs: [], dismissed: [:], revealTitles: true, artifacts: [output]
        )
        #expect(visible.chips.first?.artifacts == [output])
        #expect(visible.detachedArtifacts.isEmpty)
        #expect(HerdrHudSessionChips.chips(
            panes: [idle], mutedPaneIDs: [], dismissed: [:], revealTitles: true, artifacts: []
        ).chips.isEmpty)
    }

    @Test("Promoted session documents follow the same ownership as Chat")
    func promotedSessionDocuments() throws {
        let current = try pane(id: "new-pane", status: .done, sessionID: "session-current")
        let promoted = artifact(id: "promoted", originType: .agentRun, originID: "old-run", sessionID: "session-current")
        let moved = artifact(id: "moved", originID: "old-pane", sessionID: "session-current")
        let stale = artifact(id: "stale", originID: "new-pane", sessionID: "previous-session")
        let otherMachine = promoted.stamped(machineID: "m2")
        let result = HerdrHudSessionChips.chips(
            panes: [current], mutedPaneIDs: [], dismissed: [:], revealTitles: true,
            artifacts: [promoted, moved, stale, otherMachine]
        )
        #expect(Set(result.chips.first?.artifacts.map(\.id) ?? []) == [promoted.id, moved.id])
        #expect(result.detachedArtifacts == [otherMachine])
        let dismissed = HerdrHudSessionChips.chips(
            panes: [current], mutedPaneIDs: [], dismissed: [current.id: dismissal(current)], revealTitles: true,
            artifacts: [promoted, moved]
        )
        #expect(dismissed.chips.isEmpty)
        #expect(dismissed.detachedArtifacts.isEmpty)
    }

    private static let stamp = Date(timeIntervalSince1970: 0)

    /// A dismissal recorded for `pane` exactly as it stands, which is what
    /// `HerdrAppModel.dismissHudChip` writes.
    private func dismissal(_ pane: HerdrPane) -> HudChipDismissal {
        HudChipDismissal(pane: pane, dismissedAt: Self.stamp)
    }

    private func pane(
        id: String,
        status: AgentStatus,
        revision: Int = 1,
        title: String? = nil,
        piCapable: Bool = true,
        lastActivityAt: Date? = nil,
        workingSince: Date? = nil,
        sessionTitle: String? = nil,
        sessionActivity: String? = nil,
        sessionID: String? = nil
    ) throws -> HerdrPane {
        var payload: [String: Any] = [
            "pane_id": id,
            "workspace_id": "w1",
            "tab_id": "t1",
            "agent_status": status.rawValue,
            "revision": revision,
        ]
        if let title { payload["title"] = title }
        payload["session_title"] = sessionTitle
        payload["session_activity"] = sessionActivity
        if piCapable {
            var semantic: [String: Any] = ["available": true, "protocol_version": 1]
            semantic["session_id"] = sessionID
            payload["pi_semantic"] = semantic
        }
        if let lastActivityAt {
            payload["last_activity_at"] = HerdrTimestamp.string(from: lastActivityAt)
        }
        if let workingSince {
            payload["working_since"] = HerdrTimestamp.string(from: workingSince)
        }
        return try JSONDecoder().decode(
            HerdrPane.self,
            from: try JSONSerialization.data(withJSONObject: payload)
        )
        .stamped(machineID: "m1")
    }

    private func artifact(
        id: String,
        originType: AgentResultArtifact.OriginType = .pane,
        originID: String,
        sessionID: String? = nil
    ) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id,
            originType: originType,
            originID: originID,
            sessionID: sessionID,
            kind: .file,
            title: "Result \(id)",
            filename: "result.pdf",
            contentType: "application/pdf",
            byteSize: 42,
            createdAt: HerdrTimestamp.string(from: .now),
            downloadPath: "/api/v1/result-artifacts/\(id)/content"
        )
        .stamped(machineID: "m1")
    }
}
