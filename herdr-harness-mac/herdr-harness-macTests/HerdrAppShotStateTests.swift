import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("App Shots state")
@MainActor
struct HerdrAppShotStateTests {
    @Test("Capture targets the remembered app when Herdr itself is frontmost")
    func captureTargetSelection() {
        #expect(HerdrAppShotTarget.processID(frontmostProcessID: 100, lastExternalProcessID: 200, ownProcessID: 9) == 100)
        #expect(HerdrAppShotTarget.processID(frontmostProcessID: 9, lastExternalProcessID: 200, ownProcessID: 9) == 200)
        #expect(HerdrAppShotTarget.processID(frontmostProcessID: 9, lastExternalProcessID: nil, ownProcessID: 9) == nil)
        #expect(HerdrAppShotTarget.processID(frontmostProcessID: nil, lastExternalProcessID: 200, ownProcessID: 9) == 200)
        #expect(HerdrAppShotTarget.processID(frontmostProcessID: nil, lastExternalProcessID: nil, ownProcessID: 9) == nil)
    }

    @Test("The HUD notice renders nothing while idle and describes every visible state")
    func noticePresentation() {
        #expect(HerdrHudAppShotNotice.notice(for: .idle) == nil)

        let capturing = HerdrHudAppShotNotice.notice(for: .capturing(startedAt: Date()))
        #expect(capturing?.title == "Capturing frontmost window…")
        #expect(capturing?.isFailure == false)

        let attached = HerdrHudAppShotNotice.notice(for: .attached(filename: "Shot.png"))
        #expect(attached?.title == "Screenshot added to New chat")
        #expect(attached?.isFailure == false)

        let failed = HerdrHudAppShotNotice.notice(for: .failed(message: "Allow Herdr to record the screen."))
        #expect(failed?.title == "Allow Herdr to record the screen.")
        #expect(failed?.isFailure == true)
    }

    @Test("Notifications describe detection and failure without private data")
    func notificationContent() {
        let detected = HerdrAppShotNotification.detected()
        #expect(detected.title == "Herdr App Shots")
        #expect(detected.body.contains("Capturing"))
        #expect(!detected.isFailure)

        let failed = HerdrAppShotNotification.failed(message: "Herdr couldn’t find a visible app window to capture.")
        #expect(failed.body == "Herdr couldn’t find a visible app window to capture.")
        #expect(failed.isFailure)
    }

    @Test("The settings readout reports both keys and the observing signal")
    func commandKeyReadout() {
        let idle = HerdrCommandKeyReadout.text(
            for: HerdrCommandKeyState(isLeftCommandPressed: false, isRightCommandPressed: false, signal: .keyState),
            keyboardAccessGranted: false
        )
        #expect(idle.contains("Left ⌘ up"))
        #expect(idle.contains("Right ⌘ up"))
        #expect(idle.contains("key state"))

        let both = HerdrCommandKeyReadout.text(
            for: HerdrCommandKeyState(isLeftCommandPressed: true, isRightCommandPressed: true, signal: .globalMonitor),
            keyboardAccessGranted: true
        )
        #expect(both.contains("Left ⌘ down"))
        #expect(both.contains("Right ⌘ down"))
        #expect(both.contains("keyboard access"))

        let noSignal = HerdrCommandKeyReadout.text(
            for: .released,
            keyboardAccessGranted: false
        )
        #expect(noSignal.contains("grant keyboard access"))
    }

    @Test("Triggers are named for the diagnostics readout")
    func triggerTitles() {
        #expect(HerdrAppShotTrigger.chord.title == "Both Command keys")
        #expect(HerdrAppShotTrigger.hotKey.title == "⌃⌥C")
        #expect(HerdrAppShotTrigger.menu.title == "File menu")
        #expect(HerdrAppShotTrigger.settings.title == "Settings test")
    }

    @Test("The collapsed orb shows an outcome badge but no duplicate capture ring")
    func orbBadge() {
        #expect(HerdrHudAppShotNotice.badge(for: .idle) == nil)
        // Capturing is already signalled by the orb's capture ring.
        #expect(HerdrHudAppShotNotice.badge(for: .capturing(startedAt: Date())) == nil)
        #expect(HerdrHudAppShotNotice.badge(for: .attached(filename: "Shot.png"))?.isFailure == false)
        #expect(HerdrHudAppShotNotice.badge(for: .failed(message: "Nope"))?.isFailure == true)
    }
}
