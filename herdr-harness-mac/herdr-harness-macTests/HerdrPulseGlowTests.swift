import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr pulse glow")
struct HerdrPulseGlowTests {
    @Test("Visibility mirrors the inactive opacity branch")
    func visibilityPolicy() {
        #expect(HerdrPulseGlow.isVisible(isActive: true))
        #expect(!HerdrPulseGlow.isVisible(isActive: false))
    }

    @Test("Animation only runs while active and motion is allowed")
    func animationPolicy() {
        #expect(HerdrPulseGlow.animation(isPulsing: true, reduceMotion: false) != nil)
        #expect(HerdrPulseGlow.animation(isPulsing: false, reduceMotion: false) == nil)
        #expect(HerdrPulseGlow.animation(isPulsing: true, reduceMotion: true) == nil)
    }

    @Test("Opacity preserves a resting reduce-motion signal")
    func opacityPolicy() {
        #expect(HerdrPulseGlow.opacity(isActive: false, isPulsing: true, reduceMotion: false) == 0)
        #expect(
            HerdrPulseGlow.opacity(isActive: true, isPulsing: true, reduceMotion: true)
                == HerdrPulseGlow.restOpacity
        )
        #expect(
            HerdrPulseGlow.opacity(isActive: true, isPulsing: false, reduceMotion: false)
                == HerdrPulseGlow.restOpacity
        )
        #expect(
            HerdrPulseGlow.opacity(isActive: true, isPulsing: true, reduceMotion: false)
                == HerdrPulseGlow.peakOpacity
        )
    }

    @Test("Working status keeps its own sidebar hue")
    func workingStatusColor() {
        #expect(SidebarTone.statusColor(for: .working) == AgentStatus.working.color)
        #expect(SidebarTone.statusColor(for: .idle) == SidebarTone.status)
        #expect(SidebarTone.statusColor(for: .unknown) == SidebarTone.status)
    }

    @Test("Tab working counts use machine-scoped tab IDs")
    func workingCountUsesScopedTabID() {
        let workspace = HerdrWorkspace(
            workspaceID: "workspace",
            number: 1,
            label: "Workspace",
            focused: false,
            paneCount: 4,
            tabCount: 2,
            activeTabID: "tab-1",
            agentStatus: .working,
            panes: [
                pane(id: "pane-1", tabID: "tab-1", status: .working),
                pane(id: "pane-2", tabID: "tab-1", status: .working),
                pane(id: "pane-3", tabID: "tab-1", status: .idle),
                pane(id: "pane-4", tabID: "tab-2", status: .working),
            ]
        )
        .stamped(machineID: "work-mac")

        #expect(workspace.workingCount(inTab: "work-mac|tab-1") == 2)
        #expect(workspace.workingCount(inTab: "tab-1") == 0)
    }

    private func pane(id: String, tabID: String, status: AgentStatus) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "workspace",
            tabID: tabID,
            focused: false,
            agentStatus: status,
            revision: 0,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }
}

@Suite("Herdr HUD notification presentation")
struct HerdrHudNotificationPresentationTests {
    @Test("Finished notifications use the green signal tone")
    func finishedTone() {
        #expect(HerdrHudNotificationPresentation.tone(for: [.done]) == .finished)
        #expect(
            HerdrHudNotificationPresentation.outlineColor(
                for: HerdrHudNotificationPresentation.Tone.finished
            ) == HerdrTheme.signal
        )
        #expect(AgentStatus.done.color == HerdrTheme.signal)
        #expect(HerdrHudNotificationPresentation.outlineColor(for: AgentStatus.done) == HerdrTheme.signal)
        #expect(HerdrHudNotificationPresentation.status(forHUDChat: .completed) == .done)
    }

    @Test("Blocked and failed notification projections retain the alert tone")
    func alertTone() {
        #expect(HerdrHudNotificationPresentation.tone(for: [.blocked]) == .alert)
        #expect(HerdrHudNotificationPresentation.tone(for: [.done, .blocked]) == .alert)
        #expect(
            HerdrHudNotificationPresentation.outlineColor(
                for: HerdrHudNotificationPresentation.Tone.alert
            ) == HerdrTheme.alert
        )
        #expect(AgentStatus.blocked.color == HerdrTheme.alert)
        #expect(HerdrHudNotificationPresentation.outlineColor(for: AgentStatus.blocked) == HerdrTheme.alert)
        #expect(HerdrHudNotificationPresentation.outlineColor(for: AgentStatus.working) == HerdrTheme.working)
        #expect(HerdrHudNotificationPresentation.status(forHUDChat: .failed) == .blocked)
        #expect(HerdrHudNotificationPresentation.status(forHUDChat: nil) == .blocked)
    }

    @Test("Legacy count-only callers get completion styling without inventing attention")
    func fallbackTone() {
        #expect(HerdrHudNotificationPresentation.tone(for: [], fallbackCount: 2) == .finished)
        #expect(HerdrHudNotificationPresentation.tone(for: [], fallbackCount: 0) == nil)
    }

    @Test("Ultra-compact status prioritizes work, alerts, completion, and idle")
    func ultraCompactTonePriority() {
        let working = HerdrHudNotificationPresentation.ultraCompactTone(
            sessionIsRunning: true,
            workingCount: 0,
            statuses: [.done, .blocked],
            isConnected: true
        )
        #expect(working == .working)
        #expect(HerdrHudNotificationPresentation.ultraCompactColor(for: working) == HerdrTheme.working)

        let projectedWorking = HerdrHudNotificationPresentation.ultraCompactTone(
            sessionIsRunning: false,
            workingCount: 1,
            statuses: [.done],
            isConnected: true
        )
        #expect(projectedWorking == .working)
        #expect(
            HerdrHudNotificationPresentation.ultraCompactTone(
                sessionIsRunning: false,
                workingCount: 0,
                statuses: [.done, .blocked],
                isConnected: true
            ) == .alert
        )
        #expect(
            HerdrHudNotificationPresentation.ultraCompactColor(for: .alert)
                == HerdrTheme.alert
        )
        #expect(
            HerdrHudNotificationPresentation.ultraCompactTone(
                sessionIsRunning: false,
                workingCount: 0,
                statuses: [.done],
                isConnected: true
            ) == .finished
        )
        #expect(
            HerdrHudNotificationPresentation.ultraCompactColor(for: .finished)
                == HerdrTheme.signal
        )
        #expect(
            HerdrHudNotificationPresentation.ultraCompactTone(
                sessionIsRunning: false,
                workingCount: 0,
                statuses: [],
                isConnected: true
            ) == .idle
        )
        #expect(HerdrHudNotificationPresentation.ultraCompactColor(for: .idle) == HerdrTheme.accent)
    }

    @Test("Ultra-compact offline status is muted and explicitly announced")
    func ultraCompactOfflineAccessibility() {
        let tone = HerdrHudNotificationPresentation.ultraCompactTone(
            sessionIsRunning: false,
            workingCount: 0,
            statuses: [],
            isConnected: false
        )
        #expect(tone == .offline)
        #expect(HerdrHudNotificationPresentation.ultraCompactColor(for: tone) == HerdrTheme.muted)
        #expect(HerdrHudNotificationPresentation.ultraCompactAccessibilityValue(for: tone) == "Offline")
        #expect(
            HerdrHudNotificationPresentation.ultraCompactAccessibilityValue(for: .alert)
                == "Blocked or failed work needs attention"
        )
    }

    @Test("The hidden visual count remains available to accessibility tools")
    func accessibleCount() {
        #expect(
            HerdrHudNotificationPresentation.orbAccessibilityValue(
                sessionIsRunning: false,
                attentionCount: 3,
                workingCount: 0,
                isConnected: true
            ) == "3 need attention"
        )
        #expect(
            HerdrHudNotificationPresentation.orbAccessibilityValue(
                sessionIsRunning: true,
                attentionCount: 3,
                workingCount: 0,
                isConnected: true
            ) == "Thinking"
        )
    }
}

@Suite("Herdr HUD orb motion")
struct HerdrHudOrbMotionTests {
    @Test("Motion state prioritizes an active HUD session")
    func statePolicy() {
        #expect(HerdrHudOrbMotion.state(sessionIsRunning: true, workingCount: 0) == .thinking)
        #expect(HerdrHudOrbMotion.state(sessionIsRunning: true, workingCount: 3) == .thinking)
        #expect(HerdrHudOrbMotion.state(sessionIsRunning: false, workingCount: 3, attentionCount: 1) == .attention)
        #expect(HerdrHudOrbMotion.state(sessionIsRunning: false, workingCount: 1) == .working)
        #expect(HerdrHudOrbMotion.state(sessionIsRunning: false, workingCount: 0) == .idle)
    }

    @Test("Reduce Motion and idle states never install a live timeline")
    func animationPolicy() {
        #expect(HerdrHudOrbMotion.usesTimeline(for: .thinking, reduceMotion: false))
        #expect(HerdrHudOrbMotion.usesTimeline(for: .working, reduceMotion: false))
        #expect(!HerdrHudOrbMotion.usesTimeline(for: .attention, reduceMotion: false))
        #expect(!HerdrHudOrbMotion.usesTimeline(for: .thinking, reduceMotion: true))
        #expect(!HerdrHudOrbMotion.usesTimeline(for: .working, reduceMotion: true))
        #expect(!HerdrHudOrbMotion.usesTimeline(for: .idle, reduceMotion: false))
    }

    @Test("Animated ring cadence is capped and working pulse stays in range")
    func cadenceAndPulsePolicy() {
        #expect(HerdrHudOrbMotion.timelineCadence >= 1.0 / 12.0)
        let rest = Date(timeIntervalSinceReferenceDate: 0)
        let peak = Date(timeIntervalSinceReferenceDate: HerdrHudOrbMotion.workingPeriod / 2)
        #expect(abs(HerdrHudOrbMotion.workingOpacity(at: rest) - HerdrHudOrbMotion.workingRestOpacity) < 0.0001)
        #expect(abs(HerdrHudOrbMotion.workingOpacity(at: peak) - HerdrHudOrbMotion.workingPeakOpacity) < 0.0001)
        let inBetween = HerdrHudOrbMotion.workingOpacity(at: Date(timeIntervalSinceReferenceDate: 0.3))
        #expect(inBetween >= HerdrHudOrbMotion.workingRestOpacity)
        #expect(inBetween <= HerdrHudOrbMotion.workingPeakOpacity)
    }
}
