import SwiftUI
import UIKit

/// The Car mode surface: the agents that matter right now, one line each, with
/// oversized summary-audio and spoken-reply controls.
///
/// Presented full screen over the tab bar. Everything here is reachable by
/// glance and thumb; there is no text entry anywhere on this surface.
struct CarModeView: View {
    @Bindable var model: HerdrAppModel
    let dismiss: () -> Void

    @State private var store = CarModeStore()
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var previousIdleTimerState: Bool?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    private struct PollKey: Hashable {
        let generation: Int
        let isActive: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height
            let scale = CarModeMetrics.scale(for: dynamicTypeSize)

            ZStack {
                HerdrTheme.crust.ignoresSafeArea()

                VStack(spacing: 0) {
                    header(isWide: isWide, scale: scale)
                    content(size: proxy.size, isWide: isWide, scale: scale)
                }

                if store.isShowingVoiceLayer {
                    CarVoiceCaptureView(
                        phase: store.voice,
                        agentTitle: store.voiceEntry?.pane.displayTitle ?? "Agent",
                        workspaceLabel: store.voiceEntry?.session.workspace.label ?? "",
                        disposition: voiceDisposition,
                        samples: store.voiceSamples,
                        scale: scale,
                        isWide: isWide,
                        confirmsTranscripts: model.carModePreferences.confirmsVoiceTranscripts,
                        finish: { Task { await store.finishVoice(model: model) } },
                        send: { Task { await store.sendVoice(model: model) } },
                        retry: { store.retryVoice(model: model) },
                        cancel: { store.cancelVoice() }
                    )
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
        }
        .tint(HerdrTheme.accent)
        .preferredColorScheme(.dark)
        .task(id: PollKey(generation: model.connectionGeneration, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await store.run(model: model)
        }
        .onAppear {
            applyIdleTimerPreference()
            statusHapticTracker.setSceneActive(
                true,
                // Car mode polls its own snapshots, so transitions can be
                // announced immediately instead of waiting for a fleet refresh.
                isDemoMode: true,
                statuses: store.statusSnapshot
            )
        }
        .onDisappear {
            store.stop()
            restoreIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                // A hot microphone must never survive leaving the screen.
                store.cancelVoice()
            }
        }
        .onChange(of: model.carModePreferences.keepsScreenAwake) {
            applyIdleTimerPreference()
        }
        .onChange(of: store.statusSnapshot, initial: true) { _, statuses in
            if let event = statusHapticTracker.observe(statuses) {
                hapticPulse.fire(event)
            }
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    // MARK: - Header

    private func header(isWide: Bool, scale: CGFloat) -> some View {
        HStack(spacing: CarModeMetrics.scaled(10, by: scale)) {
            Image(systemName: "car.fill")
                .font(.system(size: 21 * scale, weight: .semibold))
                .foregroundStyle(HerdrTheme.accent)
                .frame(
                    width: CarModeMetrics.scaled(40, by: scale),
                    height: CarModeMetrics.scaled(40, by: scale)
                )
                .background(HerdrTheme.accent.opacity(0.14), in: .rect(cornerRadius: CarModeMetrics.scaled(12, by: scale)))
                .overlay {
                    RoundedRectangle(cornerRadius: CarModeMetrics.scaled(12, by: scale))
                        .strokeBorder(HerdrTheme.accent.opacity(0.34), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("Car mode")
                    .font(.system(size: 21 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
                subtitle(scale: scale)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ConnectionPill(state: model.connectionState)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
                    .frame(
                        width: CarModeMetrics.scaled(CarModeMetrics.exitSize, by: scale),
                        height: CarModeMetrics.scaled(CarModeMetrics.exitSize, by: scale)
                    )
                    .background(HerdrTheme.graphite, in: .rect(cornerRadius: CarModeMetrics.scaled(16, by: scale)))
                    .overlay {
                        RoundedRectangle(cornerRadius: CarModeMetrics.scaled(16, by: scale))
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("car-mode-exit")
            .accessibilityLabel("Leave Car mode")
            .accessibilityHint("Returns to the full Herdr app")
        }
        .padding(.horizontal, CarModeMetrics.pagePadding)
        .padding(.top, CarModeMetrics.scaled(isWide ? 2 : 6, by: scale))
        .padding(.bottom, CarModeMetrics.scaled(isWide ? 8 : 10, by: scale))
    }

    private func subtitle(scale: CGFloat) -> some View {
        Group {
            if let lastRefreshedAt = store.lastRefreshedAt {
                TimelineView(.periodic(from: lastRefreshedAt, by: 15)) { context in
                    Text("\(store.entries.count) \(store.entries.count == 1 ? "agent" : "agents") · updated \(HerdrTimestamp.compactAge(since: lastRefreshedAt, now: context.date))")
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundStyle(HerdrTheme.mist)
                }
            } else {
                Text("Finding your newest agents…")
                    .font(.system(size: 13 * scale, weight: .medium))
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .lineLimit(1)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(size: CGSize, isWide: Bool, scale: CGFloat) -> some View {
        switch store.screen {
        case let .detail(id):
            if let entry = store.entry(id: id) {
                CarAgentDetailView(
                    entry: entry,
                    scale: scale,
                    isWide: isWide,
                    isRecording: store.voice.isRecording && store.voiceAgentID == id,
                    back: { store.showGrid() },
                    play: { play(entry, scale: scale) },
                    respond: { respond(to: entry) }
                )
            } else {
                grid(size: size, isWide: isWide, scale: scale)
            }
        case .grid:
            grid(size: size, isWide: isWide, scale: scale)
        }
    }

    @ViewBuilder
    private func grid(size: CGSize, isWide: Bool, scale: CGFloat) -> some View {
        if store.entries.isEmpty {
            emptyState(scale: scale)
        } else {
            let spacing = CarModeMetrics.scaled(CarModeMetrics.cardSpacing, by: scale)
            let verticalPadding = CarModeMetrics.scaled(isWide ? 8 : 12, by: scale)
            let minimum = CarModeMetrics.scaled(
                isWide ? CarModeMetrics.landscapeRowMinHeight : CarModeMetrics.portraitCardMinHeight,
                by: scale
            )
            let count = CGFloat(store.entries.count)
            let available = size.height - headerHeight(isWide: isWide, scale: scale) - verticalPadding * 2
            let cardHeight = max(minimum, (available - spacing * (count - 1)) / count)

            ScrollView {
                VStack(spacing: spacing) {
                    ForEach(store.entries) { entry in
                        CarAgentCardView(
                            entry: entry,
                            scale: scale,
                            isWide: isWide,
                            isVoiceTarget: store.voice.isRecording && store.voiceAgentID == entry.id,
                            open: { store.openDetail(for: entry.id) },
                            play: { play(entry, scale: scale) },
                            respond: { respond(to: entry) }
                        )
                        .frame(height: cardHeight)
                    }
                }
                .padding(.horizontal, CarModeMetrics.pagePadding)
                .padding(.vertical, verticalPadding)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The grid measures its own area, so the header height is derived the same
    /// way the header lays out instead of being guessed from font metrics.
    private func headerHeight(isWide: Bool, scale: CGFloat) -> CGFloat {
        CarModeMetrics.scaled(CarModeMetrics.exitSize, by: scale)
            + CarModeMetrics.scaled(isWide ? 2 : 6, by: scale)
            + CarModeMetrics.scaled(isWide ? 8 : 10, by: scale)
    }

    private func emptyState(scale: CGFloat) -> some View {
        VStack(spacing: 12) {
            switch store.loadPhase {
            case .loading, .idle:
                ProgressView()
                    .controlSize(.large)
                    .tint(HerdrTheme.accent)
                Text("Finding your newest agents…")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.alert)
                Text(message)
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .multilineTextAlignment(.center)
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(model: model) }
                }
                .font(.system(size: 17 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: CarModeMetrics.scaled(56, by: scale))
            case .ready:
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 34 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.mist)
                Text("No recent agents")
                    .font(.system(size: 19 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
                Text("Start a Pi chat on a machine and it appears here.")
                    .font(.system(size: 15 * scale, weight: .medium))
                    .foregroundStyle(HerdrTheme.mist)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func play(_ entry: CarModeStore.Entry, scale: CGFloat) {
        hapticPulse.fire(.selection)
        store.toggleAudio(for: entry.id, action: .tldr, model: model)
    }

    private func respond(to entry: CarModeStore.Entry) {
        hapticPulse.fire(store.voice.isRecording && store.voiceAgentID == entry.id ? .recordingStopped : .recordingStarted)
        store.toggleVoice(for: entry.id, model: model)
    }

    private var voiceDisposition: PiPromptDisposition {
        guard let entry = store.voiceEntry else { return .prompt }
        return CarModeSendPolicy.disposition(
            phase: entry.summary.phase,
            capabilities: entry.pane.piSemantic?.capabilities
        )
    }

    // MARK: - Screen behaviour

    private func applyIdleTimerPreference() {
        if previousIdleTimerState == nil {
            previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = model.carModePreferences.keepsScreenAwake
    }

    private func restoreIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState ?? false
        previousIdleTimerState = nil
    }
}

#if DEBUG
#Preview("Car mode") {
    CarModeView(model: HerdrAppModel(arguments: ["-HerdrDemoMode"]), dismiss: {})
}
#endif
