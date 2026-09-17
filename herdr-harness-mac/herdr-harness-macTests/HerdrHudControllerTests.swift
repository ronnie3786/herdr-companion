import AppKit
import CoreGraphics
import Foundation
import Testing
import SwiftUI
@testable import herdr_harness_mac

@Suite("Herdr HUD controller", .serialized)
@MainActor
struct HerdrHudControllerTests {
    @Test("Ultra-compact mode defaults off and persists toggles across recreation")
    func ultraCompactPreferencePersists() {
        let defaults = makeDefaults()
        let controller = HerdrHudController(userDefaults: defaults)
        #expect(!controller.isUltraCompactEnabled)
        #expect(!controller.isUltraCompactResting)

        controller.setUltraCompactEnabled(true)
        #expect(controller.isUltraCompactEnabled)
        #expect(controller.isUltraCompactResting)
        #expect(HerdrHudController(userDefaults: defaults).isUltraCompactEnabled)

        controller.toggleUltraCompact()
        #expect(!controller.isUltraCompactEnabled)
        #expect(!controller.isUltraCompactResting)
        #expect(!controller.isExpanded)
        #expect(!HerdrHudController(userDefaults: defaults).isUltraCompactEnabled)
    }

    @Test("Enabling ultra-compact mode immediately clears the outgoing hover preview")
    func ultraCompactEntryClearsHoverImmediately() {
        let controller = HerdrHudController(userDefaults: makeDefaults())
        controller.setHoveringHud(true, region: "hud-orb")
        #expect(controller.areOrbControlsVisible)

        controller.setUltraCompactEnabled(true)

        #expect(controller.isUltraCompactResting)
        #expect(!controller.areOrbControlsVisible)
        #expect(!controller.isExpanded)
        controller.setHoveringHud(false, region: "hud-orb")
        #expect(controller.isUltraCompactResting)
    }

    @Test("Ultra-compact hover previews with grace and the HUD region union cancels exit")
    func ultraCompactHoverPreviewUsesHudUnion() async throws {
        let controller = HerdrHudController(
            userDefaults: makeDefaults(),
            attachmentHoverGrace: .milliseconds(80)
        )
        controller.setHoveringHud(true, region: "hud-orb")
        controller.setUltraCompactEnabled(true)
        #expect(controller.isUltraCompactResting)
        controller.setHoveringHud(false, region: "hud-orb")
        #expect(controller.isUltraCompactResting)

        controller.setHoveringHud(true, region: "hud-ultra-compact")
        #expect(!controller.isUltraCompactResting)
        #expect(!controller.isExpanded)
        controller.setHoveringHud(false, region: "hud-ultra-compact")
        try await Task.sleep(for: .milliseconds(20))
        controller.setHoveringHud(true, region: "hud-orb")
        try await Task.sleep(for: .milliseconds(120))
        #expect(!controller.isUltraCompactResting)
        #expect(!controller.isExpanded)

        controller.setHoveringHud(false, region: "hud-orb")
        try await Task.sleep(for: .milliseconds(120))
        #expect(controller.isUltraCompactResting)
    }

    @Test("Explicit chat, note, Quick Voice, and voice reply surfaces override ultra-compact rest")
    func explicitSurfacesStayVisible() throws {
        let harness = makeHarness(includesVoice: true)
        harness.controller.setUltraCompactEnabled(true)
        #expect(harness.controller.isUltraCompactResting)

        harness.controller.summon()
        #expect(harness.controller.isExpanded)
        #expect(!harness.controller.isUltraCompactResting)
        harness.controller.collapse()
        #expect(harness.controller.isUltraCompactResting)

        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        #expect(!harness.controller.isUltraCompactResting)
        harness.controller.closeNote()
        harness.controller.notesLayoutDidChange()
        #expect(harness.controller.isUltraCompactResting)

        let voice = try #require(harness.controller.quickVoice)
        voice.showDetails()
        #expect(!harness.controller.isUltraCompactResting)
        voice.collapse()
        #expect(harness.controller.isUltraCompactResting)

        harness.controller.setVoiceReplyCardVisible(true)
        #expect(!harness.controller.isUltraCompactResting)
        harness.controller.setVoiceReplyCardVisible(false)
        #expect(harness.controller.isUltraCompactResting)
    }

    @Test("Resizing notes respects bounds and survives controller recreation")
    func noteResizePersists() throws {
        let name = "NoteResizeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = HerdrHudController(userDefaults: defaults)
        controller.resizeNote(to: CGSize(width: 440, height: 400))
        #expect(controller.noteCardSize.width == 440)
        let restored = HerdrHudController(userDefaults: defaults)
        #expect(restored.noteCardSize == controller.noteCardSize)
        controller.resizeNote(to: .zero)
        #expect(controller.noteCardSize == HerdrHudPlacement.noteCardSize)
    }

    @Test("Summon, open, and summon again drive expansion and note state together")
    func summonOpenNoteRoundTrip() async throws {
        let harness = makeHarness()
        harness.controller.summon()
        #expect(harness.controller.isExpanded)
        #expect(harness.notes.isHudExpanded)

        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        #expect(!harness.controller.isExpanded)
        #expect(harness.session.isCollapsed)
        #expect(harness.notes.openNoteID == noteID)
        #expect(!harness.notes.isHudExpanded)

        harness.controller.summon()
        #expect(harness.notes.openNoteID == nil)
        #expect(harness.notes.isHudExpanded)
    }

    @Test("Focused-window capture stages a retained PNG in New chat without sending or replacing its draft")
    func focusedWindowCaptureTargetsNewComposer() async throws {
        let source = temporaryURL(named: "focused-window.png")
        let screenshotData = try writeSyntheticPNG(to: source)
        let existing = temporaryURL(named: "existing.txt")
        try Data("Existing synthetic attachment".utf8).write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }
        let expectedTarget = HerdrFocusedWindowTarget(processID: 321, windowID: 99)
        let harness = makeHarness(
            screenshotSelection: { processID in
                #expect(processID == 321)
                return expectedTarget
            },
            screenshotCapture: { target in
                #expect(target == expectedTarget)
                return source
            }
        )
        defer { harness.controller.setEnabled(false) }
        let chats = try #require(harness.controller.chats)
        let oldComposer = chats.composer
        oldComposer.draft = "Previously submitted"
        chats.submissionStarted(oldComposer)
        let existingChat = try #require(chats.chats.first)
        harness.controller.openChat(existingChat.id)
        let composer = chats.composer
        composer.draft = "Keep this unsent draft"
        composer.selectedMachineID = "synthetic-machine"
        _ = try composer.addCustomWorkingFolder(
            path: "/synthetic/screenshot-project",
            machineID: "synthetic-machine"
        )
        composer.addAttachments([existing])

        harness.controller.captureFocusedWindow(processID: 321)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }

        #expect(chats.displayedSession === composer)
        #expect(composer.draft == "Keep this unsent draft")
        #expect(composer.selectedMachineID == "synthetic-machine")
        #expect(composer.selectedWorkingFolder.path == "/synthetic/screenshot-project")
        #expect(composer.pendingAttachments.count == 2)
        let screenshot = try #require(composer.pendingAttachments.last)
        #expect(screenshot.isImage)
        let retainedData = try Data(contentsOf: screenshot.url)
        #expect(retainedData == screenshotData)
        #expect(NSBitmapImageRep(data: retainedData) != nil)
        #expect(composer.exchanges.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(harness.controller.isExpanded)
    }

    @Test("Only one screenshot capture can be pending")
    func duplicateCaptureWhilePendingIsIgnored() async throws {
        let barrier = ScreenshotCaptureBarrier()
        let harness = makeHarness(screenshotCapture: { target in
            try await barrier.capture(target)
        })
        defer {
            harness.controller.setEnabled(false)
            barrier.cancelAll()
        }
        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted()
        harness.controller.captureFocusedWindow(processID: 321)
        #expect(barrier.invocationCount == 1)

        let source = temporaryURL(named: "single.png")
        _ = try writeSyntheticPNG(to: source)
        barrier.succeed(with: source)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }
        #expect(harness.controller.chats?.composer.pendingAttachments.count == 1)
    }

    @Test("Navigation during capture keeps selection while staging into the original New chat composer")
    func navigationDuringCaptureDoesNotStealFocus() async throws {
        let barrier = ScreenshotCaptureBarrier()
        let harness = makeHarness(screenshotCapture: { target in
            try await barrier.capture(target)
        })
        defer {
            harness.controller.setEnabled(false)
            barrier.cancelAll()
        }
        let chats = try #require(harness.controller.chats)
        let first = chats.composer
        chats.submissionStarted(first)
        let firstID = try #require(chats.chats.first?.id)
        let second = chats.composer
        chats.submissionStarted(second)
        let secondID = try #require(chats.chats.first(where: { $0.id != firstID })?.id)
        let targetComposer = chats.composer
        harness.controller.openChat(firstID)
        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted()
        harness.controller.openChat(secondID)
        let focusAfterNavigation = harness.controller.focusRequest

        let source = temporaryURL(named: "navigated.png")
        _ = try writeSyntheticPNG(to: source)
        barrier.succeed(with: source)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }

        #expect(chats.selectedID == secondID)
        #expect(harness.controller.focusRequest == focusAfterNavigation)
        #expect(targetComposer.pendingAttachments.count == 1)
        #expect(second.pendingAttachments.isEmpty)
    }

    @Test("Submitting the target composer while capture is pending discards the image with an actionable fresh-composer error")
    func submittedComposerRejectsLateCapture() async throws {
        let barrier = ScreenshotCaptureBarrier()
        let harness = makeHarness(screenshotCapture: { target in
            try await barrier.capture(target)
        })
        defer {
            harness.controller.setEnabled(false)
            barrier.cancelAll()
        }
        let chats = try #require(harness.controller.chats)
        let submitted = chats.composer
        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted()
        chats.submissionStarted(submitted)
        let fresh = chats.composer

        let source = temporaryURL(named: "submitted.png")
        _ = try writeSyntheticPNG(to: source)
        barrier.succeed(with: source)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }

        #expect(submitted.pendingAttachments.isEmpty)
        #expect(fresh.pendingAttachments.isEmpty)
        #expect(fresh.validationError?.contains("draft was sent") == true)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Disabling during capture cancels presentation and deletes a late temporary image")
    func disableDiscardsLateCapture() async throws {
        let barrier = ScreenshotCaptureBarrier()
        let harness = makeHarness(screenshotCapture: { target in
            try await barrier.capture(target)
        })
        defer {
            harness.controller.setEnabled(false)
            barrier.cancelAll()
        }
        let composer = try #require(harness.controller.chats?.composer)
        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted()
        harness.controller.setEnabled(false)

        let source = temporaryURL(named: "disabled.png")
        _ = try writeSyntheticPNG(to: source)
        barrier.succeed(with: source)
        try await waitUntil { !FileManager.default.fileExists(atPath: source.path) }

        #expect(!harness.controller.isEnabled)
        #expect(!harness.controller.isExpanded)
        #expect(composer.pendingAttachments.isEmpty)
    }

    @Test("Asynchronous screenshot capture failures open New chat with an actionable error")
    func asynchronousCaptureFailureIsVisible() async throws {
        let barrier = ScreenshotCaptureBarrier()
        let harness = makeHarness(screenshotCapture: { target in
            try await barrier.capture(target)
        })
        defer {
            harness.controller.setEnabled(false)
            barrier.cancelAll()
        }
        let composer = try #require(harness.controller.chats?.composer)

        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted()
        barrier.fail(with: HerdrFocusedWindowScreenshotError.captureFailed)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }

        #expect(composer.validationError?.contains("couldn’t capture") == true)
        #expect(harness.controller.chats?.displayedSession === composer)
        #expect(harness.controller.isExpanded)
    }

    @Test("A canceled old capture cannot interfere with a new capture after re-enabling")
    func reenabledCaptureIgnoresCanceledOldCompletion() async throws {
        let barrier = ScreenshotCaptureBarrier()
        let harness = makeHarness(screenshotCapture: { target in
            try await barrier.capture(target)
        })
        defer {
            harness.controller.setEnabled(false)
            barrier.cancelAll()
        }
        let chats = try #require(harness.controller.chats)
        let savedSession = chats.composer
        savedSession.draft = "Synthetic saved chat"
        chats.submissionStarted(savedSession)
        let savedID = try #require(chats.chats.first?.id)
        let targetComposer = chats.composer
        harness.controller.openChat(savedID)

        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted(invocation: 1)
        harness.controller.setEnabled(false)
        harness.controller.setEnabled(true)
        harness.controller.captureFocusedWindow(processID: 321)
        try await barrier.waitUntilStarted(invocation: 2)
        let focusBeforeOldCompletion = harness.controller.focusRequest
        let selectionBeforeOldCompletion = chats.selectedID

        let oldSource = temporaryURL(named: "canceled-old.png")
        _ = try writeSyntheticPNG(to: oldSource)
        barrier.succeed(with: oldSource, invocation: 1)
        try await waitUntil { !FileManager.default.fileExists(atPath: oldSource.path) }

        #expect(harness.controller.isCapturingWindowScreenshot)
        #expect(chats.selectedID == selectionBeforeOldCompletion)
        #expect(chats.selectedID == savedID)
        #expect(harness.controller.focusRequest == focusBeforeOldCompletion)
        #expect(!harness.controller.isExpanded)
        #expect(targetComposer.pendingAttachments.isEmpty)

        let newSource = temporaryURL(named: "reenabled-new.png")
        _ = try writeSyntheticPNG(to: newSource)
        barrier.succeed(with: newSource, invocation: 2)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }

        #expect(targetComposer.pendingAttachments.count == 1)
        #expect(chats.displayedSession === targetComposer)
        #expect(harness.controller.isExpanded)
    }

    @Test("Attachment validation failure removes the screenshot source and preserves existing attachments")
    func attachmentFailureCleansScreenshotSource() async throws {
        let source = temporaryURL(named: "over-limit.png")
        _ = try writeSyntheticPNG(to: source)
        let harness = makeHarness(screenshotCapture: { _ in source })
        defer { harness.controller.setEnabled(false) }
        let composer = try #require(harness.controller.chats?.composer)
        let existingURLs = (0..<HerdrHudSession.maxAttachments).map {
            temporaryURL(named: "existing-\($0).txt")
        }
        defer { existingURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in existingURLs { try Data("Synthetic".utf8).write(to: url) }
        composer.addAttachments(existingURLs)

        harness.controller.captureFocusedWindow(processID: 321)
        try await waitUntil { !harness.controller.isCapturingWindowScreenshot }

        #expect(composer.pendingAttachments.count == HerdrHudSession.maxAttachments)
        #expect(composer.validationError == "You can attach up to 4 files.")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Focused-window selection failures open New chat with an actionable error")
    func focusedWindowSelectionFailureIsVisible() throws {
        let harness = makeHarness(screenshotSelection: { _ in
            throw HerdrFocusedWindowScreenshotError.noFocusedWindow
        })
        defer { harness.controller.setEnabled(false) }
        let chats = try #require(harness.controller.chats)
        let prior = chats.composer
        chats.submissionStarted(prior)
        harness.controller.openChat(try #require(chats.chats.first?.id))

        harness.controller.captureFocusedWindow(processID: 321)

        #expect(chats.displayedSession === chats.composer)
        #expect(chats.composer.validationError?.contains("visible app window") == true)
        #expect(harness.controller.isExpanded)
    }

    @Test("handleCancel with a note open closes only the note")
    func handleCancelClosesNoteFirst() async throws {
        let harness = makeHarness()
        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        harness.controller.handleCancel()
        #expect(harness.notes.openNoteID == nil)
    }

    @Test("Disabling the HUD closes an open note")
    func disablingClosesOpenNote() async throws {
        let harness = makeHarness()
        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        harness.controller.setEnabled(false)
        #expect(harness.notes.openNoteID == nil)
    }

    @Test("Opening a note grows the panel frame by the note card size")
    func openNoteGrowsPanelFrame() async throws {
        let harness = makeHarness()
        let beforeHeight = try #require(harness.controller.panelFrameForTesting?.height)
        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        try await Task.sleep(for: .milliseconds(300))
        let afterHeight = try #require(harness.controller.panelFrameForTesting?.height)
        #expect(afterHeight - beforeHeight == HerdrHudPlacement.notesGap + HerdrHudPlacement.noteCardSize.height)
    }

    @Test("Hover-driven notes layouts resize without animating the HUD panel")
    func hoverLayoutsDoNotAnimatePanelFrame() {
        #expect(!HerdrHudController.shouldAnimateNotesFrameTransition(from: .hidden, to: .rows(count: 0)))
        #expect(!HerdrHudController.shouldAnimateNotesFrameTransition(from: .compact(count: 3), to: .rows(count: 3)))
        #expect(!HerdrHudController.shouldAnimateNotesFrameTransition(from: .rows(count: 3), to: .compact(count: 3)))
    }

    @Test("The +N control reveals grouped sessions and holds while hovered")
    func chipOverflowRevealsAndHolds() async throws {
        let harness = makeHarness(chipRegroupDelay: .milliseconds(120))
        #expect(!harness.controller.isShowingAllChips)

        harness.controller.showAllChips()
        #expect(harness.controller.isShowingAllChips)

        harness.controller.setHoveringChips(true)
        try await Task.sleep(for: .milliseconds(260))
        #expect(harness.controller.isShowingAllChips)
    }

    @Test("Revealed sessions regroup once the pointer has left for the delay")
    func chipOverflowRegroupsAfterHover() async throws {
        let harness = makeHarness(chipRegroupDelay: .milliseconds(120))
        harness.controller.showAllChips()
        harness.controller.setHoveringChips(true)
        harness.controller.setHoveringChips(false)

        #expect(harness.controller.isShowingAllChips)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!harness.controller.isShowingAllChips)
    }

    @Test("Returning to the chips cancels a pending regroup")
    func chipOverflowHoverCancelsRegroup() async throws {
        let harness = makeHarness(chipRegroupDelay: .milliseconds(200))
        harness.controller.showAllChips()
        harness.controller.setHoveringChips(false)
        try await Task.sleep(for: .milliseconds(60))
        harness.controller.setHoveringChips(true)

        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.controller.isShowingAllChips)
    }

    @Test("Summoning the HUD regroups the revealed sessions")
    func summonRegroupsChips() async throws {
        let harness = makeHarness()
        harness.controller.showAllChips()
        harness.controller.summon()
        #expect(!harness.controller.isShowingAllChips)
    }

    /// The panel used to clamp its chip count at `maxChips`, which would have
    /// left revealed sessions drawn outside the window.
    @Test("The panel accepts every revealed chip and tracks overflow separately")
    func revealedChipsGrowThePanel() {
        // Test the controller's count contract without a hosted root. Its
        // initial model projection would otherwise replace these explicit
        // counts during panel layout. Placement tests cover the frame sizes.
        let controller = HerdrHudController(userDefaults: makeDefaults())
        controller.setCollapsedChipCount(HerdrHudPlacement.maxChips + 2)
        #expect(controller.collapsedChipCount == HerdrHudPlacement.maxChips + 2)

        controller.setCollapsedChipCount(30)
        #expect(controller.collapsedChipCount == 30)
        controller.setCollapsedChipCount(4, overflow: 1)
        #expect(controller.collapsedChipCount == 4)
        #expect(controller.collapsedOverflowCount == 1)
        controller.setCollapsedChipCount(4, overflow: 2)
        #expect(controller.collapsedOverflowCount == 2)
    }

    @Test("Visible agent settings default to four and persist finite and Show all choices")
    func visibleAgentPreference() {
        let defaults = makeDefaults()
        let controller = HerdrHudController(userDefaults: defaults)
        #expect(controller.visibleAgentLimit == 4)
        controller.visibleAgentLimit = 5
        #expect(HerdrHudController(userDefaults: defaults).visibleAgentLimit == 5)
        controller.showAllChips()
        controller.visibleAgentLimit = 0
        #expect(!controller.isShowingAllChips)
        #expect(HerdrHudController(userDefaults: defaults).visibleAgentLimit == 0)
        defaults.set(-1, forKey: "herdr.hud.visibleAgentLimit")
        #expect(HerdrHudController(userDefaults: defaults).visibleAgentLimit == 4)
    }

    @Test("Result nodes reserve their lane only while visible")
    func resultRailResizesTheCollapsedPanel() async throws {
        let harness = makeHarness()
        harness.controller.setNotesVisible(false)
        // Let the hosted root publish its initial, artifact-free projection
        // before this test drives the controller directly. Otherwise that
        // initial `onChange` can race the explicit `true` below.
        try await Task.sleep(for: .milliseconds(100))
        let original = try #require(harness.controller.panelFrameForTesting)

        harness.controller.setCollapsedResultRailVisible(true)
        try await Task.sleep(for: .milliseconds(300))
        let widened = try #require(harness.controller.panelFrameForTesting)
        #expect(widened.width - original.width == HerdrHudPlacement.resultRailWidth)
        #expect(widened.maxX == original.maxX)

        harness.controller.setCollapsedResultRailVisible(false)
        try await Task.sleep(for: .milliseconds(300))
        let restored = try #require(harness.controller.panelFrameForTesting)
        #expect(restored.width == original.width)
        #expect(restored.maxX == original.maxX)
    }

    @Test("Attachment titles remain open across overlapping HUD hover regions")
    func attachmentHoverUsesUnionOfVisibleRegions() async throws {
        let controller = HerdrHudController(userDefaults: makeDefaults(), attachmentHoverGrace: .milliseconds(25))
        #expect(!controller.areAttachmentTitlesExpanded)
        controller.setHoveringHud(true, region: "orb")
        controller.setHoveringHud(true, region: "session")
        controller.setHoveringHud(false, region: "orb")
        controller.setHoveringHud(false, region: "unknown")
        try await Task.sleep(for: .milliseconds(70))
        #expect(controller.areAttachmentTitlesExpanded)

        controller.setHoveringHud(false, region: "session")
        #expect(controller.areAttachmentTitlesExpanded)
        try await Task.sleep(for: .milliseconds(70))
        #expect(!controller.areAttachmentTitlesExpanded)
    }

    @Test("Crossing from a session to an attachment cancels the pending collapse")
    func attachmentHoverGraceBridgesControlGaps() async throws {
        let controller = HerdrHudController(userDefaults: makeDefaults(), attachmentHoverGrace: .milliseconds(100))
        controller.setHoveringHud(true, region: "session")
        controller.setHoveringHud(false, region: "session")
        try await Task.sleep(for: .milliseconds(20))
        controller.setHoveringHud(true, region: "attachments")
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.areAttachmentTitlesExpanded)

        controller.setEnabled(false)
        #expect(!controller.areAttachmentTitlesExpanded)
        controller.setHoveringHud(true, region: "attachments")
        #expect(!controller.areAttachmentTitlesExpanded)
        controller.setEnabled(true)
        #expect(!controller.areAttachmentTitlesExpanded)
    }

    @Test("Orb controls are hidden at rest, share HUD hover, and reset when disabled")
    func orbControlsFollowHudHover() async throws {
        let controller = HerdrHudController(userDefaults: makeDefaults(), attachmentHoverGrace: .milliseconds(25))
        #expect(!controller.areOrbControlsVisible)
        controller.setHoveringHud(true, region: "session")
        #expect(controller.areOrbControlsVisible)
        controller.setHoveringHud(true, region: "hud-orb")
        controller.setHoveringHud(false, region: "session")
        try await Task.sleep(for: .milliseconds(70))
        #expect(controller.areOrbControlsVisible)
        controller.setHoveringHud(false, region: "hud-orb")
        #expect(controller.areOrbControlsVisible)
        try await Task.sleep(for: .milliseconds(70))
        #expect(!controller.areOrbControlsVisible)
        controller.setHoveringHud(true, region: "notes")
        #expect(controller.areOrbControlsVisible)
        controller.setEnabled(false)
        #expect(!controller.areOrbControlsVisible)
    }

    @Test("Attachment counts reserve only the visible result limit")
    func attachmentCountClampsToVisibleLimit() {
        let controller = HerdrHudController(userDefaults: makeDefaults())
        controller.setCollapsedResultArtifactCount(12)
        #expect(controller.collapsedResultArtifactCount == HerdrHudPlacement.maxVisibleResults)
        #expect(controller.isCollapsedResultRailVisible)
        controller.setCollapsedResultArtifactCount(-1)
        #expect(controller.collapsedResultArtifactCount == 0)
        #expect(!controller.isCollapsedResultRailVisible)
    }

    @Test("Opening and closing a note card retain their panel animation")
    func cardLayoutsAnimatePanelFrame() {
        #expect(HerdrHudController.shouldAnimateNotesFrameTransition(from: .rows(count: 2), to: .card))
        #expect(HerdrHudController.shouldAnimateNotesFrameTransition(from: .card, to: .compact(count: 2)))
    }

    @Test("Panel frame changes are deferred while dragging")
    func applyFrameIsSuppressedWhileDragging() throws {
        let harness = makeHarness()
        let before = try #require(harness.controller.panelFrameForTesting)

        harness.controller.beginPanelDrag()
        harness.controller.setCollapsedChipCount(2)

        #expect(harness.controller.panelFrameForTesting == before)
        harness.controller.endPanelDrag()
    }

    @Test("Ending a drag adopts the panel's actual frame as its placement")
    func endingDragAdoptsActualPanelFrame() throws {
        let harness = makeHarness()
        let initialOffset = harness.controller.placementOffsetForTesting
        let initialFrame = try #require(harness.controller.panelFrameForTesting)
        let movedFrame = initialFrame.offsetBy(dx: -100, dy: -100)

        harness.controller.beginPanelDrag()
        harness.controller.setPanelFrameForTesting(movedFrame)
        harness.controller.endPanelDrag()

        let adoptedOffset = harness.controller.placementOffsetForTesting
        #expect(adoptedOffset.width == initialOffset.width + 100)
        #expect(adoptedOffset.height == initialOffset.height + 100)
        let savedOffset = try #require(harness.defaults.array(forKey: "herdr.hud.offset.v2") as? [NSNumber])
        #expect(savedOffset.map(\.doubleValue) == [Double(adoptedOffset.width), Double(adoptedOffset.height)])
    }

    @Test("Panel dragging tracks its active state")
    func panelDraggingTracksItsActiveState() {
        let harness = makeHarness()
        #expect(!harness.controller.isDraggingPanel)
        harness.controller.beginPanelDrag()
        #expect(harness.controller.isDraggingPanel)
        harness.controller.endPanelDrag()
        #expect(!harness.controller.isDraggingPanel)
    }

    @Test("Suspended notes hover does not change hover state")
    func suspendedNotesHoverIsIgnored() async throws {
        let harness = makeHarness()
        harness.notes.isHoverSuspended = true
        harness.notes.setHovering(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!harness.notes.isHovering)
    }

    @Test("A submission becomes an independent mini HUD and never auto-opens its answer")
    func submissionCreatesMiniHUD() async throws {
        let harness = makeHarness()
        defer { harness.controller.setEnabled(false) }
        harness.controller.summon()
        let chats = try #require(harness.controller.chats)
        let submitted = chats.displayedSession
        submitted.draft = "Plan a garden"
        await harness.controller.submitChat(submitted, model: harness.model)

        #expect(!harness.controller.isExpanded)
        let chat = try #require(chats.visibleChats.first)
        #expect(chat.session === submitted)
        #expect(chat.displayTitle == "Plan a garden")
        #expect(submitted.hasUnseenAnswer)
        #expect(chats.composer !== submitted)
        #expect(chats.composer.exchanges.isEmpty)

        harness.controller.openChat(chat.id)
        #expect(harness.controller.isExpanded)
        #expect(chats.displayedSession === submitted)
        #expect(!submitted.hasUnseenAnswer)
        submitted.draft = "Add a pond"
        harness.controller.summon()
        #expect(chats.displayedSession === chats.composer)
        #expect(submitted.draft == "Add a pond")
    }

    @Test("Chat resizing persists across expansion and relaunch without changing note size")
    func resizeChatPersists() async throws {
        let harness = makeHarness()
        defer { harness.controller.setEnabled(false) }
        harness.controller.summon()
        try await Task.sleep(for: .milliseconds(250))
        let noteSize = harness.controller.noteCardSize
        let initialChatSize = harness.controller.chatCardSize
        let before = try #require(harness.controller.panelFrameForTesting)
        harness.controller.resizeChat(to: CGSize(width: 540, height: 500))
        let size = harness.controller.chatCardSize
        let resized = try #require(harness.controller.panelFrameForTesting)
        #expect(size == CGSize(width: 540, height: 500))
        #expect(abs(resized.maxX - before.maxX) < 1)
        #expect(abs(resized.maxY - before.maxY) < 1)
        #expect(harness.controller.noteCardSize == noteSize)
        harness.controller.collapse()
        harness.controller.summon()
        #expect(harness.controller.chatCardSize == size)
        #expect(HerdrHudController(userDefaults: harness.defaults).chatCardSize == size)
        harness.controller.resetChatSize()
        // The displayed default can be shorter on the CI runner's small screen;
        // reset still saves the full preference for a larger display later.
        #expect(harness.controller.chatCardSize == initialChatSize)
        #expect(HerdrHudController(userDefaults: harness.defaults).chatCardSize == HerdrHudPlacement.expandedSize)
    }

    @Test("End Chat closes only its selected card and keeps the fresh composer's draft")
    func endSelectedChat() async throws {
        let harness = makeHarness()
        defer { harness.controller.setEnabled(false) }
        let chats = try #require(harness.controller.chats)
        let session = chats.composer
        session.draft = "Plan a picnic"
        await harness.controller.submitChat(session, model: harness.model)
        let id = try #require(chats.visibleChats.first?.id)
        chats.composer.draft = "Keep this other draft"
        harness.controller.openChat(id)
        try await harness.controller.endChat(id, model: harness.model)
        #expect(!harness.controller.isExpanded)
        #expect(chats.visibleChats.isEmpty)
        #expect(chats.composer.draft == "Keep this other draft")
        #expect(session.hasEnded)
    }

    @Test("Validation failures keep the original composer open and do not create bubbles")
    func invalidSubmissionStaysOpen() async throws {
        let harness = makeHarness()
        defer { harness.controller.setEnabled(false) }
        harness.controller.summon()
        let chats = try #require(harness.controller.chats)
        let composer = chats.composer
        await harness.controller.submitChat(composer, model: harness.model)
        #expect(harness.controller.isExpanded)
        #expect(chats.composer === composer)
        #expect(chats.visibleChats.isEmpty)
    }

    @Test("Hiding notes preserves their contents and the HUD, and persists independently")
    func noteVisibilityIsIndependentAndPersistent() async throws {
        let harness = makeHarness()
        await harness.notes.waitForPersistenceRestoreForTesting()
        let id = harness.notes.createNote()
        harness.notes.updateBody("Keep this note", for: id)
        harness.controller.setNotesVisible(false)
        #expect(harness.controller.isEnabled)
        #expect(!harness.controller.areNotesVisible)
        #expect(harness.notes.layout == .hidden)
        #expect(harness.notes.openNoteID == nil)
        #expect(harness.notes.note(id: id)?.body == "Keep this note")
        let reloaded = HerdrHudController(userDefaults: harness.defaults)
        #expect(!reloaded.areNotesVisible)
        harness.controller.setEnabled(false)
        #expect(!reloaded.isEnabled)
        harness.controller.setEnabled(true)
        #expect(harness.notes.layout == .hidden)
        harness.controller.setNotesVisible(true)
        #expect(harness.notes.layout == .icon)
        #expect(HerdrHudController(userDefaults: harness.defaults).areNotesVisible)
    }

    @Test("Explicitly opening a note restores hidden notes and HUD")
    func openNoteRestoresVisibility() async throws {
        let harness = makeHarness()
        await harness.notes.waitForPersistenceRestoreForTesting()
        let id = harness.notes.createNote()
        harness.controller.setNotesVisible(false)
        harness.controller.setEnabled(false)
        harness.controller.openNote(id)
        #expect(harness.controller.isEnabled)
        #expect(harness.controller.areNotesVisible)
        #expect(harness.notes.layout == .card)
        #expect(harness.notes.openNoteID == id)
    }

    @Test("New note opens an editor with the HUD and notes hidden")
    func newNoteRestoresVisibility() async throws {
        let harness = makeHarness()
        await harness.notes.waitForPersistenceRestoreForTesting()
        harness.controller.setNotesVisible(false)
        harness.controller.setEnabled(false)
        harness.controller.createNote()
        #expect(harness.controller.isEnabled)
        #expect(harness.controller.areNotesVisible)
        #expect(harness.notes.notes.count == 1)
        #expect(harness.notes.layout == .card)
        #expect(harness.notes.openNoteID == harness.notes.notes.first?.id)
        let firstID = harness.notes.openNoteID
        harness.controller.createNote()
        #expect(harness.notes.notes.count == 2)
        #expect(harness.notes.openNoteID != firstID)
        #expect(harness.notes.layout == .card)
    }

    @Test("Orb renders selected compact toggle opposite quick-hide with Notes and microphone below")
    func rendersFourOrbHoverControls() async throws {
        let harness = makeHarness(includesVoice: true)
        harness.controller.setUltraCompactEnabled(true)
        harness.controller.setHoveringHud(true, region: "render")
        let result = try await HerdrRenderHarness.render("hud-four-hover-controls-selected.png", size: CGSize(width: 180, height: 180)) {
            HerdrHudOrbResultRow(
                model: harness.model, controller: harness.controller, session: harness.session,
                artifacts: [], attentionChipCount: 1
            )
        }
        result.expectSubstantial(minimumBytes: 4000)
        harness.controller.setEnabled(false)
        #expect(!harness.controller.isEnabled)
        #expect(!harness.controller.isExpanded)
        harness.controller.setEnabled(true)
        #expect(harness.controller.isEnabled)
    }

    @MainActor
    private final class ScreenshotCaptureBarrier {
        private var continuations: [Int: CheckedContinuation<URL, any Error>] = [:]
        private(set) var invocationCount = 0

        func capture(_ target: HerdrFocusedWindowTarget) async throws -> URL {
            invocationCount += 1
            let invocation = invocationCount
            return try await withCheckedThrowingContinuation {
                continuations[invocation] = $0
            }
        }

        func waitUntilStarted(
            invocation: Int = 1,
            timeout: Duration = .seconds(2)
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while invocationCount < invocation {
                guard clock.now < deadline else {
                    throw AsyncWaitError.timedOut("screenshot capture invocation \(invocation) did not start")
                }
                try await clock.sleep(for: .milliseconds(1))
            }
        }

        func succeed(with url: URL, invocation: Int? = nil) {
            takeContinuation(invocation: invocation)?.resume(returning: url)
        }

        func fail(with error: any Error, invocation: Int? = nil) {
            takeContinuation(invocation: invocation)?.resume(throwing: error)
        }

        func cancelAll() {
            let pending = Array(continuations.values)
            continuations.removeAll()
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }

        private func takeContinuation(
            invocation: Int?
        ) -> CheckedContinuation<URL, any Error>? {
            guard let key = invocation ?? continuations.keys.min() else { return nil }
            return continuations.removeValue(forKey: key)
        }
    }

    private struct Harness {
        let defaults: UserDefaults
        let model: HerdrAppModel
        let session: HerdrHudSession
        let notes: HerdrHudNotesState
        let controller: HerdrHudController
    }

    private func makeHarness(
        chipRegroupDelay: Duration = .seconds(5),
        includesVoice: Bool = false,
        attachmentHoverGrace: Duration = .milliseconds(180),
        screenshotSelection: HerdrHudController.FocusedWindowSelection? = nil,
        screenshotCapture: HerdrHudController.FocusedWindowScreenshotCapture? = nil
    ) -> Harness {
        HerdrTestAppIcon.install()
        let defaults = makeDefaults()
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        let promptSettings = HerdrPromptSettingsStore(defaults: defaults)
        let session = HerdrHudSession(userDefaults: defaults, agentSettings: agentSettings, persistenceURL: temporaryURL(named: "hud-thread.json"), promptSettings: promptSettings)
        let notes = HerdrHudNotesState(userDefaults: defaults, agentSettings: agentSettings, promptSettings: promptSettings, persistenceURL: temporaryURL(named: "hud-notes.json"), hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero)
        let controller = HerdrHudController(
            userDefaults: defaults,
            chipRegroupDelay: chipRegroupDelay,
            attachmentHoverGrace: attachmentHoverGrace,
            focusedWindowSelection: screenshotSelection ?? { processID in
                HerdrFocusedWindowTarget(processID: processID ?? 0, windowID: 99)
            },
            focusedWindowScreenshotCapture: screenshotCapture ?? { _ in
                throw HerdrFocusedWindowScreenshotError.captureFailed
            },
            screenshotShortcutFlagsProvider: { 0 }
        )
        let voice = includesVoice ? QuickVoicePanelController(defaults: defaults) : nil
        voice?.setEnabled(true)
        controller.configure(model: model, session: session, notes: notes, fontScale: HerdrFontScaleStore(), quickVoice: voice)
        return Harness(defaults: defaults, model: model, session: session, notes: notes, controller: controller)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HerdrHudControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { preconditionFailure("Could not create isolated defaults") }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private enum AsyncWaitError: Error {
        case timedOut(String)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw AsyncWaitError.timedOut("condition was not met before the deadline")
            }
            try await clock.sleep(for: .milliseconds(1))
        }
    }

    private func writeSyntheticPNG(to url: URL) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 8,
            bitsPerPixel: 32
        ))
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        bitmap.setColor(.systemGreen, atX: 1, y: 0)
        bitmap.setColor(.systemOrange, atX: 0, y: 1)
        bitmap.setColor(.systemPink, atX: 1, y: 1)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
        return data
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
