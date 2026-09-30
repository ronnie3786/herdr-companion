import AppKit
import SwiftUI

/// The pop-out simulator window for one saved build (Window ▸ opened from a
/// First Mate's Builds section or Workflow). It resolves the build's machine
/// and never falls back to another one.
struct FirstMateSimulatorWindowRoot: View {
    let target: FirstMateSimulatorWindowTarget
    @State private var session: FirstMateSimulatorSession

    init(model: HerdrAppModel, target: FirstMateSimulatorWindowTarget) {
        self.target = target
        let configuration = model.firstMateConfiguration(machineID: target.machineID)
        let name = model.machines.first { $0.id == target.machineID }?.name ?? "This machine"
        _session = State(initialValue: FirstMateSimulatorSession(
            target: target, machineName: name,
            api: configuration.map { FirstMateSimulatorAPI(configuration: $0) },
            isDemo: model.isDemoMode,
            onChange: {
                // The inspector's rows show which builds are running.
                guard let feed = FirstMateSimulatorFeeds.shared.existing(machineID: target.machineID, featureID: target.featureID)
                else { return }
                Task { await feed.refresh() }
            }))
    }

    var body: some View {
        FirstMateSimulatorWindowContent(session: session)
            // Hidden in the title bar, but it names the window in the Window menu and Mission Control.
            .navigationTitle(session.windowTitle)
            .task { await session.run() }
            .onDisappear { session.close() }
            .background { FirstMateWindowVisibilityObserver { session.setVisible($0) } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("first-mate-simulator-window")
    }
}

struct FirstMateSimulatorWindowContent: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        VStack(spacing: 0) {
            FirstMateSimulatorTitleBar(session: session)
            FirstMateSimulatorIdentity(session: session)
            FirstMateSimulatorStage(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            FirstMateSimulatorControls(session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) { HerdrHazeBand() }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, base: HerdrTheme.windowBackground) }
    }
}

// MARK: - Title bar

/// The 40 pt bar beside the traffic lights: the simulator's state and its two
/// window-level actions. Empty space drags the window.
private struct FirstMateSimulatorTitleBar: View {
    let session: FirstMateSimulatorSession
    @AppStorage("herdr.mac.firstMate.simulator.browserFocusNoticeSuppressed") private var focusNoticeSuppressed = false
    @State private var confirmingBrowser = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: HerdrWindowChrome.trafficLightInset)
            FirstMateSimulatorStatusPill(session: session)
            Button {
                if focusNoticeSuppressed { openBrowser() } else { confirmingBrowser = true }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(HerdrIconButtonStyle())
            .disabled(session.browserURL == nil)
            .help(session.browserURL == nil ? session.browserUnavailableReason : "Open this exact simulator in SimPortal's browser viewer")
            .accessibilityIdentifier("first-mate-simulator-open-browser")
            .confirmationDialog("Open this simulator in your browser?", isPresented: $confirmingBrowser) {
                Button("Open in Browser") { openBrowser() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("SimPortal's browser viewer makes this simulator its focused simulator, the one agents use when they don't name a device. This window doesn't change focus.")
            }
            .dialogSuppressionToggle(isSuppressed: $focusNoticeSuppressed)
            Button {
                Task { await session.stop() }
            } label: {
                Label("Shut Down Simulator", systemImage: "power")
            }
            .buttonStyle(HerdrIconButtonStyle())
            .disabled(!canStop || session.isSubmitting)
            .help("Shut down this simulator now. Its data is kept; the saved build stays.")
            .accessibilityIdentifier("first-mate-simulator-stop")
        }
        .padding(.trailing, 10)
        .frame(height: HerdrTheme.ControlHeight.titleBar)
        .frame(maxWidth: .infinity)
        .background { HerdrWindowDragArea() }
    }

    private var canStop: Bool {
        switch session.phase {
        case .starting, .running: true
        case .failed, .unavailable: session.preview?.observation?.deviceState == "Booted"
        default: false
        }
    }

    private func openBrowser() {
        guard let url = session.browserURL, FirstMateLinkURL.validated(url.absoluteString) != nil else { return }
        openURL(url)
    }
}

/// Starting, Live, Paused… in the simulator's status color.
struct FirstMateSimulatorStatusPill: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        let (title, color, working) = presentation
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .firstMateBreathing(working)
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .frame(height: HerdrTheme.ControlHeight.small)
        .background(color.opacity(0.12), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Simulator \(title)")
        .accessibilityIdentifier("first-mate-simulator-status")
    }

    private var presentation: (String, Color, Bool) {
        switch session.phase {
        case .opening, .starting: ("Starting", HerdrTheme.working, true)
        case .stopping: ("Shutting down", HerdrTheme.working, true)
        case .stopped: (session.simulatorDeleted ? "Deleted" : "Shut down", HerdrTheme.tertiaryText, false)
        case .failed: ("Failed", HerdrTheme.alert, false)
        case .unavailable: ("Unavailable", HerdrTheme.warning, false)
        case .running:
            if session.isDemo { ("Live", HerdrTheme.success, false) }
            else if session.isPausedWhileHidden { ("Paused", HerdrTheme.tertiaryText, false) }
            else {
                switch session.stream?.state {
                case .live: ("Live", HerdrTheme.success, false)
                case .reconnecting, .connecting, .waitingForDevice, .none, .idle: ("Connecting", HerdrTheme.working, true)
                case .paused: ("Paused", HerdrTheme.tertiaryText, false)
                case .ended, .failed: ("Disconnected", HerdrTheme.warning, false)
                }
            }
        }
    }
}

// MARK: - Identity

/// Which First Mate and which build this simulator shows.
private struct FirstMateSimulatorIdentity: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FirstMateEmojiDisc(emoji: session.feature?.emoji ?? FirstMateDefaultEmoji.emoji(for: session.target.featureID), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.feature?.label ?? session.feature?.title ?? "First Mate")
                        .herdrFont(size: 14.5, weight: .semibold)
                        .tracking(-0.15)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                    Text(session.machineName)
                        .herdrFont(size: 11.5)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(1)
                }
                Text(session.build?.checkpointLabel ?? "Simulator build")
                    .herdrFont(size: 12.5, weight: .medium)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .herdrFont(size: 11.5)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrHairline(.bottom)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("first-mate-simulator-identity")
    }

    private var detail: String? {
        guard let build = session.build else { return nil }
        let parts = [build.appLabel, build.stageTitle, build.source?.revision.map { String($0.prefix(7)) }]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}

// MARK: - Stage

/// The device, fitted to the window, with whatever the simulator is doing on top.
private struct FirstMateSimulatorStage: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        GeometryReader { proxy in
            let screen = screenSize(in: proxy.size)
            let bezel = max(6, screen.width * 0.03)
            let radius = screenRadius(width: screen.width)
            ZStack {
                RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                    .fill(Color.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                            .strokeBorder(HerdrTheme.outline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .frame(width: screen.width + bezel * 2, height: screen.height + bezel * 2)
                screenContent
                    .frame(width: screen.width, height: screen.height)
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                    .overlay { FirstMateSimulatorScreenOverlay(session: session, radius: radius) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var screenContent: some View {
        if let frame = session.demoFrame {
            Image(decorative: frame, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let stream = session.stream {
            SimulatorScreenView(controller: stream, isInteractive: session.phase == .running || session.phase == .starting)
                .accessibilityIdentifier("first-mate-simulator-screen")
        } else {
            Color.black
        }
    }

    /// Width over height of the screen: the stream's own size once known.
    private var aspect: CGFloat {
        if let size = session.stream?.pixelSize, size.width > 0, size.height > 0 { return size.width / size.height }
        if let frame = session.demoFrame { return CGFloat(frame.width) / CGFloat(frame.height) }
        return (session.preview?.device ?? session.status?.defaultDevice)?.isTablet == true ? 0.72 : 402.0 / 874.0
    }

    private func screenSize(in available: CGSize) -> CGSize {
        let height = max(1, available.height - 16)
        let width = max(1, available.width - 16)
        return width / height > aspect ? CGSize(width: height * aspect, height: height) : CGSize(width: width, height: width / aspect)
    }

    private func screenRadius(width: CGFloat) -> CGFloat {
        if let fraction = session.stream?.device?.cornerRadiusFraction {
            return width * CGFloat(fraction)
        }
        return width * (aspect > 0.6 ? 0.035 : 0.13)
    }
}

/// Loading steps, an in-progress chip, or a stopped/failed card over the screen.
private struct FirstMateSimulatorScreenOverlay: View {
    let session: FirstMateSimulatorSession
    let radius: CGFloat

    var body: some View {
        ZStack {
            switch session.phase {
            case .opening:
                card { FirstMateSimulatorProgressCard(title: "Opening…", device: nil, steps: [], current: nil) }
            case .starting:
                if showsPicture {
                    VStack {
                        Spacer()
                        chip(FirstMateSimulatorStepText.title(for: session.preview?.operation?.step ?? "installing") + "…")
                    }
                    .padding(.bottom, 30)
                } else {
                    card {
                        FirstMateSimulatorProgressCard(
                            title: "Starting the simulator", device: session.preview?.device?.label,
                            steps: session.preview?.operation?.steps ?? [], current: session.preview?.operation?.step)
                    }
                }
            case .running:
                if session.isPausedWhileHidden {
                    card { stateMessage(symbol: "pause.circle", title: "Paused while hidden",
                                        message: "Show the window to resume the picture.") }
                } else if !session.isDemo, let stream = session.stream {
                    streamState(stream)
                }
            case .stopping:
                card { stateMessage(symbol: "power", title: "Shutting down…", message: nil) }
            case .stopped:
                card {
                    stateMessage(symbol: session.simulatorDeleted ? "trash" : "power",
                                 title: session.simulatorDeleted ? "Simulator deleted" : "Simulator shut down",
                                 message: stoppedReason) {
                        Button("Start Again") { Task { await session.startAgain() } }
                            .buttonStyle(HerdrButtonStyle(kind: .primary))
                            .disabled(session.isSubmitting || session.build?.launchable == false)
                            .accessibilityIdentifier("first-mate-simulator-start-again")
                    }
                }
            case .failed(let message):
                card {
                    stateMessage(symbol: "exclamationmark.triangle", title: "The simulator didn't start", message: message) {
                        Button("Try Again") { Task { await session.startAgain() } }
                            .buttonStyle(HerdrButtonStyle(kind: .outline))
                            .disabled(session.isSubmitting)
                    }
                }
            case .unavailable(let message):
                card {
                    stateMessage(symbol: "iphone.slash", title: "Can't open this build", message: message) {
                        if !session.capacity.isEmpty {
                            FirstMateSimulatorCapacityList(previews: session.capacity)
                        }
                        Button("Try Again") { Task { await session.retryOpen() } }
                            .buttonStyle(HerdrButtonStyle(kind: .outline))
                            .disabled(session.isSubmitting)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }

    private var showsPicture: Bool { session.demoFrame != nil || (session.stream != nil && session.stream?.state == .live) }

    private var stoppedReason: String {
        if session.simulatorDeleted {
            return "It was deleted in SimPortal to free disk space. The build is saved; starting again opens a fresh simulator."
        }
        switch session.preview?.stopReason {
        case "idle":
            let minutes = session.preview?.idle?.shutdownAfterMinutes ?? session.status?.policy?.idleShutdownMinutes ?? 60
            return "Nobody had watched it for \(FirstMateSimulatorPolicyText.duration(minutes: minutes)). Its data is kept; starting again opens a fresh simulator."
        case "capacity": return "It was shut down to make room for another simulator."
        default: return "Its data is kept; starting again opens a fresh simulator."
        }
    }

    @ViewBuilder private func streamState(_ stream: SimulatorStreamController) -> some View {
        switch stream.state {
        case .live:
            if stream.isTyping {
                VStack {
                    Spacer()
                    chip("Typing into the simulator")
                }
                .padding(.bottom, 30)
            }
        case .idle, .connecting:
            chip("Connecting…")
        case .waitingForDevice(let state):
            chip(state == "Booting" ? "Booting iOS…" : "Waiting for the simulator (\(state))…")
        case .reconnecting:
            chip("Reconnecting…")
        case .paused:
            EmptyView()
        case .ended(let reason), .failed(let reason):
            card { stateMessage(symbol: "wifi.exclamationmark", title: "The picture stopped", message: reason) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(session.demoFrame == nil && session.stream == nil ? 0 : 0.55)
            content()
                .padding(16)
                .frame(maxWidth: 300)
                .background(HerdrTheme.windowBackground.opacity(0.94), in: .rect(cornerRadius: HerdrTheme.Radius.card))
                .overlay { RoundedRectangle(cornerRadius: HerdrTheme.Radius.card).strokeBorder(HerdrTheme.outline) }
                .padding(18)
        }
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                .foregroundStyle(HerdrTheme.primaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(HerdrTheme.windowBackground.opacity(0.88), in: .capsule)
        .overlay { Capsule().strokeBorder(HerdrTheme.outline) }
    }

    private func stateMessage(symbol: String, title: String, message: String?) -> some View {
        stateMessage(symbol: symbol, title: title, message: message) { EmptyView() }
    }

    private func stateMessage<Actions: View>(symbol: String, title: String, message: String?,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .herdrFont(size: 20)
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(title)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .accessibilityElement(children: .contain)
    }
}

/// SimPortal's start steps with the current one spinning.
struct FirstMateSimulatorProgressCard: View {
    let title: String
    let device: String?
    let steps: [FirstMateSimulatorPreview.Step]
    let current: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                if let device {
                    Text(device)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            if steps.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps, id: \.name) { step in
                        HStack(spacing: 8) {
                            stepIcon(step)
                                .frame(width: 14, height: 14)
                            Text(FirstMateSimulatorStepText.title(for: step.name))
                                .herdrFont(size: HerdrTheme.TextSize.small, weight: step.name == current ? .semibold : .regular)
                                .foregroundStyle(step.state == "pending" ? HerdrTheme.tertiaryText : HerdrTheme.primaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(FirstMateSimulatorStepText.title(for: step.name)), \(stateWord(step.state))")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("first-mate-simulator-steps")
    }

    @ViewBuilder private func stepIcon(_ step: FirstMateSimulatorPreview.Step) -> some View {
        switch step.state {
        case "succeeded":
            Image(systemName: "checkmark.circle.fill").herdrFont(size: 12).foregroundStyle(HerdrTheme.success)
        case "running":
            ProgressView().controlSize(.mini)
        case "failed", "unknown":
            Image(systemName: "exclamationmark.circle.fill").herdrFont(size: 12).foregroundStyle(HerdrTheme.alert)
        case "skipped":
            Image(systemName: "minus.circle").herdrFont(size: 12).foregroundStyle(HerdrTheme.tertiaryText)
        default:
            Image(systemName: "circle").herdrFont(size: 12).foregroundStyle(HerdrTheme.tertiaryText)
        }
    }

    private func stateWord(_ state: String) -> String {
        switch state {
        case "succeeded": "done"
        case "running": "in progress"
        case "failed": "failed"
        case "skipped": "skipped"
        default: "waiting"
        }
    }
}

/// The previews that are already using the machine's simulator slots.
private struct FirstMateSimulatorCapacityList: View {
    let previews: [FirstMateSimulatorPreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(previews) { preview in
                HStack(spacing: 6) {
                    Circle().fill(HerdrTheme.success).frame(width: 6, height: 6)
                    Text(preview.device?.label ?? "Simulator")
                    Text(preview.phase == "starting" ? "starting" : "in use")
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(HerdrTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Controls

/// Home and Lock, what the keyboard is doing, the device, and when an
/// unwatched simulator will shut down.
private struct FirstMateSimulatorControls: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        HStack(spacing: 4) {
            Button { session.stream?.pressButton(.home) } label: { Label("Home", systemImage: "house") }
                .buttonStyle(HerdrIconButtonStyle())
                .help("Home (⇧⌘H)")
            Button { session.stream?.pressButton(.lock) } label: { Label("Lock", systemImage: "lock") }
                .buttonStyle(HerdrIconButtonStyle())
                .help("Side button (⌘L)")
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(deviceLabel)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.secondaryText)
                Text(resourceNote)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
        }
        .disabled(!(session.phase == .running && (session.stream?.acceptsInput ?? false)))
        .padding(.horizontal, 10)
        .frame(height: 46)
        .herdrHairline(.top)
        .overlay(alignment: .top) {
            if let notice = session.notice {
                Text(notice)
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(HerdrTheme.windowBackground.opacity(0.9), in: .capsule)
                    .offset(y: -30)
                    .accessibilityIdentifier("first-mate-simulator-notice")
            }
        }
    }

    private var deviceLabel: String {
        (session.preview?.device ?? session.status?.defaultDevice)?.label ?? "iOS Simulator"
    }

    private var resourceNote: String {
        let minutes = session.preview?.idle?.shutdownAfterMinutes ?? session.status?.policy?.idleShutdownMinutes ?? 0
        switch session.phase {
        case .running, .starting:
            guard minutes > 0 else { return "Stays on until you shut it down" }
            if let at = session.preview?.idle?.shutdownAt, let date = HerdrTimestamp.date(from: at), session.isPausedWhileHidden {
                return "Shuts down at \(date.formatted(date: .omitted, time: .shortened)) if nobody watches"
            }
            return "Shuts down after \(FirstMateSimulatorPolicyText.duration(minutes: minutes, short: true)) unwatched"
        case .stopped: return session.simulatorDeleted ? "Deleted" : "Shut down"
        default: return session.machineName
        }
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is on screen (not minimized or fully covered).
struct FirstMateWindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
            guard visible != lastVisible else { return }
            lastVisible = visible
            onChange?(visible)
        }
    }
}
