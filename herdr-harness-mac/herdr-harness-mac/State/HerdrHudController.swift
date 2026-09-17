import AppKit
import Carbon.HIToolbox
import Observation
import QuartzCore
import SwiftUI

final class HerdrHudPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A `.nonactivatingPanel` is key while another app owns the menu bar, so
    /// AppKit may never offer the event to our own main menu — and Format ▸
    /// Font is where ⌘B/⌘I/⌘U live. Offer it by hand in that case, so the note
    /// editor formats whether or not Herdr happens to be frontmost.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard !NSApp.isActive, let mainMenu = NSApp.mainMenu else { return false }
        return mainMenu.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
@Observable
final class HerdrHudController {
    typealias FocusedWindowSelection = @MainActor (pid_t?) throws -> HerdrFocusedWindowTarget
    typealias FocusedWindowScreenshotCapture = @MainActor (HerdrFocusedWindowTarget) async throws -> URL
    typealias ScreenshotShortcutStateProvider = HerdrDualCommandShortcut.StateProvider

    private enum DefaultsKey {
        static let enabled = "herdr.hud.enabled"
        static let notesVisible = "herdr.hud.notesVisible"
        static let offset = "herdr.hud.offset.v2"
        static let visibleAgentLimit = "herdr.hud.visibleAgentLimit"
        static let chatWidth = "herdr.hud.chatWidth"
        static let chatHeight = "herdr.hud.chatHeight"
        static let ultraCompactEnabled = "herdr.hud.ultraCompactEnabled"
    }

    private let userDefaults: UserDefaults
    private let focusedWindowSelection: FocusedWindowSelection
    private let focusedWindowScreenshotCapture: FocusedWindowScreenshotCapture
    private let screenshotShortcutStateProvider: ScreenshotShortcutStateProvider
    private var panel: HerdrHudPanel?
    private var hotKey: HerdrGlobalHotKey?
    private var screenshotShortcut: HerdrDualCommandShortcut?
    private var screenshotCaptureTask: Task<Void, Never>?
    private var screenshotCaptureGeneration = 0
    private var navigationRevision = 0
    private var session: HerdrHudSession?
    private(set) var chats: HerdrHudChats?
    private var displayedSession: HerdrHudSession? { chats?.displayedSession ?? session }
    private var notes: HerdrHudNotesState?
    private var fontScaleStore: HerdrFontScaleStore?
    private(set) var quickVoice: QuickVoicePanelController?
    private var lastNotesLayout: HerdrHudPlacement.NotesLayout = .hidden
    private var placementOffset = HerdrHudPlacement.defaultOffset()
    private var notificationTokens: [NSObjectProtocol] = []
    private var isConfigured = false
    private var isProgrammaticMove = false
    private var needsFrameSyncAfterDrag = false
    /// Hover-driven notes layouts can start a new frame animation while the
    /// previous one is still running. Only the newest animation's completion
    /// may clear `isProgrammaticMove`, or an intermediate frame gets persisted
    /// as the user's chosen placement.
    private var frameAnimationGeneration = 0
    private var enabledRevision = 0

    private(set) var noteCardSize = HerdrHudPlacement.noteCardSize
    private(set) var chatCardSize = HerdrHudPlacement.expandedSize
    private(set) var isUltraCompactEnabled: Bool
    private var preferredChatCardSize = HerdrHudPlacement.expandedSize
    private(set) var isExpanded = false
    private(set) var isDraggingPanel = false
    private(set) var focusRequest = 0
    private(set) var noteFocusRequest = 0
    private(set) var isCapturingWindowScreenshot = false
    /// Zero means Show all; finite limits apply equally to voice and pane agents.
    var visibleAgentLimit: Int {
        didSet {
            guard oldValue != visibleAgentLimit else { return }
            userDefaults.set(visibleAgentLimit, forKey: DefaultsKey.visibleAgentLimit)
            chipRegroupTask?.cancel()
            isShowingAllChips = false
        }
    }
    private(set) var collapsedChipCount = 0
    private(set) var collapsedOverflowCount = 0
    private(set) var collapsedSessionStackHeight: CGFloat = 0
    @ObservationIgnored private var sessionStackMeasurement: HerdrHudSessionStackMeasurement?
    private(set) var compactNotesHeight: CGFloat = 0
    private(set) var isVoiceReplyCardVisible = false
    private(set) var collapsedResultArtifactCount = 0
    private(set) var areAttachmentTitlesExpanded = false
    /// Orb actions share the HUD-wide hover union and its gap-crossing grace.
    var areOrbControlsVisible: Bool { areAttachmentTitlesExpanded }
    var isCollapsedResultRailVisible: Bool { collapsedResultArtifactCount > 0 }
    var isHudRunActive: Bool {
        displayedSession?.isRunning == true
            || chats?.visibleChats.contains(where: { $0.session.isRunning }) == true
    }
    /// Hover previews reuse the ordinary collapsed HUD without opening its
    /// composer. Explicit cards always win over the persisted resting mode.
    var isUltraCompactResting: Bool {
        isUltraCompactEnabled && !areAttachmentTitlesExpanded && !hasExplicitInteractionSurface
    }
    private var hasExplicitInteractionSurface: Bool {
        isExpanded
            || isVoiceReplyCardVisible
            || quickVoice?.isExpanded == true
            || Self.isCardLayout(notes?.layout ?? .hidden)
    }
    /// Whether the `+N` control has been clicked to reveal the grouped
    /// sessions. Regrouped `chipRegroupDelay` after the pointer leaves them.
    private(set) var isShowingAllChips = false

    private let chipRegroupDelay: Duration
    private var chipRegroupTask: Task<Void, Never>?
    private var isHoveringChips = false
    private var hoveredHudRegions: Set<String> = []
    private var attachmentHoverExitTask: Task<Void, Never>?
    private let attachmentHoverGrace: Duration

    #if DEBUG
    var panelFrameForTesting: CGRect? { panel?.frame }
    var placementOffsetForTesting: CGSize { placementOffset }
    func setPanelFrameForTesting(_ frame: CGRect) { panel?.setFrame(frame, display: true) }
    #endif

    init(
        userDefaults: UserDefaults = .standard,
        chipRegroupDelay: Duration = .seconds(5),
        attachmentHoverGrace: Duration = .milliseconds(180),
        focusedWindowSelection: @escaping FocusedWindowSelection = {
            try HerdrFocusedWindowScreenshot.prepare(processID: $0)
        },
        focusedWindowScreenshotCapture: @escaping FocusedWindowScreenshotCapture = {
            try await HerdrFocusedWindowScreenshot.capture(target: $0)
        },
        screenshotShortcutStateProvider: ScreenshotShortcutStateProvider? = nil
    ) {
        self.userDefaults = userDefaults
        self.focusedWindowSelection = focusedWindowSelection
        self.focusedWindowScreenshotCapture = focusedWindowScreenshotCapture
        self.screenshotShortcutStateProvider = screenshotShortcutStateProvider
            ?? HerdrDualCommandShortcut.systemStateProvider
        isUltraCompactEnabled = userDefaults.bool(forKey: DefaultsKey.ultraCompactEnabled)
        let savedLimit = userDefaults.object(forKey: DefaultsKey.visibleAgentLimit) as? Int
        visibleAgentLimit = savedLimit.flatMap { (0...20).contains($0) ? $0 : nil } ?? HerdrHudPlacement.maxChips
        let width = userDefaults.double(forKey: "herdr.hud.noteWidth")
        let height = userDefaults.double(forKey: "herdr.hud.noteHeight")
        if width.isFinite, height.isFinite, width >= 320, height >= 360 {
            noteCardSize = CGSize(width: min(width, 720), height: min(height, 800))
        }
        let chatSize = HerdrHudChatSizing.constrained(
            CGSize(width: userDefaults.double(forKey: DefaultsKey.chatWidth),
                   height: userDefaults.double(forKey: DefaultsKey.chatHeight)), screen: .zero)
        self.chatCardSize = chatSize
        self.preferredChatCardSize = chatSize
        self.chipRegroupDelay = chipRegroupDelay
        self.attachmentHoverGrace = attachmentHoverGrace
    }

    var isEnabled: Bool {
        _ = enabledRevision
        guard userDefaults.object(forKey: DefaultsKey.enabled) != nil else { return true }
        return userDefaults.bool(forKey: DefaultsKey.enabled)
    }

    var areNotesVisible: Bool {
        _ = enabledRevision
        return userDefaults.object(forKey: DefaultsKey.notesVisible) == nil
            || userDefaults.bool(forKey: DefaultsKey.notesVisible)
    }

    func setNotesVisible(_ visible: Bool) {
        userDefaults.set(visible, forKey: DefaultsKey.notesVisible)
        enabledRevision &+= 1
        notes?.setVisible(visible)
        notesLayoutDidChange()
    }

    func setUltraCompactEnabled(_ enabled: Bool) {
        guard isUltraCompactEnabled != enabled else { return }
        isUltraCompactEnabled = enabled
        userDefaults.set(enabled, forKey: DefaultsKey.ultraCompactEnabled)
        if enabled {
            // The enabling click belongs to the outgoing preview. Clear its
            // hover union now so compact rest does not wait for pointer exit.
            resetHudHover()
        }
        applyFrame(animated: true)
    }

    func toggleUltraCompact() {
        setUltraCompactEnabled(!isUltraCompactEnabled)
    }

    func configure(
        model: HerdrAppModel,
        session: HerdrHudSession,
        notes: HerdrHudNotesState,
        fontScale: HerdrFontScaleStore,
        quickVoice: QuickVoicePanelController? = nil
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.session = session
        self.chats = HerdrHudChats(legacySession: session, defaults: userDefaults)
        self.notes = notes
        notes.setVisible(areNotesVisible)
        self.fontScaleStore = fontScale
        self.quickVoice = quickVoice
        quickVoice?.configure(model: model, hud: self)
        lastNotesLayout = notes.layout
        placementOffset = loadPlacementOffset()

        let initialFrame = frame(for: false)
        let panel = HerdrHudPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.handleCancel() }
        panel.contentView = NSHostingView(
            rootView: HerdrHudRootView(
                model: model,
                controller: self,
                session: session,
                notes: notes,
                fontScale: fontScale
            )
        )
        self.panel = panel
        // The root view reports its initial chip count while the hosting view
        // is being installed. Reapply after retaining the panel so an eager
        // initial report cannot be lost before `self.panel` was available.
        applyFrame(animated: false)
        installObservers(for: panel)
        session.isCollapsed = true

        if isEnabled {
            installHotKey()
            installScreenshotShortcut()
            panel.orderFrontRegardless()
        }
    }

    func summon() {
        navigationRevision &+= 1
        chats?.select(nil)
        showSelectedChat()
    }

    func openChat(_ id: String) {
        navigationRevision &+= 1
        chats?.select(id)
        showSelectedChat()
    }

    func endChat(_ id: String, model: HerdrAppModel) async throws {
        let focusBefore = focusRequest
        if try await chats?.end(id, model: model) == true,
           focusRequest == focusBefore, chats?.selectedID == nil {
            collapse()
        }
    }

    func submitChat(_ submittedSession: HerdrHudSession, model: HerdrAppModel) async {
        await submittedSession.submit(model: model) { [self] in
            let wasDisplayed = displayedSession === submittedSession
            chats?.submissionStarted(submittedSession)
            if wasDisplayed { collapse() }
        }
        // Completion is represented by the conversation bubble, never by focus
        // theft or opening over a different conversation/draft.
    }

    private func showSelectedChat() {
        quickVoice?.collapse()
        if !isEnabled {
            setEnabled(true)
        }
        guard let panel else { return }
        notes?.closeNote()
        regroupChips()
        isExpanded = true
        if notes?.isHudExpanded == false { notes?.isHudExpanded = true }
        displayedSession?.isCollapsed = false
        applyFrame(animated: true)
        panel.makeKeyAndOrderFront(nil)
        focusRequest &+= 1
        displayedSession?.markSeen()
    }

    func collapse() {
        navigationRevision &+= 1
        guard let panel else { return }
        isExpanded = false
        if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
        displayedSession?.isCollapsed = true
        applyFrame(animated: true)
        if panel.isKeyWindow {
            refocusPanelWithoutFade(panel)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func toggleFromHotKey() {
        guard let panel else { return }
        if !panel.isVisible || !isExpanded {
            summon()
        } else {
            collapse()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { resetHudHover() }
        if !enabled { quickVoice?.collapse() }
        notes?.closeNote()
        regroupChips()
        userDefaults.set(enabled, forKey: DefaultsKey.enabled)
        enabledRevision &+= 1
        guard let panel else { return }

        if enabled {
            installHotKey()
            installScreenshotShortcut()
            isExpanded = false
            if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
            displayedSession?.isCollapsed = true
            applyFrame(animated: false)
            panel.orderFrontRegardless()
        } else {
            cancelWindowScreenshotCapture()
            isExpanded = false
            if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
            displayedSession?.isCollapsed = true
            applyFrame(animated: false)
            panel.orderOut(nil)
            hotKey?.unregister()
            screenshotShortcut?.unregister()
        }
    }

    /// Captures the frontmost app/window identity before any asynchronous work
    /// or HUD presentation, then stages the PNG in the separate New chat composer.
    func captureFocusedWindow(
        processID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) {
        guard isEnabled, screenshotCaptureTask == nil, let chats else { return }
        let targetComposer = chats.composer
        let startedNavigationRevision = navigationRevision
        let target: HerdrFocusedWindowTarget
        do {
            target = try focusedWindowSelection(processID)
        } catch {
            targetComposer.reportAttachmentError(error.localizedDescription)
            presentNewComposerIfNavigationUnchanged(startedNavigationRevision)
            return
        }

        screenshotCaptureGeneration &+= 1
        let generation = screenshotCaptureGeneration
        let capture = focusedWindowScreenshotCapture
        isCapturingWindowScreenshot = true
        screenshotCaptureTask = Task { @MainActor [weak self, targetComposer] in
            defer { self?.finishWindowScreenshotCapture(generation: generation) }
            do {
                let sourceURL = try await capture(target)
                defer { try? FileManager.default.removeItem(at: sourceURL) }
                try Task.checkCancellation()
                guard let self,
                      self.screenshotCaptureGeneration == generation,
                      self.isEnabled,
                      let currentChats = self.chats
                else { return }
                guard currentChats.composer === targetComposer else {
                    currentChats.composer.reportAttachmentError(
                        "The screenshot wasn’t added because that New chat draft was sent while capture was in progress. Try again."
                    )
                    self.presentNewComposerIfNavigationUnchanged(startedNavigationRevision)
                    return
                }
                targetComposer.addAttachments([sourceURL])
                self.presentNewComposerIfNavigationUnchanged(startedNavigationRevision)
            } catch is CancellationError {
                // Disable and replacement captures intentionally discard late results.
            } catch {
                guard let self,
                      self.screenshotCaptureGeneration == generation,
                      self.isEnabled,
                      let currentChats = self.chats
                else { return }
                if currentChats.composer === targetComposer {
                    targetComposer.reportAttachmentError(error.localizedDescription)
                } else {
                    currentChats.composer.reportAttachmentError(
                        "The screenshot wasn’t added because that New chat draft was sent while capture was in progress. Try again."
                    )
                }
                self.presentNewComposerIfNavigationUnchanged(startedNavigationRevision)
            }
        }
    }

    private func presentNewComposerIfNavigationUnchanged(_ revision: Int) {
        guard navigationRevision == revision else { return }
        chats?.select(nil)
        showSelectedChat()
    }

    private func finishWindowScreenshotCapture(generation: Int) {
        guard screenshotCaptureGeneration == generation else { return }
        screenshotCaptureTask = nil
        isCapturingWindowScreenshot = false
    }

    private func cancelWindowScreenshotCapture() {
        screenshotCaptureGeneration &+= 1
        screenshotCaptureTask?.cancel()
        screenshotCaptureTask = nil
        isCapturingWindowScreenshot = false
    }

    func setVoiceReplyCardVisible(_ isVisible: Bool) {
        guard isVoiceReplyCardVisible != isVisible else { return }
        isVoiceReplyCardVisible = isVisible
        applyFrame(animated: true)
    }

    func presentQuickVoice() {
        navigationRevision &+= 1
        if !isEnabled { setEnabled(true) }
        notes?.closeNote()
        isExpanded = false
        notes?.isHudExpanded = false
        displayedSession?.isCollapsed = true
        applyFrame(animated: false)
        panel?.makeKeyAndOrderFront(nil)
    }

    func quickVoiceLayoutDidChange() { applyFrame(animated: false) }

    func fontScaleDidChange() { applyFrame(animated: false) }

    func measureSessionStack(_ measurement: HerdrHudSessionStackMeasurement) {
        guard measurement.height.isFinite, measurement.height >= 0,
              sessionStackMeasurement != measurement else { return }
        sessionStackMeasurement = measurement
        if !isExpanded { applyFrame(animated: false) }
    }

    func setCollapsedChipCount(_ count: Int, overflow: Int = 0) {
        let clampedCount = max(0, count)
        let clampedOverflow = max(0, overflow)
        guard collapsedChipCount != clampedCount || collapsedOverflowCount != clampedOverflow else { return }
        collapsedChipCount = clampedCount
        collapsedOverflowCount = clampedOverflow
        if !isExpanded {
            applyFrame(animated: true)
        }
    }

    func setCollapsedResultRailVisible(_ isVisible: Bool) {
        setCollapsedResultArtifactCount(isVisible ? max(1, collapsedResultArtifactCount) : 0)
    }

    func setCollapsedResultArtifactCount(_ count: Int) {
        let clampedCount = min(max(0, count), HerdrHudPlacement.maxVisibleResults)
        guard collapsedResultArtifactCount != clampedCount else { return }
        collapsedResultArtifactCount = clampedCount
        if !isExpanded {
            applyFrame(animated: true)
        }
    }

    /// Use a union of visible HUD controls, never the transparent panel frame.
    /// A short exit grace lets the pointer cross the gaps between controls and
    /// reach the newly disclosed attachments without flickering them closed.
    func setHoveringHud(_ hovering: Bool, region: String) {
        if hovering {
            guard isEnabled else { return }
            hoveredHudRegions.insert(region)
            attachmentHoverExitTask?.cancel()
            attachmentHoverExitTask = nil
            setAttachmentTitlesExpanded(true)
        } else {
            guard hoveredHudRegions.remove(region) != nil, hoveredHudRegions.isEmpty else { return }
            attachmentHoverExitTask?.cancel()
            attachmentHoverExitTask = Task { [weak self, attachmentHoverGrace] in
                try? await Task.sleep(for: attachmentHoverGrace)
                guard !Task.isCancelled, let self, self.hoveredHudRegions.isEmpty else { return }
                self.attachmentHoverExitTask = nil
                self.setAttachmentTitlesExpanded(false)
            }
        }
    }

    private func resetHudHover() {
        attachmentHoverExitTask?.cancel()
        attachmentHoverExitTask = nil
        hoveredHudRegions.removeAll()
        setAttachmentTitlesExpanded(false)
    }

    private func setAttachmentTitlesExpanded(_ expanded: Bool) {
        guard areAttachmentTitlesExpanded != expanded else { return }
        areAttachmentTitlesExpanded = expanded
        if !isExpanded {
            // Resize AppKit immediately. SwiftUI owns the pills' transition,
            // keeping the right-hand anchor still throughout the expansion.
            applyFrame(animated: false)
        }
    }

    func beginPanelDrag() {
        isDraggingPanel = true
        notes?.isHoverSuspended = true
        needsFrameSyncAfterDrag = false
    }

    func endPanelDrag() {
        isDraggingPanel = false
        if let panel {
            let visibleFrame = visibleFrame(for: panel)
            let offset = HerdrHudPlacement.offset(
                forFrame: panel.frame,
                visibleFrame: visibleFrame,
                isUltraCompact: isUltraCompactResting
            )
            placementOffset = HerdrHudPlacement.reclamp(
                topRightOffset: offset,
                isExpanded: isExpanded,
                isUltraCompact: isUltraCompactResting,
                visibleFrame: visibleFrame
            )
            savePlacementOffset()
        }
        notes?.isHoverSuspended = false
        if needsFrameSyncAfterDrag {
            needsFrameSyncAfterDrag = false
            applyFrame(animated: false)
        }
    }

    /// Reveal every session the `+N` control had grouped away.
    func showAllChips() {
        chipRegroupTask?.cancel()
        chipRegroupTask = nil
        guard !isShowingAllChips else { return }
        isShowingAllChips = true
    }

    func regroupChips() {
        chipRegroupTask?.cancel()
        chipRegroupTask = nil
        guard isShowingAllChips else { return }
        isShowingAllChips = false
    }

    /// Hovering holds the revealed list open; leaving it starts the regroup
    /// countdown. Deliberately a grace period rather than an immediate collapse
    /// — the pointer crosses the gaps between chips on its way to one of them.
    func setHoveringChips(_ hovering: Bool) {
        isHoveringChips = hovering
        guard isShowingAllChips else { return }
        chipRegroupTask?.cancel()
        guard !hovering else {
            chipRegroupTask = nil
            return
        }
        chipRegroupTask = Task { [weak self, chipRegroupDelay] in
            try? await Task.sleep(for: chipRegroupDelay)
            guard !Task.isCancelled, let self, !self.isHoveringChips else { return }
            self.chipRegroupTask = nil
            self.isShowingAllChips = false
        }
    }

    func resizeChat(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        preferredChatCardSize = HerdrHudChatSizing.constrained(size, screen: visibleFrame(for: panel).size,
                                                              otherHeight: chatOtherHeight)
        chatCardSize = preferredChatCardSize
        userDefaults.set(preferredChatCardSize.width, forKey: DefaultsKey.chatWidth)
        userDefaults.set(preferredChatCardSize.height, forKey: DefaultsKey.chatHeight)
        applyFrame(animated: false)
    }

    func resetChatSize() {
        preferredChatCardSize = HerdrHudPlacement.expandedSize
        userDefaults.set(preferredChatCardSize.width, forKey: DefaultsKey.chatWidth)
        userDefaults.set(preferredChatCardSize.height, forKey: DefaultsKey.chatHeight)
        chatCardSize = HerdrHudChatSizing.constrained(preferredChatCardSize, screen: visibleFrame(for: panel).size,
                                                     otherHeight: chatOtherHeight)
        applyFrame(animated: false)
    }

    private var chatOtherHeight: CGFloat {
        let layout = notes?.layout ?? .hidden
        let natural = HerdrHudPlacement.notesContentSize(layout, isExpanded: true).height
        let notesHeight: CGFloat
        if case .compact = layout {
            // Compact notes scroll; reserve the toggle and two usable rows,
            // rather than shrinking the chat for every saved note.
            notesHeight = min(natural, HerdrHudPlacement.notesToggleSize
                              + 2 * (HerdrHudPlacement.noteCompactBarHeight + HerdrHudPlacement.noteCompactBarSpacing))
        } else {
            notesHeight = natural
        }
        return (notesHeight > 0 ? HerdrHudPlacement.notesGap + notesHeight : 0)
            + (isVoiceReplyCardVisible ? HerdrHudPlacement.notesGap + HerdrHudPlacement.voiceReplyCardSize.height : 0)
            + (quickVoice?.isExpanded == true ? HerdrHudPlacement.chipSpacing + HerdrHudPlacement.quickVoiceCardSize.height : 0)
    }

    func resizeNote(to size: CGSize) {
        noteCardSize = constrainedNoteSize(size)
        userDefaults.set(noteCardSize.width, forKey: "herdr.hud.noteWidth")
        userDefaults.set(noteCardSize.height, forKey: "herdr.hud.noteHeight")
        applyFrame(animated: false)
    }

    private func constrainedNoteSize(_ size: CGSize) -> CGSize {
        let screen = visibleFrame(for: panel)
        let margin = HerdrHudPlacement.shadowMargin * 2
        let otherHeight = HerdrHudPlacement.collapsedSize.height + HerdrHudPlacement.notesGap
            + (isVoiceReplyCardVisible ? HerdrHudPlacement.voiceReplyCardSize.height + HerdrHudPlacement.notesGap : 0)
            + (quickVoice?.isExpanded == true ? HerdrHudPlacement.quickVoiceCardSize.height + HerdrHudPlacement.chipSpacing : 0)
        return CGSize(
            width: min(max(320, size.width), max(320, min(720, screen.width - margin))),
            height: min(max(360, size.height), max(360, min(800, screen.height - margin - otherHeight)))
        )
    }

    func notesLayoutDidChange() {
        guard let panel else { return }
        let currentLayout = notes?.layout ?? .hidden
        let newFrame = frame(for: isExpanded)
        if newFrame != panel.frame {
            applyFrame(animated: Self.shouldAnimateNotesFrameTransition(from: lastNotesLayout, to: currentLayout))
        }
        if case .card = lastNotesLayout,
           !Self.isCardLayout(currentLayout),
           !isExpanded,
           !isDraggingPanel,
           panel.isKeyWindow {
            refocusPanelWithoutFade(panel)
        }
        lastNotesLayout = currentLayout
    }

    /// Compact, hidden, and row layouts are all hover-driven. Resizing the
    /// AppKit panel with an animator for those transitions moves the window's
    /// origin while SwiftUI is also changing its content, which makes the HUD
    /// appear to leave the screen. Resize those layouts immediately and let the
    /// notes view own the fade. Card presentation can retain its deliberate
    /// panel animation.
    static func shouldAnimateNotesFrameTransition(
        from oldLayout: HerdrHudPlacement.NotesLayout,
        to newLayout: HerdrHudPlacement.NotesLayout
    ) -> Bool {
        isCardLayout(oldLayout) || isCardLayout(newLayout)
    }

    func createNote() {
        guard let notes else { return }
        openNote(notes.createNote())
    }

    func openNote(_ id: UUID) {
        navigationRevision &+= 1
        quickVoice?.collapse()
        guard let panel, let notes else { return }
        if !isEnabled { setEnabled(true) }
        if !areNotesVisible { setNotesVisible(true) }
        if isExpanded {
            isExpanded = false
            displayedSession?.isCollapsed = true
            if notes.isHudExpanded { notes.isHudExpanded = false }
        }
        notes.openNote(id)
        applyFrame(animated: true)
        panel.makeKeyAndOrderFront(nil)
        noteFocusRequest &+= 1
    }

    func closeNote() { notes?.closeNote() }

    func handleCancel() {
        if quickVoice?.isExpanded == true {
            quickVoice?.collapse()
        } else if notes?.openNoteID != nil {
            closeNote()
        } else {
            collapse()
        }
    }

    private static func isCardLayout(_ layout: HerdrHudPlacement.NotesLayout) -> Bool {
        if case .card = layout { return true }
        return false
    }

    private func refocusPanelWithoutFade(_ panel: HerdrHudPanel) {
        let previousBehavior = panel.animationBehavior
        panel.animationBehavior = .none
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        panel.animationBehavior = previousBehavior
    }

    private func installHotKey() {
        if hotKey == nil {
            hotKey = HerdrGlobalHotKey(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey | optionKey)
            ) { [weak self] in
                self?.toggleFromHotKey()
            }
        }
        _ = hotKey?.register()
    }

    private func installScreenshotShortcut() {
        if screenshotShortcut == nil {
            screenshotShortcut = HerdrDualCommandShortcut(
                stateProvider: screenshotShortcutStateProvider
            ) { [weak self] in
                self?.captureFocusedWindow()
            }
        }
        _ = screenshotShortcut?.register()
    }

    private func installObservers(for panel: HerdrHudPanel) {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.persistCurrentPlacement() }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reclampPlacement() }
            }
        )
    }

    private func persistCurrentPlacement() {
        guard let panel else { return }
        if isDraggingPanel {
            placementOffset = HerdrHudPlacement.offset(
                forFrame: panel.frame,
                visibleFrame: visibleFrame(for: panel),
                isUltraCompact: isUltraCompactResting
            )
            return
        }
        guard !isProgrammaticMove else { return }
        placementOffset = HerdrHudPlacement.offset(
            forFrame: panel.frame,
            visibleFrame: visibleFrame(for: panel),
            isUltraCompact: isUltraCompactResting
        )
        savePlacementOffset()
    }

    private func reclampPlacement() {
        if isDraggingPanel { return }
        guard let panel else { return }
        isProgrammaticMove = true
        frameAnimationGeneration &+= 1
        let generation = frameAnimationGeneration
        panel.setFrame(frame(for: isExpanded), display: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frameAnimationGeneration == generation else { return }
            self.isProgrammaticMove = false
        }
    }

    private func applyFrame(animated: Bool) {
        if isDraggingPanel {
            needsFrameSyncAfterDrag = true
            return
        }
        guard let panel else { return }
        let newFrame = frame(for: isExpanded)
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isProgrammaticMove = true
        frameAnimationGeneration &+= 1
        let generation = frameAnimationGeneration
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.frameAnimationGeneration == generation else { return }
                    self.isProgrammaticMove = false
                }
            })
        } else {
            panel.setFrame(newFrame, display: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.frameAnimationGeneration == generation else { return }
                self.isProgrammaticMove = false
            }
        }
    }

    private func frame(for isExpanded: Bool) -> CGRect {
        let visibleFrame = visibleFrame(for: panel)
        let fontScale = fontScaleStore?.scale.rawValue ?? 1
        if isExpanded {
            chatCardSize = HerdrHudChatSizing.constrained(preferredChatCardSize, screen: visibleFrame.size,
                                                        otherHeight: chatOtherHeight)
        }
        let measuredHeight = sessionStackMeasurement.flatMap {
            $0.matches(chipCount: collapsedChipCount, overflow: collapsedOverflowCount, fontScale: fontScale) ? $0.height : nil
        }
        var notesSize = HerdrHudPlacement.notesContentSize(notes?.layout ?? .hidden, isExpanded: isExpanded)
        if case .card = notes?.layout {
            noteCardSize = constrainedNoteSize(noteCardSize)
            notesSize = noteCardSize
        }
        let voiceReplySize = isVoiceReplyCardVisible ? HerdrHudPlacement.voiceReplyCardSize : .zero
        let quickVoiceSize = quickVoice?.isExpanded == true ? HerdrHudPlacement.quickVoiceCardSize : .zero
        if case let .compact(count) = notes?.layout {
            notesSize = HerdrHudPlacement.compactNotesViewportSize(
                count: count, isExpanded: isExpanded, visibleFrameHeight: visibleFrame.height,
                chipCount: collapsedChipCount, voiceReplySize: voiceReplySize,
                quickVoiceSize: quickVoiceSize, fontScale: fontScale,
                measuredContentHeight: measuredHeight,
                expandedChatSize: chatCardSize
            )
            compactNotesHeight = notesSize.height
        }
        collapsedSessionStackHeight = HerdrHudPlacement.sessionStackHeight(
            chipCount: collapsedChipCount,
            overflow: collapsedOverflowCount,
            visibleFrameHeight: visibleFrame.height,
            notesSize: notesSize,
            voiceReplySize: voiceReplySize,
            quickVoiceSize: quickVoiceSize,
            fontScale: fontScale,
            measuredContentHeight: measuredHeight
        )
        return HerdrHudPlacement.frame(
            isExpanded: isExpanded,
            isUltraCompact: isUltraCompactResting,
            visibleFrame: visibleFrame,
            topRightOffset: placementOffset,
            chipCount: isExpanded ? 0 : collapsedChipCount,
            overflow: isExpanded ? 0 : collapsedOverflowCount,
            hasResultRail: !isExpanded && isCollapsedResultRailVisible,
            resultArtifactCount: collapsedResultArtifactCount,
            expandsResultTitles: areAttachmentTitlesExpanded,
            notesSize: notesSize,
            voiceReplySize: voiceReplySize,
            quickVoiceSize: quickVoiceSize,
            fontScale: fontScale,
            measuredContentHeight: isExpanded ? nil : measuredHeight,
            expandedChatSize: chatCardSize
        )
    }

    private func visibleFrame(for panel: NSPanel?) -> CGRect {
        panel?.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
    }

    private func loadPlacementOffset() -> CGSize {
        guard let values = userDefaults.array(forKey: DefaultsKey.offset) as? [NSNumber], values.count == 2 else {
            return HerdrHudPlacement.defaultOffset()
        }
        return CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
    }

    private func savePlacementOffset() {
        userDefaults.set([placementOffset.width, placementOffset.height], forKey: DefaultsKey.offset)
    }
}
