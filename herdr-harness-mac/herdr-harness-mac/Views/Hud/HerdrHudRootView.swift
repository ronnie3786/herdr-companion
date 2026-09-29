import SwiftUI

struct HerdrHudRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let notes: HerdrHudNotesState
    let fontScale: HerdrFontScaleStore

    @State private var voiceReply = HerdrHudVoiceReply()
    /// The resting-circle ↔ orb morph. Seeded from the controller so the very
    /// first frame already shows the right surface.
    @State private var morph: HerdrHudMorphTimeline
    /// Drives the frame clock only while a morph is in flight; a settled HUD
    /// must not keep a display link alive.
    @State private var isMorphAnimating = false
    @AppStorage(HerdrAppearancePreferences.glassEnabledKey) private var glassEnabled = HerdrAppearancePreferences.defaultGlassEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        model: HerdrAppModel,
        controller: HerdrHudController,
        session: HerdrHudSession,
        notes: HerdrHudNotesState,
        fontScale: HerdrFontScaleStore
    ) {
        _model = Bindable(wrappedValue: model)
        self.controller = controller
        self.session = session
        self.notes = notes
        self.fontScale = fontScale
        _morph = State(initialValue: .settled(atRest: controller.isUltraCompactResting))
    }

    /// Which of the HUD's three collapsed-or-not surfaces the controller wants.
    /// Only the orb ↔ resting pair morphs; the chat card keeps its own
    /// transition and snaps the morph to whichever end it leaves toward.
    private enum Surface: Equatable {
        case card
        case orb
        case resting
    }

    private var surface: Surface {
        if controller.isExpanded { return .card }
        return controller.isUltraCompactResting ? .resting : .orb
    }

    /// The real indicator takes over once the morph has landed on the circle.
    private var showsRestingCircle: Bool {
        morph.isAtRest && !isMorphAnimating
    }

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

    private var unreadAlertStatuses: [AgentStatus] {
        HerdrHudNotificationFilter.alerts(model.alerts, panes: model.workspaces.flatMap(\.panes))
            .filter { !$0.isRead }
            .map(\.status)
    }

    private var ultraCompactTone: HerdrHudNotificationPresentation.UltraCompactTone {
        HerdrHudNotificationPresentation.ultraCompactTone(
            sessionIsRunning: controller.isHudRunActive,
            workingCount: model.workingCount,
            statuses: unreadAlertStatuses + attentionChipStatuses,
            isConnected: model.connectionState == .live || model.isDemoMode
        )
    }

    var body: some View {
        let chipState = sessionChips
        let orbNotificationStatuses = attentionChipStatuses
        let hudChatCount = controller.chats?.visibleChats.count ?? 0
        let collapsedCounts = [chipState.chips.count + hudChatCount, chipState.overflow]
        let hasSessionRows = hudChatCount > 0 || !chipState.chips.isEmpty || chipState.overflow > 0
        // An empty stack would still earn its spacing beneath the orb, and the
        // hosting view's minimum size would then push the panel past the frame
        // the controller computed. Mount the agents block only when it has rows.
        let showsAgents = controller.quickVoice?.isExpanded == true || hasSessionRows
        let tone = ultraCompactTone
        // One clock for the whole surface: the orb lane, the chips, and the
        // companions below all read the same morph state each frame.
        TimelineView(.animation(paused: !isMorphAnimating)) { context in
            let morphState = isMorphAnimating ? morph.state(at: context.date) : morph.target
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
                    } else if showsRestingCircle {
                        HerdrHudUltraCompactIndicator(controller: controller, tone: tone)
                    } else {
                        HerdrHudMorphStage(
                            state: morphState,
                            tone: tone,
                            pulseOpacity: restingPulseOpacity(tone: tone, at: context.date)
                        ) {
                            HerdrHudOrbResultRow(
                                model: model,
                                controller: controller,
                                session: session,
                                artifacts: chipState.detachedArtifacts,
                                attentionChipCount: orbNotificationStatuses.count,
                                attentionChipStatuses: orbNotificationStatuses,
                                notes: notes,
                                morphProgress: morphState.orb
                            )
                        } agents: {
                            if showsAgents {
                                VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                                    if let voice = controller.quickVoice, voice.isExpanded {
                                        QuickVoiceDetailsView(controller: voice, session: voice.session, model: model)
                                            .herdrHudHoverRegion("quick-voice", action: controller.setHoveringHud)
                                            .herdrHudMorphCompanionReveal(morphState.agents)
                                    }

                                    if hasSessionRows {
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
                                            measureContent: controller.measureSessionStack,
                                            revealProgress: morphState.agents
                                        )
                                        .onHover { controller.setHoveringChips($0) }
                                    }
                                }
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
                if !showsRestingCircle {
                    if voiceReply.showsCard {
                        HerdrHudVoiceReplyCardView(model: model, voiceReply: voiceReply)
                            .herdrHudHoverRegion("voice-reply", action: controller.setHoveringHud)
                            .herdrHudMorphCompanionReveal(morphState.agents)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing))
                            )
                    }
                    if notes.layout != .hidden, controller.isExpanded || notes.layout != .icon {
                        HerdrHudNotesStripView(model: model, controller: controller, notes: notes)
                            .herdrHudHoverRegion("notes", action: controller.setHoveringHud)
                            .herdrHudMorphCompanionReveal(morphState.agents)
                    }
                }
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
        .onChange(of: surface) { previous, current in
            surfaceDidChange(from: previous, to: current)
        }
        // Ends the frame clock once the morph has landed. Keyed on the
        // timeline so a retarget mid-flight restarts the countdown.
        .task(id: morph) {
            guard morph.isAnimating else { return }
            let remaining = morph.remainingDuration(at: .now) + 0.04
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            isMorphAnimating = false
        }
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
        //
        // The margin follows the panel lane the controller has actually applied,
        // not the resting flag: while the orb morphs back into the circle the
        // panel keeps the orb's frame, and the content must keep its margin with
        // it so the circle never jumps. Deliberately not animated: the panel
        // resizes in the same step, so an animated margin would slide content.
        .padding(
            controller.usesUltraCompactLane
                ? HerdrHudPlacement.ultraCompactShadowMargin
                : HerdrHudPlacement.shadowMargin
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: controller.isExpanded)
        .environment(\.herdrFontScale, fontScale.scale)
        // The HUD is always dark, so only the setting and Reduce Transparency decide.
        .environment(\.herdrGlassActive, HerdrGlass.isActive(enabled: glassEnabled, reduceTransparency: reduceTransparency, colorScheme: .dark))
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
    }

    /// The resting circle breathes while work is running; the morph picks that
    /// breath up so the hand-off is seamless.
    private func restingPulseOpacity(
        tone: HerdrHudNotificationPresentation.UltraCompactTone,
        at date: Date
    ) -> Double {
        guard tone == .working, !reduceMotion else { return 1 }
        return HerdrHudOrbMotion.workingOpacity(at: date)
    }

    private func surfaceDidChange(from previous: Surface, to current: Surface) {
        switch current {
        case .card:
            // The card has its own transition; park the morph on the full
            // HUD so the companions beneath the card stay visible.
            beginMorph(toRest: false, animated: false)
        case .orb:
            beginMorph(toRest: false, animated: previous == .resting && !reduceMotion)
        case .resting:
            beginMorph(toRest: true, animated: previous == .orb && !reduceMotion)
        }
    }

    private func beginMorph(toRest rest: Bool, animated: Bool) {
        morph.retarget(toRest: rest, at: .now, animated: animated)
        isMorphAnimating = morph.isAnimating
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
