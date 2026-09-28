import AppKit
import Observation
import SwiftUI

/// The First Mate HUD: a floating panel with First Mate's face, a row of
/// feature orbs, and a list that opens under it.
///
/// It is separate from the agent HUD (`HerdrHudController`): its own panel,
/// switch (``FirstMateHudPreferences/enabledKey``), place, and state. It reads
/// the process-wide First Mate fleet index, so it adds no poller of its own; it
/// only keeps the fleet driver at its active 10 s poll while it shows. It belongs to
/// the process (`HerdrShellState`), so it keeps running with every window
/// closed.
@MainActor @Observable
final class FirstMateHudController {
    /// What opens beside the HUD. Only one card shows at a time.
    enum Card: Equatable {
        /// The hover readout for a feature.
        case readout(FirstMateFleetFeatureID)
        /// The hover list of tucked features (the "+N" orb or summary row).
        case tucked
        /// A feature's newest First Mate message, with a reply box.
        case message(FirstMateFleetFeatureID)
        /// Rename a feature or change its emoji.
        case editor(FirstMateFleetFeatureID)
        /// Type to First Mate.
        case chat
        /// First Mate's latest line beside the face.
        case latestLine
    }

    enum VoicePhase: Equatable {
        case idle
        /// The press is filling the rose ring; listening starts at 0.42 s.
        case pressing(Date)
        case listening
        case transcribing
        /// The words heard, shown briefly before they are sent.
        case heard(String)

        /// Listening, transcribing, and the words heard show a caption.
        var showsCaption: Bool {
            switch self {
            case .listening, .transcribing, .heard: true
            case .idle, .pressing: false
            }
        }
    }

    /// First Mate's latest line: a soft note (it fades) or a feature's new
    /// message (it stays until read).
    struct LatestLine: Equatable {
        var text: String
        var featureID: FirstMateFleetFeatureID?
        var expiresAt: Date?
    }

    struct ChatLine: Identifiable, Equatable {
        enum Role: Equatable { case person, firstMate }
        let id = UUID()
        let role: Role
        let text: String
    }

    static let holdDelay: Duration = .milliseconds(420)
    static let hoverDelay: Duration = .milliseconds(220)
    static let hoverGrace: Duration = .milliseconds(180)
    static let softNoteDuration: TimeInterval = 5.5
    static let speakingDuration: TimeInterval = 1.3
    /// The fleet's poll while the HUD shows. The spec's 5 s assumed a
    /// summary-only poll; each poll also fetches every machine's feature
    /// list, so the HUD keeps the active-app rate instead of dropping to
    /// 30 s while another app is in front.
    static let hudPollingInterval: Duration = .seconds(10)
    static let cardSizes: [String: CGSize] = [
        "readout": CGSize(width: 300, height: 262),
        "message": CGSize(width: 320, height: 292),
        "editor": CGSize(width: 300, height: 176),
        "chat": CGSize(width: 352, height: 420),
        "latestLine": CGSize(width: 290, height: 104),
    ]

    // MARK: State the views read

    private(set) var items: [FirstMateHudItem] = []
    private(set) var isExpanded: Bool
    private(set) var showsAllMoving = false
    private(set) var hoverCard: Card?
    private(set) var explicitCard: Card?
    private(set) var latestLine: LatestLine?
    private(set) var layout: FirstMateHudGeometry.Output
    /// Listening shows its caption beside the face, so the panel follows it.
    private(set) var voicePhase: VoicePhase = .idle {
        didSet { if oldValue.showsCaption != voicePhase.showsCaption { relayout() } }
    }
    /// The feature a message card's mic talks to; nil routes the words.
    private(set) var voiceTarget: FirstMateFleetFeatureID?
    private(set) var isThinking = false
    private(set) var speakingUntil: Date?
    /// Where the eyes look, up to 2.4 pt from center.
    private(set) var gaze: CGVector = .zero
    private(set) var chatLines: [ChatLine] = []
    private(set) var notice: String?
    var chatDraft = ""
    var replyDraft = ""
    var editorLabel = ""
    var editorEmoji = ""
    /// Bumped to move keyboard focus into the open card's field.
    private(set) var focusRequest = 0
    private(set) var isVisible = false

    /// Opens a feature's session in the app (the chat window when its preview
    /// is on, else the main window's First Mate screen). Set by whichever
    /// window appears first, because opening a window needs SwiftUI.
    @ObservationIgnored var openConversation: ((FirstMateFleetFeatureID) -> Void)?

    // MARK: Plumbing

    @ObservationIgnored private weak var model: HerdrAppModel?
    @ObservationIgnored private weak var shell: HerdrShellState?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isInert: Bool
    @ObservationIgnored private var panel: HerdrHudPanel?
    @ObservationIgnored private var faceCenter: CGPoint?
    @ObservationIgnored private var isDraggingPanel = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var mouseMonitors: [Any] = []
    @ObservationIgnored private var lastGazeUpdate = Date.distantPast
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var latestLineTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var speakingTask: Task<Void, Never>?
    /// Transcribing and sending what was heard; Esc cancels it.
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    @ObservationIgnored private var seenMessages: Set<String> = []
    @ObservationIgnored private var hasLoadedItems = false
    @ObservationIgnored private var demoPresentation: [String: (label: String, emoji: String)] = [:]
    @ObservationIgnored private let voice = HerdrQuickVoiceCapture()
    @ObservationIgnored private var isStarted = false
    /// Demo mode's fleet size (`-HerdrFirstMateHudDemoCount`).
    @ObservationIgnored var demoCount: Int? = FirstMateHudPreferences.demoCount()
    /// Offscreen renders place the HUD on this frame instead of a screen.
    @ObservationIgnored private var renderVisibleFrame: CGRect?
    /// Offscreen renders never create a panel.
    @ObservationIgnored private var isRenderingOnly = false

    var voiceSamples: [CGFloat] { voice.samples }

    init(defaults: UserDefaults = .standard, isInert: Bool = FirstMateFleetDriver.isHostedByTests) {
        self.defaults = defaults
        self.isInert = isInert
        isExpanded = defaults.bool(forKey: FirstMateHudPreferences.expandedKey)
        layout = FirstMateHudGeometry.layout(.init(
            faceCenter: .zero, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            column: .collapsed(orbCount: 0), card: nil))
    }

    var isEnabled: Bool { FirstMateHudPreferences.isEnabled(defaults) }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: FirstMateHudPreferences.enabledKey)
        syncVisibility()
    }

    // MARK: Derived

    var collapsed: FirstMateHudOverflow.Collapsed { FirstMateHudOverflow.collapsed(items) }
    var expanded: FirstMateHudOverflow.Expanded { FirstMateHudOverflow.expanded(items, showAllMoving: showsAllMoving) }
    var badge: FirstMateHudBadge.Value? { FirstMateHudBadge.value(items) }

    /// The card showing: an explicit one wins over a hover, which wins over
    /// the latest line.
    var visibleCard: Card? {
        if let explicitCard { return explicitCard }
        // Talking to First Mate shows its caption where the latest line goes.
        if voicePhase.showsCaption { return .latestLine }
        if let hoverCard { return hoverCard }
        return latestLine == nil ? nil : .latestLine
    }

    var isListening: Bool { voicePhase == .listening }
    var isSpeaking: Bool { speakingUntil.map { $0 > Date() } ?? false }

    func item(_ id: FirstMateFleetFeatureID) -> FirstMateHudItem? { items.first { $0.id == id } }

    /// The features behind "+N" (collapsed) or the summary row (expanded).
    var tuckedItems: [FirstMateHudItem] {
        isExpanded ? expanded.summary?.tucked ?? [] : collapsed.tucked
    }

    var isDemo: Bool { model?.isDemoMode ?? false }

    /// Cards name the machine when features come from more than one.
    var showsMachineNames: Bool { Set(items.map(\.id.machineID)).count > 1 }

    // MARK: Lifecycle

    /// Idempotent: the main window and the chat window both call it.
    func start(model: HerdrAppModel, shell: HerdrShellState) {
        self.model = model
        self.shell = shell
        // The isolated First Mate recording shows no floating panels, like the
        // agent HUD.
        guard !isInert, !isStarted, !ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateDemo") else { return }
        isStarted = true
        trackItems()
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncVisibility() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Re-place the face from its saved point on the new screens.
                    self?.faceCenter = nil
                    self?.relayout()
                }
            },
        ]
        syncVisibility()
    }

    /// Shows the panel while it is on and some machine has First Mate (or in
    /// demo mode), so a Mac without First Mate never gets a lone face.
    private func syncVisibility() {
        guard isStarted, !isRenderingOnly else { return }
        if isEnabled && hasFirstMate {
            show()
        } else {
            hide()
        }
    }

    /// A machine whose companion answered with First Mate. In demo mode, only
    /// when asked for (the switch set explicitly, or a demo fleet size), so UI
    /// tests and demo recordings get no floating panel.
    private var hasFirstMate: Bool {
        guard let model, let shell else { return false }
        if model.isDemoMode {
            return demoCount != nil || defaults.object(forKey: FirstMateHudPreferences.enabledKey) != nil
        }
        return shell.firstMateFleet.hosts.contains { !$0.unsupported && $0.lastUpdated != nil }
    }

    private func show() {
        let panel = panel ?? makePanel()
        if !isVisible {
            isVisible = true
            reloadItems()
            relayout()
            panel.orderFrontRegardless()
            installMouseMonitors()
            shell?.firstMateFleetDriver?.setHudPolling(Self.hudPollingInterval)
            lingerTask = Task { [weak self] in
                // Merged features leave after two minutes even with no fleet change.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.reloadItems()
                }
            }
        }
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        cancelVoice()
        closeCards()
        panel?.orderOut(nil)
        removeMouseMonitors()
        shell?.firstMateFleetDriver?.setHudPolling(nil)
        lingerTask?.cancel()
        lingerTask = nil
    }

    private func makePanel() -> HerdrHudPanel {
        let panel = HerdrHudPanel(contentRect: layout.panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.title = "First Mate HUD"
        panel.setAccessibilityLabel("First Mate HUD")
        panel.onCancel = { [weak self] in self?.handleEscape() }
        panel.contentView = NSHostingView(rootView: FirstMateHudRootView(controller: self))
        self.panel = panel
        return panel
    }

    // MARK: Items

    /// Rebuilds the items whenever the fleet, the read markers, or the demo
    /// change.
    private func trackItems() {
        withObservationTracking {
            reloadItems()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackItems() }
        }
    }

    private func hosts() -> [FirstMateFleetHost] {
        guard let model, let shell else { return [] }
        guard model.isDemoMode else { return shell.firstMateFleet.hosts }
        var host = FirstMateHudDemo.host(base: shell.firstMateChatDemo.host, count: demoCount, now: shell.firstMateChatDemo.now)
        if var entries = host.fleetEntries, !demoPresentation.isEmpty {
            for (id, presentation) in demoPresentation {
                entries[id]?.label = presentation.label
                entries[id]?.emoji = presentation.emoji
            }
            host.fleetEntries = entries
        }
        return [host]
    }

    private func reloadItems() {
        guard let shell else { return }
        // The roster can gain or lose its First Mate machines.
        syncVisibility()
        let next = FirstMateHudRoster.items(hosts: hosts(), readState: shell.firstMateFleet.readState, now: Date())
        guard next != items else { return }
        let previous = items
        items = next
        noticeNewMessages(previous: previous)
        // A card whose feature left closes.
        for card in [explicitCard, hoverCard].compactMap({ $0 }) {
            switch card {
            case .readout(let id), .message(let id), .editor(let id):
                if item(id) == nil { closeCard(card) }
            case .tucked:
                if tuckedItems.isEmpty { closeCard(card) }
            case .chat, .latestLine:
                break
            }
        }
        if let line = latestLine, let id = line.featureID, item(id)?.showsDot != true {
            clearLatestLine()
        }
        relayout()
    }

    /// First Mate's latest line: a summary once the first list lands, then
    /// each new unread message from a feature that needs you.
    private func noticeNewMessages(previous: [FirstMateHudItem]) {
        let unread = items.filter(\.showsDot)
        let keys = unread.map { "\($0.id.machineID)/\($0.id.featureID)/\($0.conversation.latestFirstMateMessageID ?? "")" }
        defer { seenMessages.formUnion(keys) }
        guard hasLoadedItems else {
            hasLoadedItems = !items.isEmpty
            if items.contains(where: \.needsYou) {
                showLatestLine(LatestLine(text: FirstMateHudRouting.summary(items), featureID: nil,
                                          expiresAt: Date().addingTimeInterval(Self.softNoteDuration)))
            }
            return
        }
        guard let newest = zip(unread, keys).first(where: { !seenMessages.contains($0.1) })?.0 else { return }
        let text = newest.conversation.previewText.isEmpty ? FirstMateHudRouting.phrase(newest) + "." : newest.conversation.previewText
        showLatestLine(LatestLine(text: text, featureID: newest.id, expiresAt: nil))
    }

    private func showLatestLine(_ line: LatestLine) {
        latestLine = line
        latestLineTask?.cancel()
        relayout()
        guard let expiresAt = line.expiresAt else { return }
        latestLineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.latestLine == line else { return }
            self.clearLatestLine()
        }
    }

    func clearLatestLine() {
        latestLineTask?.cancel()
        latestLine = nil
        relayout()
    }

    // MARK: Layout

    /// The visible frame of the screen the face is on, or of the main screen
    /// when it is on none (a display was unplugged).
    private func visibleFrame(containing point: CGPoint?) -> CGRect {
        if let renderVisibleFrame { return renderVisibleFrame }
        if let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen.visibleFrame }
        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    #if DEBUG
    /// Offscreen renders and tests: loads the items and lays the HUD out on
    /// `visibleFrame` with the face at `face`, with no panel, polling, or
    /// pointer tracking.
    func prepareForRendering(model: HerdrAppModel, shell: HerdrShellState, visibleFrame: CGRect, face: CGPoint) {
        self.model = model
        self.shell = shell
        renderVisibleFrame = visibleFrame
        faceCenter = face
        isStarted = true
        isRenderingOnly = true
        reloadItems()
        relayout()
    }

    /// Renders the talking states without a microphone.
    func setVoicePhaseForRendering(_ phase: VoicePhase) {
        voicePhase = phase
        relayout()
    }
    #endif

    /// The saved face point, when it is still on a screen; otherwise the
    /// default place on the main screen.
    private func savedFace() -> CGPoint {
        if let values = defaults.array(forKey: FirstMateHudPreferences.faceKey) as? [NSNumber], values.count == 2 {
            let point = CGPoint(x: values[0].doubleValue, y: values[1].doubleValue)
            if NSScreen.screens.contains(where: { $0.frame.contains(point) }) { return point }
        }
        return FirstMateHudGeometry.defaultFace(visibleFrame: visibleFrame(containing: nil))
    }

    private func saveFace(_ face: CGPoint) {
        defaults.set([face.x, face.y], forKey: FirstMateHudPreferences.faceKey)
    }

    /// The card's size and where its top wants to be.
    private func cardInput(for card: Card) -> FirstMateHudGeometry.Card {
        let key: String
        var anchor = -FirstMateHudGeometry.faceRadius + 4
        switch card {
        case .readout(let id), .message(let id), .editor(let id):
            key = card == .readout(id) ? "readout" : card == .message(id) ? "message" : "editor"
            if let y = anchorY(for: id) { anchor = y - 24 }
        case .tucked:
            key = "readout"
            anchor = (isExpanded ? summaryRowCenterY() : FirstMateHudGeometry.orbRowDrop) - 24
        case .chat:
            key = "chat"
        case .latestLine:
            key = "latestLine"
        }
        var size = Self.cardSizes[key] ?? CGSize(width: 300, height: 240)
        if card == .tucked {
            size.height = min(76 + CGFloat(tuckedItems.count) * 36, 560)
        }
        return .init(size: size, anchorY: anchor)
    }

    /// A feature's row or orb center, below the face center.
    func anchorY(for id: FirstMateFleetFeatureID) -> CGFloat? {
        guard isExpanded else {
            return collapsed.orbs.contains { $0.id == id } || collapsed.tucked.contains { $0.id == id }
                ? FirstMateHudGeometry.orbRowDrop : nil
        }
        return rowCenters()[id]
    }

    /// Each expanded row's center below the face center, before scrolling.
    func rowCenters() -> [FirstMateFleetFeatureID: CGFloat] {
        let layout = expanded
        var y = FirstMateHudGeometry.listTop
        var centers: [FirstMateFleetFeatureID: CGFloat] = [:]
        for item in layout.needsYou {
            centers[item.id] = y + FirstMateHudGeometry.slatHeight / 2
            y += FirstMateHudGeometry.rowPitch
        }
        if !layout.needsYou.isEmpty, !layout.moving.isEmpty || layout.summary != nil { y += FirstMateHudGeometry.groupGap }
        for item in layout.moving {
            let height = layout.movingAreCompact ? FirstMateHudGeometry.compactHeight : FirstMateHudGeometry.slatHeight
            centers[item.id] = y + height / 2
            y += layout.movingAreCompact ? FirstMateHudGeometry.compactPitch : FirstMateHudGeometry.rowPitch
        }
        return centers
    }

    private func summaryRowCenterY() -> CGFloat {
        FirstMateHudGeometry.listTop + FirstMateHudGeometry.listContentHeight(expanded) - FirstMateHudGeometry.rowPitch
            + FirstMateHudGeometry.slatHeight / 2
    }

    func relayout() {
        guard isStarted, !isDraggingPanel else { return }
        let wanted = faceCenter ?? savedFace()
        let visible = visibleFrame(containing: wanted)
        let face = FirstMateHudGeometry.clampFace(wanted, visibleFrame: visible)
        faceCenter = face
        let column: FirstMateHudGeometry.Column = isExpanded
            ? .expanded(contentHeight: FirstMateHudGeometry.listContentHeight(expanded))
            : .collapsed(orbCount: collapsed.orbs.count + (collapsed.hasMore ? 1 : 0))
        let next = FirstMateHudGeometry.layout(.init(
            faceCenter: face, visibleFrame: visible, column: column, card: visibleCard.map(cardInput)))
        if next != layout { layout = next }
        if let panel, panel.frame != next.panelFrame {
            // Not displayed now: the content and the frame change in the same
            // pass, so the face never draws in its old spot.
            panel.setFrame(next.panelFrame, display: false)
        }
    }

    // MARK: Face gestures

    func facePressBegan() {
        guard voicePhase == .idle else { return }
        voicePhase = .pressing(Date())
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, case .pressing = self.voicePhase else { return }
            self.startListening()
        }
    }

    /// A press that ended before listening started is a click: open the chat.
    func facePressEnded() {
        holdTask?.cancel()
        holdTask = nil
        switch voicePhase {
        case .pressing:
            voicePhase = .idle
            toggleChat()
        case .listening:
            finishListening()
        default:
            break
        }
    }

    /// A press may still become a drag; talking may not.
    var canDragFace: Bool {
        switch voicePhase {
        case .idle, .pressing: true
        case .listening, .transcribing, .heard: false
        }
    }

    /// A drag moves the whole HUD; it cancels any press.
    func faceDragBegan() {
        holdTask?.cancel()
        if case .pressing = voicePhase { voicePhase = .idle }
        isDraggingPanel = true
        hoverTask?.cancel()
        hoverCard = nil
    }

    func faceDragEnded() {
        isDraggingPanel = false
        guard let panel else { return }
        let frame = panel.frame
        let dropped = CGPoint(x: frame.minX + layout.faceCenter.x, y: frame.maxY - layout.faceCenter.y)
        let face = FirstMateHudGeometry.clampFace(dropped, visibleFrame: visibleFrame(containing: dropped))
        faceCenter = face
        saveFace(face)
        relayout()
    }

    // MARK: Voice

    /// The message card's mic: hold to talk to that feature; letting go sends.
    func micPressBegan(target: FirstMateFleetFeatureID) {
        guard voicePhase == .idle else { return }
        voiceTarget = target
        voicePhase = .pressing(Date())
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, case .pressing = self.voicePhase else { return }
            self.voicePhase = .listening
            self.voice.beginHold()
        }
    }

    func micPressEnded() {
        holdTask?.cancel()
        holdTask = nil
        switch voicePhase {
        case .pressing:
            voicePhase = .idle
            voiceTarget = nil
            showNotice("Hold the mic to talk.")
        case .listening:
            finishListening()
        default:
            break
        }
    }

    private func startListening() {
        voiceTarget = nil
        explicitCard = explicitCard == .chat ? .chat : nil
        hoverCard = nil
        voicePhase = .listening
        voice.beginHold()
        relayout()
    }

    private func finishListening() {
        voicePhase = .transcribing
        let target = voiceTarget
        voiceTarget = nil
        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            guard let self else { return }
            let model = self.model
            let outcome = await self.voice.endHold { url in
                guard let model else { throw CancellationError() }
                return try await model.transcribeVoiceNote(at: url)
            }
            // Esc while transcribing or showing the words sends nothing.
            guard !Task.isCancelled else { return }
            switch outcome {
            case .transcript(let transcription):
                let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { self.voicePhase = .idle; self.showNotice("I didn't catch that."); return }
                self.voicePhase = .heard(text)
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self.voicePhase = .idle
                if let target {
                    let typed = self.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.replyDraft = typed.isEmpty ? text : typed + " " + text
                    self.submitReply(to: target)
                } else {
                    await self.submit(text)
                }
            case .tooShort:
                self.voicePhase = .idle
                self.showNotice("Hold a little longer to talk.")
            case .failure(let message):
                self.voicePhase = .idle
                self.showNotice(message)
            case .cancelled:
                self.voicePhase = .idle
            }
        }
    }

    /// Stops talking at any point: listening discards the recording, and
    /// transcribing or showing the words sends nothing.
    func cancelVoice() {
        holdTask?.cancel()
        holdTask = nil
        if voicePhase == .listening { voice.cancel() }
        voiceTask?.cancel()
        voiceTask = nil
        voiceTarget = nil
        voicePhase = .idle
    }

    // MARK: Cards

    func toggleChat() {
        if explicitCard == .chat {
            closeCard(.chat)
        } else {
            openExplicit(.chat)
        }
    }

    func openExplicit(_ card: Card) {
        hoverTask?.cancel()
        hoverCard = nil
        explicitCard = card
        if case .message(let id) = card { markRead(id) }
        if case .editor(let id) = card, let item = item(id) {
            editorLabel = item.label
            editorEmoji = item.emoji
        }
        if case .message = card { replyDraft = "" }
        relayout()
        panel?.makeKeyAndOrderFront(nil)
        focusRequest &+= 1
    }

    func closeCard(_ card: Card) {
        if explicitCard == card { explicitCard = nil }
        if hoverCard == card { hoverCard = nil }
        if card == .latestLine { clearLatestLine(); return }
        relayout()
    }

    func closeCards() {
        hoverTask?.cancel()
        explicitCard = nil
        hoverCard = nil
        relayout()
    }

    /// Hovering a row, orb, or the card itself. The readout opens after
    /// 220 ms and closes 180 ms after the pointer leaves everything.
    func hover(_ card: Card?, isInside: Bool) {
        hoverTask?.cancel()
        guard !isDraggingPanel, explicitCard == nil else { return }
        if isInside, let card {
            if hoverCard == card { return }
            let delay = hoverCard == nil ? Self.hoverDelay : .milliseconds(60)
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.explicitCard == nil else { return }
                self.hoverCard = card
                self.relayout()
            }
        } else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Self.hoverGrace)
                guard !Task.isCancelled, let self else { return }
                self.hoverCard = nil
                self.relayout()
            }
        }
    }

    /// The pointer is over the open hover card: keep it.
    func holdHoverCard() {
        hoverTask?.cancel()
    }

    /// Esc steps back: editor, then listening, then a card, then the chat,
    /// then the list.
    func handleEscape() {
        if case .editor = explicitCard {
            explicitCard = nil
            relayout()
        } else if voicePhase != .idle {
            cancelVoice()
        } else if let card = explicitCard, card != .chat {
            closeCard(card)
        } else if hoverCard != nil {
            hoverCard = nil
            relayout()
        } else if explicitCard == .chat {
            closeCard(.chat)
        } else if latestLine != nil {
            clearLatestLine()
        } else if isExpanded {
            setExpanded(false)
        }
    }

    // MARK: List

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        if !expanded { showsAllMoving = false }
        defaults.set(expanded, forKey: FirstMateHudPreferences.expandedKey)
        hoverTask?.cancel()
        hoverCard = nil
        relayout()
    }

    func toggleShowAllMoving() {
        hoverTask?.cancel()
        showsAllMoving.toggle()
        hoverCard = nil
        relayout()
    }

    /// "+N": opens the list with every moving row showing.
    func openTucked() {
        hoverTask?.cancel()
        showsAllMoving = true
        hoverCard = nil
        if !isExpanded {
            isExpanded = true
            defaults.set(true, forKey: FirstMateHudPreferences.expandedKey)
        }
        relayout()
    }

    // MARK: Actions

    /// Opens a feature's session in the app and marks its message read.
    func openSession(_ id: FirstMateFleetFeatureID) {
        markRead(id)
        closeCards()
        openConversation?(id)
    }

    /// An orb opens its message when it has an unread dot, else its session.
    func activateOrb(_ id: FirstMateFleetFeatureID) {
        if item(id)?.showsDot == true {
            openExplicit(.message(id))
        } else {
            openSession(id)
        }
    }

    func markRead(_ id: FirstMateFleetFeatureID) {
        guard let shell, let item = item(id), item.conversation.isUnread,
              let through = item.conversation.latestFirstMateMessageID else { return }
        let fleet = shell.firstMateFleet
        Task { await fleet.markRead(machineID: id.machineID, featureID: id.featureID, throughMessageID: through) }
        if latestLine?.featureID == id { clearLatestLine() }
    }

    /// Typed or spoken words: answered here, or sent to the feature they name.
    func submit(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chatLines.append(ChatLine(role: .person, text: trimmed))
        switch FirstMateHudRouting.route(trimmed, items: items) {
        case .answer(let answer):
            reply(answer)
        case .send(let id, let label, let text):
            if await send(text, to: id) {
                reply("Sent to \(label).")
            } else {
                reply("I couldn't send that to \(label). \(notice ?? "Check the connection and try again.")")
            }
        }
    }

    /// The chat panel's send.
    func submitChat() {
        let text = chatDraft
        chatDraft = ""
        Task { await submit(text) }
    }

    /// The message card's reply box.
    func submitReply(to id: FirstMateFleetFeatureID) {
        let text = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let item = item(id) else { return }
        replyDraft = ""
        Task {
            if await send(text, to: id) {
                closeCard(.message(id))
                showLatestLine(LatestLine(text: "Sent to \(item.label).", featureID: nil,
                                          expiresAt: Date().addingTimeInterval(Self.softNoteDuration)))
                speak()
            } else {
                replyDraft = text
            }
        }
    }

    private func reply(_ text: String) {
        chatLines.append(ChatLine(role: .firstMate, text: text))
        if chatLines.count > 40 { chatLines.removeFirst(chatLines.count - 40) }
        speak()
        if explicitCard != .chat {
            showLatestLine(LatestLine(text: text, featureID: nil, expiresAt: Date().addingTimeInterval(Self.softNoteDuration)))
        }
    }

    /// The speaking mouth for 1.3 s, then back to still, so the face stops
    /// redrawing.
    private func speak() {
        speakingUntil = Date().addingTimeInterval(Self.speakingDuration)
        speakingTask?.cancel()
        speakingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.speakingDuration))
            guard !Task.isCancelled else { return }
            self?.speakingUntil = nil
        }
    }

    /// Posts the words to the feature as the person's message.
    func send(_ text: String, to id: FirstMateFleetFeatureID) async -> Bool {
        guard let model, let shell else { return false }
        isThinking = true
        defer { isThinking = false }
        if model.isDemoMode {
            // The chat window's demo store; the HUD's extra demo features
            // have no chat to send to.
            let store = shell.firstMateChatDemo.store
            guard store.snapshots[id.featureID] != nil else {
                showNotice("This demo feature has no chat to send to.")
                return false
            }
            let previous = store.selectedFeatureID
            store.select(id.featureID)
            let sent = await store.sendPreparedMessage(text, expectedContext: store.operationContext)
            if let previous {
                if previous != id.featureID { store.select(previous) }
            } else {
                store.selectedFeatureID = nil
            }
            return sent
        }
        guard let configuration = model.firstMateConfiguration(machineID: id.machineID) else {
            showNotice("That machine isn't connected.")
            return false
        }
        do {
            let snapshot = try await HerdrAPIClient(configuration: configuration)
                .sendFirstMateMessage(featureID: id.featureID, text: text, requestID: UUID().uuidString)
            guard snapshot.ok else { throw APIError.invalidResponse }
            Task {
                await shell.refreshFirstMateStore(machineID: id.machineID)
                await shell.firstMateFleet.refresh()
            }
            return true
        } catch {
            showNotice(error.localizedDescription)
            return false
        }
    }

    /// Saves a new label (24 characters at most) and emoji.
    func saveEditor(for id: FirstMateFleetFeatureID) {
        let label = String(editorLabel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FirstMateHudEditing.labelLimit))
        let emoji = FirstMateHudEditing.firstEmoji(in: editorEmoji)
        guard let model, let shell, let item = item(id), !label.isEmpty else { return }
        closeCard(.editor(id))
        // Only what changed, so a new emoji never pins the default label
        // and a new label never pins the default emoji.
        let newLabel = label == item.label ? nil : label
        let newEmoji = emoji.flatMap { $0 == item.emoji ? nil : $0 }
        guard newLabel != nil || newEmoji != nil else { return }
        if model.isDemoMode {
            demoPresentation[id.featureID] = (newLabel ?? item.label, newEmoji ?? item.emoji)
            reloadItems()
            return
        }
        guard let configuration = model.firstMateConfiguration(machineID: id.machineID) else { return }
        Task {
            do {
                _ = try await HerdrAPIClient(configuration: configuration)
                    .updateFirstMateHud(featureID: id.featureID, label: newLabel, emoji: newEmoji)
                await shell.firstMateFleet.refresh()
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    /// A short note from First Mate, shown as its latest line.
    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
        if explicitCard != .chat {
            showLatestLine(LatestLine(text: text, featureID: nil, expiresAt: Date().addingTimeInterval(Self.softNoteDuration)))
        }
    }

    // MARK: Gaze

    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let handler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.updateGaze() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in handler() }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in handler(); return event }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMouseMonitors() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        gaze = .zero
    }

    /// At most 20 updates a second, and only when the look changes.
    private func updateGaze() {
        let now = Date()
        guard now.timeIntervalSince(lastGazeUpdate) > 0.05, let face = faceCenter, !isDraggingPanel else { return }
        lastGazeUpdate = now
        let next = FirstMateHudFaceMotion.gaze(pointer: NSEvent.mouseLocation, face: face)
        if abs(next.dx - gaze.dx) > 0.1 || abs(next.dy - gaze.dy) > 0.1 { gaze = next }
    }
}

enum FirstMateHudFaceMotion {
    static let maximumGaze: CGFloat = 2.4

    /// The eyes' offset toward the pointer, easing to 2.4 pt at 240 pt away.
    /// SwiftUI y runs down, screen y up.
    static func gaze(pointer: CGPoint, face: CGPoint) -> CGVector {
        let dx = pointer.x - face.x
        let dy = face.y - pointer.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return .zero }
        let reach = min(distance / 240, 1) * maximumGaze
        return CGVector(dx: dx / distance * reach, dy: dy / distance * reach)
    }
}

enum FirstMateHudEditing {
    static let labelLimit = 24

    /// The first emoji in the text (a whole grapheme, so flags and skin tones
    /// survive), or nil when there is none.
    static func firstEmoji(in text: String) -> String? {
        text.first { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }.map(String.init)
    }
}
