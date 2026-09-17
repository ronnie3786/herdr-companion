import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Focused app-window screenshot")
@MainActor
struct HerdrFocusedWindowScreenshotTests {
    @Test("Selection uses the frontmost visible normal-layer window for the captured process")
    func selectsFirstEligibleWindowForProcess() throws {
        let candidates = [
            candidate(pid: 22, id: 1),
            candidate(pid: 11, id: 2, layer: 1),
            candidate(pid: 11, id: 3, alpha: 0),
            candidate(pid: 11, id: 4, width: 40),
            candidate(pid: 11, id: 5),
            candidate(pid: 11, id: 6),
        ]

        let target = try HerdrFocusedWindowScreenshot.target(
            processID: 11,
            candidates: candidates
        )

        #expect(target == HerdrFocusedWindowTarget(processID: 11, windowID: 5))
    }

    @Test("A missing frontmost application is actionable")
    func missingApplicationFails() {
        #expect(throws: HerdrFocusedWindowScreenshotError.noFocusedApplication) {
            try HerdrFocusedWindowScreenshot.target(processID: nil, candidates: [])
        }
    }

    @Test("A process without an eligible visible window does not fall back")
    func missingWindowFailsWithoutFallback() {
        let candidates = [
            candidate(pid: 44, id: 1),
            candidate(pid: 33, id: 2, layer: 2),
            candidate(pid: 33, id: 3, height: 20),
        ]

        #expect(throws: HerdrFocusedWindowScreenshotError.noFocusedWindow) {
            try HerdrFocusedWindowScreenshot.target(processID: 33, candidates: candidates)
        }
    }

    @Test("Denied Screen Recording permission stops before window selection")
    func deniedPermissionIsExplicit() {
        #expect(throws: HerdrFocusedWindowScreenshotError.permissionRequired) {
            try HerdrFocusedWindowScreenshot.prepare(
                processID: 11,
                permissionCheck: { false }
            )
        }
    }

    @Test("Capture rechecks permission before ScreenCaptureKit access")
    func captureRechecksPermission() async {
        await #expect(throws: HerdrFocusedWindowScreenshotError.permissionRequired) {
            try await HerdrFocusedWindowScreenshot.capture(
                target: HerdrFocusedWindowTarget(processID: 11, windowID: 5),
                permissionCheck: { false }
            )
        }
    }

    private func candidate(
        pid: pid_t,
        id: CGWindowID,
        layer: Int = 0,
        alpha: Double = 1,
        width: CGFloat = 800,
        height: CGFloat = 600
    ) -> HerdrWindowCandidate {
        HerdrWindowCandidate(
            processID: pid,
            windowID: id,
            layer: layer,
            alpha: alpha,
            bounds: CGRect(x: 10, y: 10, width: width, height: height)
        )
    }
}
