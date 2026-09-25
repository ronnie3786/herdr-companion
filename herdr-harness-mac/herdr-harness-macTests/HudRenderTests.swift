import Foundation
import SwiftUI
import Testing
import Vision
@testable import herdr_harness_mac

@Suite("Herdr HUD renders", .serialized)
@MainActor
struct HudRenderTests {
    @Test("HUD card renders completed transcript rows")
    func rendersHudCard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "hud-fleet-status",
                machineID: "demo1",
                prompt: "What is the current status of the demo fleet?",
                sentPrompt: "What is the current status of the demo fleet?",
                response: "The fleet is healthy. Two alerts need attention, and one pane is waiting for review.",
                error: nil,
                status: .completed,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            ),
            HerdrHudExchange(
                id: "hud-resolve-alert",
                machineID: "demo1",
                prompt: "Resolve the stale attention alert and summarize the change.",
                sentPrompt: "Resolve the stale attention alert and summarize the change.",
                response: "Resolved the stale alert, refreshed its status, and left the active pane open for review.",
                error: nil,
                status: .completed,
                costUSD: 0.0042,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: ["alert-screenshot.png"]
            ),
        ])

        let result = try await HerdrRenderHarness.render(
            "15-hud-card.png",
            size: CGSize(width: 420, height: 580)
        ) {
            HerdrHudCardView(
                model: model,
                controller: HerdrHudController(),
                session: session
            )
        }

        result.expectSubstantial()
    }

    @Test("HUD orb renders unread-alert status without a visual count")
    func rendersHudOrb() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        #expect(model.unreadAlertCount > 0)

        let result = try await HerdrRenderHarness.render(
            "16-hud-orb.png",
            size: CGSize(width: 100, height: 100)
        ) {
            HerdrHudOrbView(
                model: model,
                controller: HerdrHudController(),
                session: session
            )
            .frame(width: 100, height: 100)
        }

        result.expectSubstantial()
    }

    @Test("Ultra-compact HUD renders its restrained 20-point signal centered in the collapsed lane")
    func rendersUltraCompactIndicator() async throws {
        let result = try await HerdrRenderHarness.render(
            "29-hud-ultra-compact.png",
            size: HerdrHudPlacement.ultraCompactContentSize
        ) {
            HerdrHudUltraCompactIndicator(
                controller: HerdrHudController(),
                tone: .finished
            )
        }

        result.expectSubstantial(minimumBytes: 500)
    }

    @Test("HUD session chips render in the collapsed strip")
    func rendersHudSessionChips() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        let chips = [
            HerdrHudSessionChips.Chip(
                id: "demo1|w1:p1",
                title: "Herdr Mac",
                status: .working,
                isMuted: false,
                since: .now,
                emoji: "🧪",
                activity: "Running UI tests"
            ),
            HerdrHudSessionChips.Chip(
                id: "demo2|w2:p1",
                title: "Launch report",
                status: .done,
                isMuted: false,
                since: .now,
                emoji: "📄",
                activity: "Release documents"
            ),
        ]

        let result = try await HerdrRenderHarness.render(
            "17-hud-session-chips.png",
            size: HerdrHudPlacement.collapsedContentSize(chipCount: 2)
        ) {
            HerdrHudSessionChipsView(
                model: model,
                session: session,
                chips: chips,
                overflow: 0
            )
        }

        result.expectSubstantial()
    }

    @Test("Session bubbles keep chat name, emoji activity, and status on three distinct lines", arguments: [HerdrFontScale.medium, .xxxLarge])
    func rendersThreeSessionLabels(fontScale: HerdrFontScale) async throws {
        let chips: [HerdrHudSessionChips.Chip] = [
            .init(id: "running", title: "Herdr Mac", status: .working, isMuted: false, since: .now,
                  emoji: "🧪", activity: "Running UI tests"),
            .init(id: "finished", title: "Launch report", status: .done, isMuted: false, since: .now,
                  emoji: "📄", activity: "Release documents"),
            .init(id: "blocked", title: "Slack follow-up", status: .blocked, isMuted: false, since: .now,
                  emoji: "💬", activity: "Investigating sign-in"),
        ]
        let result = try await HerdrRenderHarness.render(
            "28-hud-session-three-labels-\(fontScale.label).png",
            size: CGSize(width: HerdrHudPlacement.chipWidth + 24, height: fontScale == .medium ? 224 : 320)
        ) {
            VStack(spacing: 8) {
                ForEach(chips) { chip in
                    HerdrHudSessionBubbleLabel(chip: chip)
                }
            }
            .padding(12)
            .environment(\.herdrFontScale, fontScale)
        }
        result.expectSubstantial(minimumBytes: 3_000)
    }

    @Test("HUD result artifacts render as a luminous dock beside their session")
    func rendersHudResultArtifacts() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        let artifacts = [
            renderArtifact(id: "report", filename: "launch-report.pdf", contentType: "application/pdf"),
            renderArtifact(id: "prototype", filename: "agent-console.html", contentType: "text/html"),
            renderArtifact(id: "demo", filename: "workflow-demo.mp4", contentType: "video/mp4"),
            renderArtifact(id: "source", filename: "ResultPipeline.swift", contentType: "text/x-swift"),
        ]
        let chip = HerdrHudSessionChips.Chip(
            id: "demo1|w1:p1",
            title: "Finished agent",
            status: .done,
            isMuted: false,
            since: .now,
            artifacts: artifacts
        )

        let result = try await HerdrRenderHarness.render(
            "21-hud-result-artifacts.png",
            size: CGSize(
                width: HerdrHudPlacement.resultRailWidth + HerdrHudPlacement.chipWidth,
                height: 64
            )
        ) {
            HerdrHudSessionChipsView(
                model: model,
                session: session,
                chips: [chip],
                overflow: 0
            )
        }

        result.expectSubstantial(minimumBytes: 2_000)
    }

    @Test("Hovering the HUD renders every session attachment title together")
    func rendersExpandedSessionAttachmentTitles() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(userDefaults: makeDefaults(), persistenceURL: temporaryPersistenceURL())
        let chip = HerdrHudSessionChips.Chip(
            id: "demo1|w1:p1",
            title: "Launch report",
            status: .done,
            isMuted: false,
            since: .now,
            artifacts: [
                renderArtifact(id: "hover-report", filename: "launch-report.pdf", contentType: "application/pdf"),
                renderArtifact(id: "hover-preview", filename: "agent-console.html", contentType: "text/html"),
                renderArtifact(id: "hover-video", filename: "workflow-demo.mp4", contentType: "video/mp4"),
            ],
            emoji: "📄",
            activity: "Release documents"
        )
        let result = try await HerdrRenderHarness.render(
            "27-hud-session-attachment-titles.png",
            size: CGSize(
                width: HerdrHudPlacement.resultRailWidth(artifactCount: 3, expandsTitles: true) + HerdrHudPlacement.chipWidth,
                height: 64
            )
        ) {
            HerdrHudSessionChipsView(
                model: model,
                session: session,
                chips: [chip],
                overflow: 0,
                expandsAttachmentTitles: true
            )
        }
        result.expectSubstantial(minimumBytes: 3_000)
    }

    @Test("Expanded HUD keeps completed Agent outputs visible")
    func rendersExpandedHudResultStrip() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "expanded-output",
                machineID: "demo1",
                prompt: "Build the launch package",
                sentPrompt: "Build the launch package",
                response: "The launch report, interactive preview, and walkthrough are ready.",
                error: nil,
                status: .completed,
                costUSD: 0.008,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            ),
        ])
        model.ingestResultArtifacts(
            [
                renderArtifact(id: "expanded-report", filename: "launch-report.pdf", contentType: "application/pdf"),
                renderArtifact(id: "expanded-preview", filename: "agent-console.html", contentType: "text/html"),
                renderArtifact(id: "expanded-video", filename: "walkthrough.mp4", contentType: "video/mp4"),
            ],
            machineID: "demo1",
            replacingMachineSlice: true
        )

        let result = try await HerdrRenderHarness.render(
            "22-hud-expanded-result-strip.png",
            size: HerdrHudPlacement.expandedSize
        ) {
            HerdrHudCardView(
                model: model,
                controller: HerdrHudController(),
                session: session
            )
        }

        result.expectSubstantial(minimumBytes: 10_000)
    }

    @Test("HUD note card renders actions and links")
    func rendersHudNoteCard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let agentSettings = AgentModelSettingsStore(defaults: makeDefaults())
        let promptSettings = HerdrPromptSettingsStore(defaults: makeDefaults())
        let notes = HerdrHudNotesState(
            userDefaults: makeDefaults(),
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: temporaryPersistenceURL(),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        await notes.waitForPersistenceRestoreForTesting()
        let id = UUID()
        let startedLink = HerdrNoteLink(
            id: UUID(),
            paneID: "w1:p1",
            machineID: "demo1",
            title: "Implementation session",
            createdAt: .now
        )
        let standaloneLink = HerdrNoteLink(
            id: UUID(),
            paneID: "w2:p1",
            machineID: "demo2",
            title: "Review session",
            createdAt: .now
        )
        var started = HerdrNoteAction(
            id: UUID(),
            title: "Open implementation session",
            prompt: "Continue the implementation",
            status: .started
        )
        started.linkID = startedLink.id
        let ready = HerdrNoteAction(
            id: UUID(),
            title: "Draft release notes",
            prompt: "Draft concise release notes",
            status: .ready
        )
        notes.seedNotesForTesting([
            HerdrNote(
                id: id,
                title: "HUD notes polish",
                body: "• Build the card\n• Check link handling\n• Verify animations\n• Capture the render",
                color: .lavender,
                aiSummary: "The note is ready to turn into focused sessions.",
                actions: [ready, started],
                links: [startedLink, standaloneLink]
            ),
        ])

        let result = try await HerdrRenderHarness.render(
            "18-hud-note-card.png",
            size: HerdrHudPlacement.noteCardSize
        ) {
            HerdrNoteCardView(model: model, controller: HerdrHudController(), notes: notes, noteID: id)
        }

        result.expectSubstantial()
    }

    @Test("HUD note rows render note signals")
    func rendersHudNoteRows() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let agentSettings = AgentModelSettingsStore(defaults: makeDefaults())
        let promptSettings = HerdrPromptSettingsStore(defaults: makeDefaults())
        let notes = HerdrHudNotesState(
            userDefaults: makeDefaults(),
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: temporaryPersistenceURL(),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        await notes.waitForPersistenceRestoreForTesting()
        let linked = HerdrNoteLink(
            id: UUID(), paneID: "w1:p1", machineID: "demo1", title: "Linked pane", createdAt: .now
        )
        let ready = HerdrNoteAction(id: UUID(), title: "Start a session", prompt: "Start", status: .ready)
        notes.seedNotesForTesting([
            HerdrNote(title: "Ready to ship", color: .yellow, actions: [ready]),
            HerdrNote(title: "Linked investigation", color: .green, links: [linked]),
            HerdrNote(title: "Quiet scratchpad", color: .blue),
        ])

        let result = try await HerdrRenderHarness.render(
            "19-hud-note-rows.png",
            size: CGSize(
                width: HerdrHudPlacement.notesWidth,
                height: HerdrHudPlacement.notesContentSize(.rows(count: 3), isExpanded: false).height
            )
        ) {
            HerdrNoteRowsView(model: model, controller: HerdrHudController(), notes: notes)
        }

        result.expectSubstantial()
    }

    @Test("HUD compact notes render color bars")
    func rendersHudCompactNotes() async throws {
        let agentSettings = AgentModelSettingsStore(defaults: makeDefaults())
        let promptSettings = HerdrPromptSettingsStore(defaults: makeDefaults())
        let notes = HerdrHudNotesState(
            userDefaults: makeDefaults(),
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: temporaryPersistenceURL(),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        await notes.waitForPersistenceRestoreForTesting()
        notes.seedNotesForTesting([
            HerdrNote(title: "Yellow", color: .yellow),
            HerdrNote(title: "Peach", color: .peach),
            HerdrNote(title: "Pink", color: .pink),
            HerdrNote(title: "Green", color: .green),
        ])

        let result = try await HerdrRenderHarness.render(
            "20-hud-note-compact.png",
            size: HerdrHudPlacement.notesContentSize(.compact(count: 4), isExpanded: false)
        ) {
            HerdrNoteCompactStackView(notes: notes, count: 4)
        }

        result.expectSubstantial(minimumBytes: 1024)
    }

    @Test("HUD composer renders a dropped image attachment with its thumbnail")
    func rendersComposerAfterImageDrop() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HudRenderTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(HerdrDropImageFixtures.makePNG(), forType: .png)
        #expect(session.acceptPasteboardDrop(pasteboard))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.pendingAttachments.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attachment = try #require(session.pendingAttachments.first)
        defer { session.removeAttachment(attachment.id) }

        let result = try await HerdrRenderHarness.render(
            "30-hud-composer-attachment.png",
            size: CGSize(width: 420, height: 320),
            settlePasses: 12,
            afterSettling: {
                // The chip loads its own thumbnail in a detached task.
                try? await Task.sleep(for: .milliseconds(120))
            }
        ) {
            HerdrHudComposerView(model: model, controller: HerdrHudController(), session: session)
        }
        result.expectSubstantial(minimumBytes: 3_000)
    }

    @Test("A fresh composer renders the main-workspace checkbox and picker at large text")
    func rendersFreshComposerMainWorkspaceToggle() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        session.applyLocalMachineDefaultIfNeeded(in: model)
        let workspace = HerdrWorkspace(
            workspaceID: "w-main",
            number: 1,
            label: "Main workspace",
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "w-main:t1",
            agentStatus: .idle
        )
        session.seedMainWorkspacesForTesting([workspace])
        #expect(session.selectMainWorkspace(workspace, in: model))
        session.createsInMainWorkspace = true
        session.draft = "Draft the release note"

        let result = try await HerdrRenderHarness.render(
            "30-hud-main-workspace-composer-xxxlarge.png",
            size: CGSize(width: 480, height: 320),
            settlePasses: 12
        ) {
            HerdrHudComposerView(model: model, controller: HerdrHudController(), session: session)
                .environment(\.herdrFontScale, .xxxLarge)
        }

        result.expectSubstantial(minimumBytes: 2_000)
        let text = try recognizedText(at: result.url).lowercased()
        #expect(session.isNewChat)
        #expect(text.contains("create in main workspace"))
        #expect(text.contains("main workspace"))
    }

    @Test("An existing conversation composer omits the checkbox even when its flag was left set")
    func rendersExistingComposerWithoutWorkspaceToggle() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "hud-existing-turn",
                machineID: "demo1",
                prompt: "Existing conversation",
                sentPrompt: "Existing conversation",
                response: "Already answered.",
                error: nil,
                status: .completed,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            ),
        ])
        session.createsInMainWorkspace = true

        let result = try await HerdrRenderHarness.render(
            "31-hud-existing-composer.png",
            size: CGSize(width: 480, height: 320),
            settlePasses: 12
        ) {
            HerdrHudComposerView(model: model, controller: HerdrHudController(), session: session)
                .environment(\.herdrFontScale, .xxxLarge)
        }

        result.expectSubstantial(minimumBytes: 2_000)
        let text = try recognizedText(at: result.url).lowercased()
        #expect(!session.isNewChat)
        #expect(!text.contains("create in main workspace"))
    }

    @Test("A workspace recovery composer renders Open chat and Keep draft")
    func rendersWorkspaceLaunchRecovery() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        session.applyLocalMachineDefaultIfNeeded(in: model)
        let receipt = HerdrHudWorkspaceLaunchReceipt(
            requestID: "launch-1",
            fingerprint: "synthetic-fingerprint",
            machineID: "demo1",
            endpoint: "http://localhost:9092",
            workspaceID: "w-main",
            tabID: "w-main:t1",
            paneID: "w-main:p1",
            phase: .sending,
            createdAt: .now
        )
        session.createsInMainWorkspace = true
        session.draft = "Recover this draft"
        session.setWorkspaceLaunchStateForTesting(
            .needsRecovery(
                message: "A chat was created in the main workspace, but Herdr couldn't confirm its first message was sent.",
                receipt: receipt
            )
        )

        let result = try await HerdrRenderHarness.render(
            "32-hud-workspace-recovery.png",
            size: CGSize(width: 520, height: 360),
            settlePasses: 12
        ) {
            HerdrHudComposerView(model: model, controller: HerdrHudController(), session: session)
                .environment(\.herdrFontScale, .large)
        }

        result.expectSubstantial(minimumBytes: 2_000)
        let text = try recognizedText(at: result.url).lowercased()
        #expect(text.contains("open chat"))
        #expect(text.contains("keep draft"))
        #expect(session.workspaceLaunchPaneIDForOpening() == "demo1|w-main:p1")
    }

    private func recognizedText(at url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.005
        try HerdrOCR.perform(request, url: url)
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HudRenderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated render defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryPersistenceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HudRenderTests-\(UUID().uuidString)-hud-thread.json")
    }

    private func renderArtifact(
        id: String,
        filename: String,
        contentType: String
    ) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id,
            originType: .pane,
            originID: "w1:p1",
            kind: .file,
            title: filename,
            filename: filename,
            contentType: contentType,
            byteSize: 2_048,
            createdAt: HerdrTimestamp.string(from: .now),
            downloadPath: "/api/v1/result-artifacts/\(id)/content"
        )
        .stamped(machineID: "demo1")
    }

    @Test("HUD voice reply card renders the editable transcript")
    func rendersHudVoiceReplyCard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let voiceReply = HerdrHudVoiceReply()
        voiceReply.target(paneID: "demo1|p1", title: "release planner")
        voiceReply.enterEditingForTesting(
            transcript: "Ship the release notes once the changelog lands, then ping me."
        )

        let result = try await HerdrRenderHarness.render(
            "23-hud-voice-reply-card.png",
            size: HerdrHudPlacement.voiceReplyCardSize
        ) {
            HerdrHudVoiceReplyCardView(model: model, voiceReply: voiceReply)
        }

        result.expectSubstantial()
    }
}
