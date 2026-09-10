import SwiftUI

enum HerdrHudChipMotion {
    static let workingGlowOpacity = 0.55

    /// HUD chips are permanently mounted beside the orb, so their working
    /// signal stays static. A static shadow preserves the visual cue without
    /// adding one perpetual display-link animation per chip.
    static func showsStaticGlow(for status: AgentStatus) -> Bool {
        status == .working
    }
}

struct HerdrHudSessionChipsView: View {
    @Environment(\.herdrFontScale) private var fontScale
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession
    let chips: [HerdrHudSessionChips.Chip]
    let overflow: Int
    var showAll: () -> Void = { }
    var summon: () -> Void = { }
    var voiceReply: HerdrHudVoiceReply?
    var openVoiceRequest: ((String) -> Void)?
    var expandsAttachmentTitles = false
    var onHoverHud: (Bool, String) -> Void = { _, _ in }
    var maximumHeight: CGFloat?
    var measureContent: (HerdrHudSessionStackMeasurement) -> Void = { _ in }

    @State private var measurement: HerdrHudSessionStackMeasurement?
    @State private var hoveredChipID: String?

    var body: some View {
        if let maximumHeight, contentHeight > maximumHeight {
            ScrollView(.vertical) {
                chipRows
            }
            .scrollIndicators(.hidden)
            .frame(width: contentWidth, height: max(0, maximumHeight))
            .accessibilityLabel("Agent sessions")
            .accessibilityHint("Scroll to reach more sessions")
        } else {
            chipRows
        }
    }

    private var contentHeight: CGFloat {
        if let measurement, measurement.matches(chipCount: chips.count, overflow: overflow, fontScale: fontScale.rawValue) {
            return measurement.height
        }
        return HerdrHudPlacement.sessionStackContentHeight(
            chipCount: chips.count,
            overflow: overflow,
            fontScale: fontScale.rawValue
        )
    }

    private var contentWidth: CGFloat {
        let artifactCount = chips.map(\.artifacts.count).max() ?? 0
        return HerdrHudPlacement.chipWidth + (artifactCount > 0
            ? HerdrHudPlacement.resultRailWidth(artifactCount: artifactCount, expandsTitles: expandsAttachmentTitles)
            : 0)
    }

    private var chipRows: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
            ForEach(chips) { chip in
                sessionRow(chip)
            }
            if overflow > 0 {
                overflowButton
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: HerdrHudSessionStackMeasurement.self) { geometry in
            HerdrHudSessionStackMeasurement(height: ceil(geometry.size.height), chipCount: chips.count,
                                           overflow: overflow, fontScale: fontScale.rawValue)
        } action: { measured in
            measurement = measured
            measureContent(measured)
        }
    }

    private func sessionRow(_ chip: HerdrHudSessionChips.Chip) -> some View {
        HStack(spacing: 0) {
            if !chip.artifacts.isEmpty {
                HerdrHudResultArtifactRailView(
                    model: model,
                    artifacts: chip.artifacts,
                    expandsTitles: expandsAttachmentTitles,
                    hoverRegionID: "session-results-\(chip.id)",
                    onHoverHud: onHoverHud
                )
            }

            chipButton(chip)
                .overlay(alignment: .topTrailing) {
                    if session.voiceReplyTarget == chip.id || voiceReply?.paneID == chip.id {
                        replyButton(chip)
                            .padding(.trailing, 6)
                            .padding(.top, 3)
                    } else if chip.status == .done {
                        speakButton(chip)
                            .padding(.trailing, 6)
                            .padding(.top, 3)
                            .opacity(showsSpeakButton(chip) ? 1 : 0)
                            .allowsHitTesting(showsSpeakButton(chip))
                    }
                }
                .herdrHudHoverRegion("session-\(chip.id)", action: onHoverHud)
                .onHover { hovering in
                    if hovering {
                        hoveredChipID = chip.id
                    } else if hoveredChipID == chip.id {
                        hoveredChipID = nil
                    }
                }
        }
    }

    /// The grouped-session control. Clicking it reveals the sessions the chip
    /// limit folded away; the HUD regroups them a few seconds after the pointer
    /// leaves the stack.
    private var overflowButton: some View {
        Button(action: showAll) {
            Text("+\(overflow)")
                .herdrFont(.caption2, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.mist)
                .frame(
                    width: HerdrHudPlacement.overflowDiameter(count: overflow, fontScale: fontScale.rawValue),
                    height: HerdrHudPlacement.overflowDiameter(count: overflow, fontScale: fontScale.rawValue)
                )
                .background(HerdrTheme.graphite.opacity(0.94), in: .circle)
                .overlay {
                    Circle().strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Show \(overflow) more session\(overflow == 1 ? "" : "s")")
        .accessibilityIdentifier("hud-session-chip-overflow")
        .accessibilityLabel("\(overflow) more sessions")
        .accessibilityHint("Shows every session; they regroup shortly after you move away")
        .herdrHudHoverRegion("session-overflow", action: onHoverHud)
    }

    /// Offered once this chip's answer has finished playing. Recording happens
    /// right here — tap to talk, tap again to stop — so a spoken reply never
    /// drags the user into the HUD's own chat, which is a different agent.
    private func replyButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        let isRecording = voiceReply?.isRecording == true
        let isTranscribing = voiceReply?.phase == .transcribing
        return Button {
            guard let voiceReply else { return }
            voiceReply.target(paneID: chip.id, title: chip.title)
            Task { await voiceReply.toggleCapture(gateway: HerdrLiveVoiceReplyGateway(model: model)) }
        } label: {
            Group {
                if isTranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isRecording ? "record.circle.fill" : "mic.circle.fill")
                        .herdrFont(.caption2, weight: .bold)
                        .foregroundStyle(isRecording ? HerdrTheme.alert : HerdrTheme.accent)
                }
            }
            .frame(width: 20, height: 20)
            .background(HerdrTheme.graphite, in: .circle)
            .overlay {
                Circle().strokeBorder(
                    (isRecording ? HerdrTheme.alert : HerdrTheme.accent).opacity(isRecording ? 0.9 : 0.45),
                    lineWidth: 1
                )
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isTranscribing)
        .help(isRecording ? "Stop recording" : "Reply to this session by voice")
        .accessibilityLabel(isRecording ? "Stop recording" : "Reply by voice")
        .accessibilityIdentifier("hud-session-chip-reply-\(chip.id)")
    }

    private func showsSpeakButton(_ chip: HerdrHudSessionChips.Chip) -> Bool {
        hoveredChipID == chip.id || session.isSpeakingSession(chip.id)
    }

    /// The same TL;DR playback the chat composer offers, reachable without
    /// opening the session: hover a finished chip and press play.
    private func speakButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        Button {
            Task { await session.toggleSessionAudio(paneID: chip.id, model: model) }
        } label: {
            Group {
                if session.isPreparingSessionAudio(chip.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: speakSymbol(chip))
                        .herdrFont(.caption2, weight: .bold)
                }
            }
            .foregroundStyle(session.isSpeakingSession(chip.id) ? HerdrTheme.working : HerdrTheme.accent)
            .frame(width: 20, height: 20)
            .background(HerdrTheme.graphite, in: .circle)
            .overlay {
                Circle().strokeBorder(HerdrTheme.accent.opacity(0.45), lineWidth: 1)
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Play a spoken summary of this session's last answer")
        .accessibilityIdentifier("hud-session-chip-speak-\(chip.id)")
        .accessibilityLabel("Listen to a summary of \(chip.title)")
    }

    private func speakSymbol(_ chip: HerdrHudSessionChips.Chip) -> String {
        guard session.isSpeakingSession(chip.id) else { return "speaker.wave.2.fill" }
        return session.responseAudioPlayer.phase == .paused(.tldr) ? "play.fill" : "pause.fill"
    }

    private func chipButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        Button {
            if model.pane(id: chip.id) == nil, let noteID = chip.voiceNoteID {
                openVoiceRequest?(noteID)
            } else {
                model.dismissHudChip(chip.id)
                HerdrMacAppDelegate.openPaneURLWithFallback(chip.id)
            }
        } label: {
            HerdrHudSessionBubbleLabel(chip: chip, model: model)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let pane = model.pane(id: chip.id) {
                SmartRenamePaneButton(model: model, pane: pane)
                CopyPaneIDButton(pane: pane)
            }
            if let noteID = chip.voiceNoteID {
                Button("Show voice request", systemImage: "waveform") { openVoiceRequest?(noteID) }
            }
            Button(
                chip.isMuted ? "Unmute session" : "Mute session",
                systemImage: chip.isMuted ? "bell" : "bell.slash"
            ) {
                model.toggleMutedHudSession(chip.id)
            }
        }
        .accessibilityIdentifier("hud-session-chip-\(chip.id)")
        .help("\(chip.title): \(chip.activity). \(chip.statusLabel)")
    }
}
