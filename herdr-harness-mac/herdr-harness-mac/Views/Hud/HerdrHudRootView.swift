import SwiftUI

struct HerdrHudRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let notes: HerdrHudNotesState
    let fontScale: HerdrFontScaleStore

    @State private var voiceReply = HerdrHudVoiceReply()

    private var sessionChips: (
        chips: [HerdrHudSessionChips.Chip],
        overflow: Int,
        detachedArtifacts: [AgentResultArtifact]
    ) {
        QuickVoiceHudProjection.chips(
            panes: model.workspaces.flatMap(\.panes),
            notes: controller.quickVoice?.session.notes ?? [],
            mutedPaneIDs: model.mutedHudSessionIDs,
            dismissed: model.dismissedHudChips,
            revealTitles: model.showSessionTitles,
            artifacts: model.unopenedResultArtifacts,
            showAll: controller.isShowingAllChips,
            visibleAgentLimit: controller.visibleAgentLimit,
            workspaceNames: Dictionary(model.workspaces.flatMap { workspace in
                workspace.panes.map { ($0.id, workspace.label) }
            }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Overflow is navigation, not unread attention. Project every session so
    /// hidden working sessions never create a notification count. Keep the
    /// statuses so the orb can distinguish finished work from genuine alerts.
    private var attentionChipStatuses: [AgentStatus] {
        let hudAnswers = controller.chats?.visibleChats.compactMap { chat -> AgentStatus? in
            guard chat.session.hasUnseenAnswer else { return nil }
            return HerdrHudNotificationPresentation.status(
                forHUDChat: chat.session.exchanges.last?.status
            )
        } ?? []
        let paneStatuses = QuickVoiceHudProjection.chips(
            panes: model.workspaces.flatMap(\.panes),
            notes: controller.quickVoice?.session.notes ?? [],
            mutedPaneIDs: model.mutedHudSessionIDs,
            dismissed: model.dismissedHudChips,
            revealTitles: false,
            artifacts: [],
            showAll: true
        ).chips.filter { $0.status.needsAttention }.map(\.status)
        return hudAnswers + paneStatuses
    }

    /// Recomputed whenever the target pane reports new work, which is the cue
    /// that the answer the reply offer belongs to has been superseded.
    private var replyTargetActivity: Date? {
        session.voiceReplyTarget.flatMap { model.pane(id: $0) }?.lastActivityAt
    }

    var body: some View {
        let chipState = sessionChips
        let orbNotificationStatuses = attentionChipStatuses
        let hudChatCount = controller.chats?.visibleChats.count ?? 0
        let collapsedCounts = [chipState.chips.count + hudChatCount, chipState.overflow]
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.notesGap) {
            Group {
                if controller.isExpanded {
                    HerdrHudCardView(model: model, controller: controller,
                                     session: controller.chats?.displayedSession ?? session)
                        .id(ObjectIdentifier(controller.chats?.displayedSession ?? session))
                        .herdrHudHoverRegion("hud-card", action: controller.setHoveringHud)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity),
                                    removal: .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity)
                                )
                        )
                } else {
                    VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                        HerdrHudOrbResultRow(
                            model: model,
                            controller: controller,
                            session: session,
                            artifacts: chipState.detachedArtifacts,
                            attentionChipCount: orbNotificationStatuses.count,
                            attentionChipStatuses: orbNotificationStatuses,
                            notes: notes
                        )

                        if let voice = controller.quickVoice, voice.isExpanded {
                            QuickVoiceDetailsView(controller: voice, session: voice.session, model: model)
                                .herdrHudHoverRegion("quick-voice", action: controller.setHoveringHud)
                        }

                        if hudChatCount > 0 || !chipState.chips.isEmpty || chipState.overflow > 0 {
                            HerdrHudSessionChipsView(
                                model: model,
                                session: session,
                                chips: chipState.chips,
                                overflow: chipState.overflow,
                                chatController: controller,
                                showAll: controller.showAllChips,
                                summon: controller.summon,
                                voiceReply: voiceReply,
                                openVoiceRequest: { controller.quickVoice?.showDetails(noteID: $0) },
                                expandsAttachmentTitles: controller.areAttachmentTitlesExpanded,
                                onHoverHud: controller.setHoveringHud,
                                maximumHeight: controller.collapsedSessionStackHeight,
                                measureContent: controller.measureSessionStack
                            )
                            .onHover { controller.setHoveringChips($0) }
                        }
                    }
                    .onChange(of: collapsedCounts, initial: true) { _, counts in
                        controller.setCollapsedChipCount(counts[0], overflow: counts[1])
                    }
                    .onChange(of: maximumResultCount(chipState), initial: true) { _, count in
                        controller.setCollapsedResultArtifactCount(count)
                    }
                }
            }
            if voiceReply.showsCard {
                HerdrHudVoiceReplyCardView(model: model, voiceReply: voiceReply)
                    .herdrHudHoverRegion("voice-reply", action: controller.setHoveringHud)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing))
                    )
            }
            if notes.layout != .hidden, controller.isExpanded || notes.layout != .icon {
                HerdrHudNotesStripView(model: model, controller: controller, notes: notes)
                    .herdrHudHoverRegion("notes", action: controller.setHoveringHud)
            }
        }
        .task(id: model.machines.filter { model.canControl(machineID: $0.id) }.map(\.id).sorted()) {
            await controller.chats?.restore(model: model)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: voiceReply.showsCard)
        .onChange(of: voiceReply.showsCard, initial: true) { _, isVisible in
            controller.setVoiceReplyCardVisible(isVisible)
        }
        .onChange(of: controller.quickVoice?.session.recorder.status) { _, _ in
            controller.quickVoice?.session.recordingStateChanged()
        }
        .onChange(of: controller.quickVoice?.session.recorder.errorMessage) { _, _ in
            controller.quickVoice?.session.recordingStateChanged()
        }
        .onChange(of: controller.quickVoice?.session.phase) { _, phase in
            if phase == .recording {
                voiceReply.cancel()
                session.responseAudioPlayer.stop()
            }
        }
        .onChange(of: session.voiceReplyTarget, initial: true) { _, target in
            // A new answer finishing retargets the reply; losing the target
            // means the session it belonged to is gone.
            if target == nil { voiceReply.cancel() }
        }
        // Sending or dismissing ends the reply. Without this the offer stayed
        // pinned to the chip forever, so the speaker never came back for the
        // next answer.
        .onChange(of: voiceReply.paneID) { previous, current in
            if previous != nil, current == nil { session.clearVoiceReplyTarget() }
        }
        .onChange(of: replyTargetActivity, initial: true) { _, _ in
            session.expireVoiceReplyTargetIfStale(
                pane: session.voiceReplyTarget.flatMap { model.pane(id: $0) },
                isReplyInFlight: voiceReply.paneID != nil
            )
        }
        .onChange(of: notes.layout, initial: true) { _, _ in controller.notesLayoutDidChange() }
        .onChange(of: fontScale.scale) { _, _ in controller.fontScaleDidChange() }
        .background(
            HerdrHudWindowDragHandle(
                onDragBegan: controller.beginPanelDrag,
                onDragEnded: controller.endPanelDrag
            )
        )
        // The panel is placed by its top-right corner and grows downward, so the
        // content must be pinned there too. Centering (the default) let content
        // that had already taken its final size overflow above the screen for
        // the whole of every frame animation, which read as the HUD jumping
        // off-screen and sliding back in.
        .padding(HerdrHudPlacement.shadowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: controller.isExpanded)
        .environment(\.herdrFontScale, fontScale.scale)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
    }

    private func maximumResultCount(
        _ chipState: (
            chips: [HerdrHudSessionChips.Chip],
            overflow: Int,
            detachedArtifacts: [AgentResultArtifact]
        )
    ) -> Int {
        min(
            HerdrHudPlacement.maxVisibleResults,
            max(chipState.detachedArtifacts.count, chipState.chips.map(\.artifacts.count).max() ?? 0)
        )
    }
}
