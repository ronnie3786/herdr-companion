import SwiftUI

/// The simulator for one saved build, full screen on iPad and iPhone (the Mac
/// opens a window). It asks the feature's companion to reuse or start a
/// simulator for the exact build, follows it through Booting, Installing and
/// Launching to Running, and shows SimPortal's stream through the companion's
/// relay with touches and hardware keys forwarded. Done only stops watching;
/// Stop shuts the simulator down. The companion's idle policy shuts down a
/// simulator nobody watches.
struct FirstMateSimulatorCover: View {
    let model: HerdrAppModel
    let target: FirstMateSimulatorWindowTarget
    let feed: FirstMateBuildsFeed
    @State private var session: FirstMateSimulatorSession?
    @State private var demoStartsFromBoot = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let session {
                FirstMateSimulatorCoverContent(session: session) { dismiss() }
                    .task { await follow(session) }
            } else {
                FirstMateSimulatorBackdrop().ignoresSafeArea()
            }
        }
        .onAppear { if session == nil { session = makeSession() } }
        .onDisappear { session?.close() }
        .onChange(of: scenePhase) { _, phase in session?.setVisible(phase != .background) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-simulator-cover")
    }

    /// Resolves the build's own machine; it never falls back to another one.
    private func makeSession() -> FirstMateSimulatorSession {
        let isDemo = model.isDemoMode
        let session = FirstMateSimulatorSession(
            target: target, machineName: model.machineName(target.machineID),
            api: isDemo ? nil : model.client(forMachine: target.machineID)?.simulatorPreviews,
            isDemo: isDemo,
            onChange: { [weak feed] in feed?.refreshSimulatorSoon() })
        if isDemo, let build = feed.simulator.builds.first(where: { $0.id == target.buildID }) {
            let snapshot = model.firstMateFleet.store(for: FirstMateFeatureTarget(machineID: target.machineID, featureID: target.featureID))?.snapshot
            let feature = snapshot.map {
                FirstMateSimulatorFeatureSummary(id: $0.feature.id, title: $0.feature.title, label: nil, emoji: nil)
            }
            let running = build.activePreview != nil
            demoStartsFromBoot = !running
            session.presentDemo(build: build, feature: feature,
                                screen: FirstMateSimulatorDemoAppScreen.image(FirstMateBuildsDemo.screenKind(for: build)),
                                startingAt: running ? nil : "booting")
        }
        return session
    }

    /// Follows the preview until the cover closes; demo mode plays the start steps instead.
    private func follow(_ session: FirstMateSimulatorSession) async {
        guard session.isDemo else { return await session.run() }
        guard demoStartsFromBoot else { return }
        demoStartsFromBoot = false
        for step in ["installing", "launching"] {
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            session.presentDemoStarting(at: step)
        }
        do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
        session.presentDemoRunning()
    }
}

/// The cover's bar, the device with its stream, the hardware controls and a
/// note on where the picture comes from. Render tests use it directly.
struct FirstMateSimulatorCoverContent: View {
    let session: FirstMateSimulatorSession
    var done: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            FirstMateSimulatorCoverBar(session: session, compact: sizeClass == .compact, done: done)
            VStack(spacing: 14) {
                FirstMateSimulatorDeviceStage(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .composerLayoutMeasurement(id: "first-mate-simulator-stage")
                if let notice = session.notice {
                    Text(notice)
                        .herdrFont(.footnote).foregroundStyle(HerdrTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(HerdrTheme.windowBackground.opacity(0.9), in: .capsule)
                        .accessibilityIdentifier("first-mate-simulator-notice")
                }
                FirstMateSimulatorControls(session: session)
                Text(note)
                    .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("first-mate-simulator-note")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { FirstMateSimulatorBackdrop().ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
    }

    private var note: String {
        var text = "Streams from SimPortal on \(session.machineName) through the companion. Touches and typing go straight to the simulator."
        let minutes = session.preview?.idle?.shutdownAfterMinutes ?? session.status?.policy?.idleShutdownMinutes ?? 0
        if minutes > 0 {
            text += " Idle simulators shut down after \(FirstMateSimulatorPolicyText.duration(minutes: minutes))."
        }
        return text
    }
}

/// The prototype's backdrop: a violet glow over near-black.
private struct FirstMateSimulatorBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 16 / 255, green: 16 / 255, blue: 20 / 255)
            GeometryReader { proxy in
                RadialGradient(colors: [Color(red: 132 / 255, green: 98 / 255, blue: 222 / 255).opacity(0.16), .clear],
                               center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0,
                               endRadius: max(proxy.size.width, proxy.size.height) * 0.55)
            }
        }
    }
}

// MARK: - Bar

private struct FirstMateSimulatorCoverBar: View {
    let session: FirstMateSimulatorSession
    let compact: Bool
    let done: () -> Void
    @AppStorage("herdr.ios.firstMate.simulator.browserFocusNoticeSuppressed") private var focusNoticeSuppressed = false
    @State private var confirmingBrowser = false
    @State private var demoNotice = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Button("Done", action: done)
                .buttonStyle(FirstMateSimulatorPillStyle(prominent: true))
                .accessibilityIdentifier("first-mate-simulator-done")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .herdrFont(size: 16, weight: .semibold, relativeTo: .headline)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                // Compact width drops "Simulator" and wraps rather than cutting the device out.
                Text(compact ? subtitleParts.dropFirst().joined(separator: " · ") : subtitleParts.joined(separator: " · "))
                    .herdrFont(size: 12, monospaced: !compact, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
                    .lineLimit(compact ? 2 : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if compact { FirstMateSimulatorStateLabel(session: session) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("first-mate-simulator-identity")
            if !compact { FirstMateSimulatorStateLabel(session: session) }
            browserButton
            Button(role: .destructive) {
                Task { await session.stop() }
            } label: {
                Label("Stop", systemImage: "stop")
            }
            .buttonStyle(FirstMateSimulatorPillStyle(iconOnly: compact, tint: HerdrTheme.alert))
            .disabled(!canStop || session.isSubmitting)
            .accessibilityLabel("Stop simulator")
            .accessibilityHint("Shuts this simulator down. Its data and the saved build are kept.")
            .accessibilityIdentifier("first-mate-simulator-stop")
        }
        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Color(red: 26 / 255, green: 24 / 255, blue: 35 / 255).opacity(0.98)
                .ignoresSafeArea(edges: .top)
        }
        .herdrHairline(.bottom)
        .composerLayoutMeasurement(id: "first-mate-simulator-bar")
        .confirmationDialog("Open this simulator in SimPortal?", isPresented: $confirmingBrowser, titleVisibility: .visible) {
            Button("Open in SimPortal") { openBrowser() }
            Button("Open, and Don't Ask Again") {
                focusNoticeSuppressed = true
                openBrowser()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SimPortal's browser viewer makes this simulator its focused simulator, the one agents use when they don't name a device. Watching here doesn't change focus.")
        }
        .alert("Demo simulator", isPresented: $demoNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This opens the simulator in SimPortal's browser viewer on \(session.machineName). The demo simulator is synthetic and has no SimPortal.")
        }
    }

    private var browserButton: some View {
        Button {
            if session.isDemo {
                demoNotice = true
            } else if focusNoticeSuppressed {
                openBrowser()
            } else {
                confirmingBrowser = true
            }
        } label: {
            Label("Open in SimPortal", systemImage: "globe")
        }
        .buttonStyle(FirstMateSimulatorPillStyle(iconOnly: compact))
        .disabled(session.browserURL == nil)
        .accessibilityHint(session.browserURL == nil ? browserUnavailableReason : "Opens SimPortal's browser viewer for this exact simulator")
        .accessibilityIdentifier("first-mate-simulator-open-browser")
    }

    /// "Receipts 2.4 (118)" for a Mobile App Hub build's copy, else the checkpoint's label.
    private var title: String {
        guard let build = session.build else { return "Simulator" }
        return build.hubBuildID != nil ? (build.appLabel ?? build.checkpointLabel) : build.checkpointLabel
    }

    /// "Simulator · iPhone 17 Pro · iOS 26.2 · Mac Studio"
    private var subtitleParts: [String] {
        let device = session.preview?.device ?? session.status?.defaultDevice
        return (["Simulator", device?.deviceTypeName, device?.runtimeName, session.machineName] as [String?]).compactMap { $0 }
    }

    private var canStop: Bool {
        switch session.phase {
        case .starting, .running: true
        case .failed, .unavailable: session.preview?.observation?.deviceState == "Booted"
        default: false
        }
    }

    private var browserUnavailableReason: String {
        if session.preview?.udid == nil { return "Available once the simulator is created." }
        return "SimPortal on \(session.machineName) has no tailnet link this device can open. Enable its tailnet link there (simportal tailscale enable)."
    }

    private func openBrowser() {
        guard let url = session.browserURL, FirstMateLinkURL.validated(url.absoluteString) != nil else { return }
        openURL(url)
    }
}

/// Starting, Booting, Installing, Launching, Running… from the companion's preview.
private struct FirstMateSimulatorStateLabel: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        let (title, color) = presentation
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title)
                .herdrFont(.footnote, weight: .semibold)
                .foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Simulator \(title)")
        .accessibilityIdentifier("first-mate-simulator-status")
    }

    private var presentation: (String, Color) {
        switch session.phase {
        case .opening: ("Starting", HerdrTheme.working)
        case .starting:
            switch session.preview?.operation?.step {
            case "booting": ("Booting", HerdrTheme.working)
            case "installing": ("Installing", HerdrTheme.working)
            case "launching", "checking_stream": ("Launching", HerdrTheme.working)
            default: ("Starting", HerdrTheme.working)
            }
        case .stopping: ("Shutting down", HerdrTheme.working)
        case .stopped: (session.simulatorDeleted ? "Deleted" : "Shut down", HerdrTheme.tertiaryText)
        case .failed: ("Failed", HerdrTheme.alert)
        case .unavailable: ("Unavailable", HerdrTheme.warning)
        case .running:
            if session.isDemo { ("Running", HerdrTheme.success) }
            else if session.isPausedWhileHidden { ("Paused", HerdrTheme.tertiaryText) }
            else {
                switch session.stream?.state {
                case .live: ("Running", HerdrTheme.success)
                case .reconnecting, .connecting, .waitingForDevice, .none, .idle: ("Connecting", HerdrTheme.working)
                case .paused: ("Paused", HerdrTheme.tertiaryText)
                case .ended, .failed: ("Disconnected", HerdrTheme.warning)
                }
            }
        }
    }
}

/// The prototype's round pills: 38 pt to see, 44 pt to tap; icon only on compact width.
private struct FirstMateSimulatorPillStyle: ButtonStyle {
    var prominent = false
    var iconOnly = false
    var tint: Color = HerdrTheme.primaryText

    func makeBody(configuration: Configuration) -> some View {
        FirstMateSimulatorPill(configuration: configuration, prominent: prominent, iconOnly: iconOnly, tint: tint)
    }
}

private struct FirstMateSimulatorPill: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let iconOnly: Bool
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Group {
            if iconOnly {
                configuration.label.labelStyle(.iconOnly).frame(width: 38)
            } else {
                configuration.label.labelStyle(.titleAndIcon).padding(.horizontal, prominent ? 16 : 14)
            }
        }
        .herdrFont(size: prominent ? 15 : 14, weight: .semibold, relativeTo: .subheadline)
        .foregroundStyle(tint)
        .lineLimit(1)
        .frame(height: 38)
        .background(configuration.isPressed ? HerdrTheme.inkFill(0.16) : HerdrTheme.inkFill(prominent ? 0.10 : 0.06), in: .capsule)
        .overlay { if !prominent { Capsule().strokeBorder(HerdrTheme.outline, lineWidth: 1) } }
        .opacity(enabled ? 1 : 0.42)
        .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
        .contentShape(.rect)
        .fixedSize()
    }
}

// MARK: - Controls

/// The buttons SimPortal's viewer protocol supports (Home and the side
/// button), and typing for a device without a hardware keyboard.
private struct FirstMateSimulatorControls: View {
    let session: FirstMateSimulatorSession
    @State private var typing = false
    @State private var text = ""

    private var acceptsInput: Bool {
        session.phase == .running && (session.isDemo || session.stream?.acceptsInput == true)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { session.stream?.pressButton(.home) } label: { Label("Home", systemImage: "house") }
                .accessibilityIdentifier("first-mate-simulator-home")
            Button { session.stream?.pressButton(.lock) } label: { Label("Lock", systemImage: "lock") }
                .accessibilityLabel("Side button")
                .accessibilityIdentifier("first-mate-simulator-lock")
            Button { typing = true } label: { Label("Type", systemImage: "keyboard") }
                .accessibilityLabel("Type into the simulator")
                .accessibilityIdentifier("first-mate-simulator-type")
        }
        .buttonStyle(FirstMateSimulatorPillStyle())
        .disabled(!acceptsInput)
        .composerLayoutMeasurement(id: "first-mate-simulator-controls")
        .alert("Type into the simulator", isPresented: $typing) {
            TextField("Text", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send") {
                session.stream?.send(.text(text))
                text = ""
            }
            Button("Cancel", role: .cancel) { text = "" }
        } message: {
            Text("The text goes to the field that has focus in the simulator.")
        }
    }
}

// MARK: - Device

/// The device, fitted to the space, with whatever the simulator is doing on top.
private struct FirstMateSimulatorDeviceStage: View {
    let session: FirstMateSimulatorSession

    var body: some View {
        GeometryReader { proxy in
            let screen = screenSize(in: proxy.size)
            let bezel = max(6, min(12, screen.width * 0.03))
            let radius = screenRadius(width: screen.width)
            ZStack {
                RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                    .fill(Color(red: 10 / 255, green: 10 / 255, blue: 13 / 255))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                            .strokeBorder(Color(red: 43 / 255, green: 43 / 255, blue: 51 / 255), lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
                    .frame(width: screen.width + bezel * 2, height: screen.height + bezel * 2)
                screenContent
                    .frame(width: screen.width, height: screen.height)
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                    .overlay { FirstMateSimulatorScreenOverlay(session: session, radius: radius) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var screenContent: some View {
        if let frame = session.demoFrame {
            Image(decorative: frame, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .accessibilityLabel("Simulator screen")
                .accessibilityIdentifier("first-mate-simulator-screen")
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
        let height = max(1, available.height - 28)
        let width = max(1, available.width - 28)
        return width / height > aspect ? CGSize(width: height * aspect, height: height) : CGSize(width: width, height: width / aspect)
    }

    private func screenRadius(width: CGFloat) -> CGFloat {
        if let fraction = session.stream?.device?.cornerRadiusFraction {
            return width * CGFloat(fraction)
        }
        return width * (aspect > 0.6 ? 0.035 : 0.13)
    }
}

/// Loading steps, an in-progress chip, or a stopped, failed or unavailable card over the screen.
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
                    card { stateMessage(symbol: "pause.circle", title: "Paused while in the background",
                                        message: "Come back to resume the picture.") }
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
            EmptyView()
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
                .padding(14)
        }
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).tint(HerdrTheme.primaryText)
            Text(text)
                .herdrFont(.footnote, weight: .medium)
                .foregroundStyle(HerdrTheme.primaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(HerdrTheme.windowBackground.opacity(0.88), in: .capsule)
        .overlay { Capsule().strokeBorder(HerdrTheme.outline) }
        .accessibilityElement(children: .combine)
    }

    private func stateMessage(symbol: String, title: String, message: String?) -> some View {
        stateMessage(symbol: symbol, title: title, message: message) { EmptyView() }
    }

    private func stateMessage<Actions: View>(symbol: String, title: String, message: String?,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(title)
                .herdrFont(.body, weight: .semibold)
                .foregroundStyle(HerdrTheme.primaryText)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .herdrFont(.footnote)
                    .foregroundStyle(HerdrTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-simulator-state")
    }
}

/// SimPortal's start steps with the current one spinning.
private struct FirstMateSimulatorProgressCard: View {
    let title: String
    let device: String?
    let steps: [FirstMateSimulatorPreview.Step]
    let current: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .herdrFont(.body, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                if let device {
                    Text(device)
                        .herdrFont(.footnote)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            if steps.isEmpty {
                ProgressView().controlSize(.small).tint(HerdrTheme.primaryText)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(steps, id: \.name) { step in
                        HStack(spacing: 8) {
                            stepIcon(step).frame(width: 16, height: 16)
                            Text(FirstMateSimulatorStepText.title(for: step.name))
                                .herdrFont(.footnote, weight: step.name == current ? .semibold : .regular)
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
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(HerdrTheme.success)
        case "running":
            ProgressView().controlSize(.mini).tint(HerdrTheme.primaryText)
        case "failed", "unknown":
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(HerdrTheme.alert)
        case "skipped":
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(HerdrTheme.tertiaryText)
        default:
            Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(HerdrTheme.tertiaryText)
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
                    FirstMateRunningDot()
                    Text(preview.device?.label ?? "Simulator")
                    Text(preview.phase == "starting" ? "starting" : "in use")
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
                .herdrFont(.footnote)
                .foregroundStyle(HerdrTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
