import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import herdr_harness_mac

/// Drives a real HUD panel through the resting-circle round trip with the
/// production timings and records its live view hierarchy frame by frame,
/// together with the controller's state and the panel's actual frame. The
/// PNGs and `timeline.json` land next to the other renders; the assertions are
/// the behavioural contract: the collapse waits the full grace after the
/// pointer leaves, re-entry inside that window cancels it, and the panel keeps
/// the orb's frame until the morph back has landed.
@Suite("Herdr HUD morph live capture", .serialized)
@MainActor
struct HerdrHudMorphLiveCaptureTests {
    @Test("A hover preview morphs out of the circle, waits after exit, survives re-entry, and morphs back inside a held panel")
    func capturesTheRestingRoundTrip() async throws {
        let recorder = try LiveCaptureRecorder(directoryName: "hud-morph-live")
        let harness = makeHarness()
        defer { harness.controller.setEnabled(false) }
        let controller = harness.controller
        let clock = ContinuousClock()

        // Three synthetic HUD chats with an answer each (only answered chats
        // are visible), so the agents beneath the orb are part of the picture
        // in both directions.
        let chats = try #require(controller.chats)
        for (index, title) in ["Plan the launch", "Review the diff", "Draft release notes"].enumerated() {
            let composer = chats.composer
            composer.draft = title
            composer.seedExchangesForTesting([
                HerdrHudExchange(
                    id: "live-\(index)",
                    machineID: "demo1",
                    prompt: title,
                    sentPrompt: title,
                    response: "Done: \(title.lowercased()).",
                    error: nil,
                    status: .completed,
                    costUSD: nil,
                    createdAt: .now,
                    promotedPaneID: nil,
                    attachmentFilenames: []
                ),
            ])
            chats.submissionStarted(composer)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.collapsedChipCount == 3)

        // 0. Turning the orb into the resting circle is itself a morph: the
        //    panel is held at the orb's size while the orb contracts, then snaps.
        recorder.beginPhase("enable", clock: clock)
        controller.setUltraCompactEnabled(true)
        #expect(controller.isUltraCompactResting)
        #expect(controller.isRestingFrameHeld)
        try await recorder.record(
            controller, phase: "enable", every: .milliseconds(16), timeout: .seconds(3), clock: clock
        ) { controller.usesUltraCompactLane }
        try await Task.sleep(for: .milliseconds(200))
        let restingFrame = try #require(controller.panelFrameForTesting)
        #expect(controller.usesUltraCompactLane)
        #expect(restingFrame.size == CGSize(
            width: HerdrHudPlacement.collapsedSize.width + 2 * HerdrHudPlacement.ultraCompactShadowMargin,
            height: HerdrHudPlacement.collapsedSize.height + 2 * HerdrHudPlacement.ultraCompactShadowMargin
        ))
        recorder.capture(controller, phase: "rest", clock: clock)

        // 1. Hover the circle: the panel takes the orb's frame at once and the
        //    morph out plays inside it.
        recorder.beginPhase("expand", clock: clock)
        controller.setHoveringHud(true, region: "hud-ultra-compact")
        let previewFrame = try #require(controller.panelFrameForTesting)
        #expect(previewFrame.width > restingFrame.width)
        #expect(!controller.isUltraCompactResting)
        try await recorder.record(controller, phase: "expand", for: .milliseconds(750), every: .milliseconds(16), clock: clock)

        // 2. Leave: the HUD must stay open through the grace window.
        recorder.beginPhase("exit-wait", clock: clock)
        let firstExit = clock.now
        controller.setHoveringHud(false, region: "hud-ultra-compact")
        #expect(controller.isUltraCompactCollapsePending)
        try await recorder.record(controller, phase: "exit-wait", for: .milliseconds(900), every: .milliseconds(100), clock: clock)
        #expect(!controller.isUltraCompactResting, "still open well after the old 180 ms grace")
        #expect(controller.areOrbControlsVisible)

        // 3. Come back inside the window: the pending collapse is cancelled.
        let reentry = clock.now
        try #require(firstExit.duration(to: reentry) < .seconds(2), "re-entry must land inside the two-second window")
        recorder.beginPhase("reentry", clock: clock)
        controller.setHoveringHud(true, region: "hud-orb")
        #expect(!controller.isUltraCompactCollapsePending)
        try await recorder.record(controller, phase: "reentry", for: .milliseconds(1_800), every: .milliseconds(200), clock: clock)
        #expect(firstExit.duration(to: clock.now) > .milliseconds(2_500))
        #expect(!controller.isUltraCompactResting, "the cancelled countdown never fired")

        // 4. Leave for good and time the collapse.
        recorder.beginPhase("collapse-wait", clock: clock)
        let finalExit = clock.now
        controller.setHoveringHud(false, region: "hud-orb")
        #expect(controller.isUltraCompactCollapsePending)
        try await recorder.record(
            controller, phase: "collapse-wait", every: .milliseconds(50), timeout: .seconds(4), clock: clock
        ) { controller.isUltraCompactResting }
        let collapseLatency = finalExit.duration(to: clock.now)
        #expect(collapseLatency >= .milliseconds(2_150), "grace 180 ms + 2 s before resting, got \(collapseLatency)")
        #expect(collapseLatency < .milliseconds(3_500))
        #expect(!controller.isUltraCompactCollapsePending)

        // 5. The morph back plays inside the orb's frame, which then snaps to the circle's.
        #expect(controller.isRestingFrameHeld, "the panel is held at the orb's size while the orb contracts")
        #expect(!controller.usesUltraCompactLane)
        let heldFrame = try #require(controller.panelFrameForTesting)
        #expect(heldFrame.width == previewFrame.width)
        #expect(heldFrame.height >= HerdrHudPlacement.collapsedSize.height + 2 * HerdrHudPlacement.shadowMargin)
        recorder.beginPhase("collapse", clock: clock)
        try await recorder.record(controller, phase: "collapse", for: .milliseconds(700), every: .milliseconds(16), clock: clock)
        #expect(!controller.isRestingFrameHeld)
        #expect(controller.usesUltraCompactLane)
        #expect(controller.panelFrameForTesting?.size == restingFrame.size)
        recorder.capture(controller, phase: "rest-again", clock: clock)

        try recorder.finish()
        #expect(recorder.frameCount > 60)
        print("HUD morph live capture: \(recorder.directory.path) (\(recorder.frameCount) frames, \(recorder.method))")
    }

    // MARK: Recorder

    /// Records the panel's content view each frame and the controller's state
    /// alongside it.
    @MainActor
    private final class LiveCaptureRecorder {
        struct Frame: Codable {
            let phase: String
            let phaseElapsedMs: Int
            let totalElapsedMs: Int
            let file: String
            let panelWidth: Double
            let panelHeight: Double
            let isUltraCompactResting: Bool
            let isRestingFrameHeld: Bool
            let isUltraCompactCollapsePending: Bool
            let areOrbControlsVisible: Bool
            let usesUltraCompactLane: Bool
        }

        let directory: URL
        private(set) var frames: [Frame] = []
        private(set) var method = "unknown"
        private var phaseStart: ContinuousClock.Instant?
        private var start: ContinuousClock.Instant?
        var frameCount: Int { frames.count }

        init(directoryName: String) throws {
            directory = HerdrRenderHarness.directory.appending(path: directoryName, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func beginPhase(_ phase: String, clock: ContinuousClock) {
            phaseStart = clock.now
            if start == nil { start = phaseStart }
        }

        func record(
            _ controller: HerdrHudController,
            phase: String,
            for duration: Duration,
            every interval: Duration,
            clock: ContinuousClock
        ) async throws {
            let deadline = clock.now.advanced(by: duration)
            while clock.now < deadline {
                capture(controller, phase: phase, clock: clock)
                try await clock.sleep(for: interval)
            }
            capture(controller, phase: phase, clock: clock)
        }

        func record(
            _ controller: HerdrHudController,
            phase: String,
            every interval: Duration,
            timeout: Duration,
            clock: ContinuousClock,
            until condition: @MainActor () -> Bool
        ) async throws {
            let deadline = clock.now.advanced(by: timeout)
            while !condition() {
                guard clock.now < deadline else {
                    throw LiveCaptureError.timedOut(phase)
                }
                capture(controller, phase: phase, clock: clock)
                try await clock.sleep(for: interval)
            }
            capture(controller, phase: phase, clock: clock)
        }

        func capture(_ controller: HerdrHudController, phase: String, clock: ContinuousClock) {
            let now = clock.now
            if start == nil { start = now }
            if phaseStart == nil { phaseStart = now }
            guard let panel = controller.panelForTesting else { return }
            let index = frames.count
            let phaseElapsed = milliseconds(phaseStart!.duration(to: now))
            let file = String(format: "%03d-%@-%04dms.png", index, phase, phaseElapsed)
            if let data = capturePNG(of: panel) {
                try? data.write(to: directory.appending(path: file), options: .atomic)
            }
            frames.append(Frame(
                phase: phase,
                phaseElapsedMs: phaseElapsed,
                totalElapsedMs: milliseconds(start!.duration(to: now)),
                file: file,
                panelWidth: panel.frame.width,
                panelHeight: panel.frame.height,
                isUltraCompactResting: controller.isUltraCompactResting,
                isRestingFrameHeld: controller.isRestingFrameHeld,
                isUltraCompactCollapsePending: controller.isUltraCompactCollapsePending,
                areOrbControlsVisible: controller.areOrbControlsVisible,
                usesUltraCompactLane: controller.usesUltraCompactLane
            ))
        }

        func finish() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(frames)
            try data.write(to: directory.appending(path: "timeline.json"), options: .atomic)
        }

        /// Draws the live panel's view hierarchy at Retina density. The window
        /// server's capture APIs are unavailable on this SDK or gated behind
        /// the Screen Recording permission, which a test must never prompt for.
        private func capturePNG(of panel: NSPanel) -> Data? {
            guard let view = panel.contentView else { return nil }
            method = "cacheDisplay"
            let scale: CGFloat = 2
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width * scale),
                pixelsHigh: Int(view.bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            bitmap.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }

        private func milliseconds(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }

    private enum LiveCaptureError: Error {
        case timedOut(String)
    }

    // MARK: Harness

    private struct Harness {
        let model: HerdrAppModel
        let session: HerdrHudSession
        let notes: HerdrHudNotesState
        let controller: HerdrHudController
    }

    /// A real controller and panel with production timings. The panel is
    /// placed well away from the screen corner so it never covers a HUD the
    /// person running the tests may have there.
    private func makeHarness() -> Harness {
        HerdrTestAppIcon.install()
        let suiteName = "HerdrHudMorphLiveCaptureTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set([480, 240], forKey: "herdr.hud.offset.v2")
        defaults.set(false, forKey: "herdr.hud.notesVisible")
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        let promptSettings = HerdrPromptSettingsStore(defaults: defaults)
        let session = HerdrHudSession(
            userDefaults: defaults, agentSettings: agentSettings,
            persistenceURL: temporaryURL(named: "hud-thread.json"), promptSettings: promptSettings
        )
        let notes = HerdrHudNotesState(
            userDefaults: defaults, agentSettings: agentSettings, promptSettings: promptSettings,
            persistenceURL: temporaryURL(named: "hud-notes.json"),
            hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero
        )
        let controller = HerdrHudController(
            userDefaults: defaults,
            reduceMotionPreference: { false },
            focusedWindowSelection: { processID in
                HerdrFocusedWindowTarget(processID: processID ?? 0, windowID: 99)
            },
            focusedWindowScreenshotCapture: { _ in
                throw HerdrFocusedWindowScreenshotError.captureFailed
            },
            screenshotShortcutStateProvider: { .released },
            commandKeyMonitor: HerdrCommandKeyMonitor(
                keyStateQuery: { _, _ in false },
                flagsQuery: { _ in 0 },
                listenEventAccess: { false },
                requestListenEventAccess: { false }
            ),
            frontmostProcessProvider: { 321 },
            appShotNotificationPoster: { _ in }
        )
        controller.configure(model: model, session: session, notes: notes, fontScale: HerdrFontScaleStore())
        // Fully transparent but ordered in, like the render harness: the panel
        // is real to AppKit (frames, layout, hover regions) and its content
        // still draws into the captures, without flashing a HUD on the screen
        // of whoever runs the tests.
        controller.panelForTesting?.alphaValue = 0
        return Harness(model: model, session: session, notes: notes, controller: controller)
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
