import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("First Mate HUD controller placement", .serialized)
@MainActor
struct FirstMateHudControllerPlacementTests {
    private typealias Geometry = FirstMateHudGeometry
    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let initialFace = CGPoint(x: 900, y: 790)

    private func withController(count: Int = 7,
                                _ check: (FirstMateHudController, UserDefaults) async throws -> Void) async throws {
        let suiteName = "FirstMateHudControllerPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: defaults)
        await shell.firstMateChatDemo.store.refresh()
        let hud = FirstMateHudController(defaults: defaults, isInert: true)
        hud.demoCount = count
        hud.prepareForRendering(model: model, shell: shell, visibleFrame: Self.screen, face: Self.initialFace)
        defer {
            hud.clearLatestLine()
            // The controller intentionally keeps these references weak.
            withExtendedLifetime((model, shell)) {}
        }
        try await check(hud, defaults)
    }

    private func screenFace(_ hud: FirstMateHudController) -> CGPoint {
        CGPoint(x: hud.layout.panelFrame.minX + hud.layout.faceCenter.x,
                y: hud.layout.panelFrame.maxY - hud.layout.faceCenter.y)
    }

    private func frame(_ hud: FirstMateHudController, placingFaceAt point: CGPoint) -> CGRect {
        let current = screenFace(hud)
        return hud.layout.panelFrame.offsetBy(dx: point.x - current.x, dy: point.y - current.y)
    }

    private func expectPlacement(_ hud: FirstMateHudController, defaults: UserDefaults, at point: CGPoint) {
        #expect(screenFace(hud) == point)
        let saved = defaults.array(forKey: FirstMateHudPreferences.faceKey) as? [NSNumber]
        #expect(saved?.map(\.doubleValue) == [Double(point.x), Double(point.y)])
    }

    @Test("The collapsed latest line hugs either side of the face above the orb row", arguments: [6, 7])
    func latestLineHugsFace(count: Int) async throws {
        try await withController(count: count) { hud, _ in
            #expect(hud.items.count == count)
            #expect(!hud.isExpanded)
            #expect(hud.visibleCard == .latestLine)
            for point in [Self.initialFace, CGPoint(x: 1370, y: 790)] {
                hud.adoptPanelFrame(frame(hud, placingFaceAt: point))
                let card = try #require(hud.layout.cardFrame)
                let distance = hud.layout.cardSide == .trailing
                    ? card.minX - hud.layout.faceCenter.x : hud.layout.faceCenter.x - card.maxX
                let reach = Geometry.faceRadius + Geometry.cardGap
                    + (hud.layout.cardSide == .trailing ? Geometry.badgeReach : 0)
                #expect(distance > 0 && distance <= reach)
                #expect(card.maxY <= hud.layout.faceCenter.y + Geometry.orbRowDrop - Geometry.orbSize / 2 - Geometry.cardGap / 2)
            }
        }
    }

    @Test("A latest line near the top falls back past the orb row")
    func latestLineTopFallback() async throws {
        try await withController { hud, _ in
            hud.adoptPanelFrame(frame(hud, placingFaceAt: CGPoint(x: 900, y: 839)))
            let card = try #require(hud.layout.cardFrame)
            #expect(hud.layout.cardSide == .trailing)
            #expect(card.minX - hud.layout.faceCenter.x == Geometry.collapsedHalfWidth(orbCount: 6) + Geometry.badgeReach + Geometry.cardGap)
            #expect(hud.layout.panelFrame.maxY - card.minY <= Self.screen.maxY - Geometry.margin)
        }
    }

    @Test("Drops at lower-left, middle, upper, and right points are saved without snapping", arguments: [
        CGPoint(x: 160, y: 240), CGPoint(x: 720, y: 450), CGPoint(x: 480, y: 810), CGPoint(x: 1280, y: 360),
    ])
    func freePlacement(point: CGPoint) async throws {
        try await withController { hud, defaults in
            hud.adoptPanelFrame(frame(hud, placingFaceAt: point))
            expectPlacement(hud, defaults: defaults, at: point)
            hud.relayout()
            expectPlacement(hud, defaults: defaults, at: point)
        }
    }

    @Test("A low drop survives relayout, list expansion, and opening or closing the latest line")
    func lowDropSticks() async throws {
        try await withController { hud, defaults in
            let point = CGPoint(x: 160, y: 240)
            hud.adoptPanelFrame(frame(hud, placingFaceAt: point))
            hud.relayout()
            expectPlacement(hud, defaults: defaults, at: point)
            hud.setExpanded(true)
            expectPlacement(hud, defaults: defaults, at: point)
            hud.clearLatestLine()
            #expect(hud.visibleCard == nil)
            expectPlacement(hud, defaults: defaults, at: point)
            hud.setExpanded(false)
            expectPlacement(hud, defaults: defaults, at: point)
            hud.openExplicit(.latestLine)
            #expect(hud.visibleCard == .latestLine)
            expectPlacement(hud, defaults: defaults, at: point)
            hud.closeCard(.latestLine)
            #expect(hud.visibleCard == nil)
            expectPlacement(hud, defaults: defaults, at: point)
        }
    }

    @Test("A partly offscreen drop clamps only the face, not the row or expanded list")
    func bottomClamp() async throws {
        try await withController { hud, defaults in
            let point = CGPoint(x: 160, y: 20)
            let expected = Geometry.clampFace(point, visibleFrame: Self.screen)
            hud.adoptPanelFrame(frame(hud, placingFaceAt: point))
            expectPlacement(hud, defaults: defaults, at: expected)
            #expect(screenFace(hud).y == Self.screen.minY + Geometry.faceRadius + Geometry.margin)
            hud.setExpanded(true)
            expectPlacement(hud, defaults: defaults, at: expected)
        }
    }

    @Test("Move notifications during a drag defer saving and layout until the drop")
    func movesDuringDrag() async throws {
        try await withController { hud, defaults in
            let point = CGPoint(x: 160, y: 240)
            let panel = hud.makePanelForTesting()
            defer { panel.contentView = nil; panel.close() }
            let originalLayout = hud.layout
            hud.faceDragBegan()
            panel.setFrame(frame(hud, placingFaceAt: point), display: false)
            // Explicitly deliver the notification too, independent of the window server.
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
            #expect(hud.layout == originalLayout)
            #expect(defaults.object(forKey: FirstMateHudPreferences.faceKey) == nil)
            hud.relayout()
            #expect(hud.layout == originalLayout)
            hud.faceDragEnded()
            expectPlacement(hud, defaults: defaults, at: point)
            // Let the one-shot post-drag recheck run before closing the panel.
            await drainMainQueue()
            expectPlacement(hud, defaults: defaults, at: point)
        }
    }

    @Test("A panel move reported after the drag ends is adopted and saved")
    func lateMove() async throws {
        try await withController { hud, defaults in
            let panel = hud.makePanelForTesting()
            defer { panel.contentView = nil; panel.close() }
            hud.faceDragBegan()
            hud.faceDragEnded()
            expectPlacement(hud, defaults: defaults, at: Self.initialFace)
            let point = CGPoint(x: 160, y: 240)
            panel.setFrame(frame(hud, placingFaceAt: point), display: false)
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
            expectPlacement(hud, defaults: defaults, at: point)
            await drainMainQueue()
            hud.relayout()
            expectPlacement(hud, defaults: defaults, at: point)
            #expect(panel.frame == hud.layout.panelFrame)
        }
    }

    @Test("Programmatic frame moves during relayout never save the face")
    func programmaticMoves() async throws {
        try await withController { hud, defaults in
            let panel = hud.makePanelForTesting()
            defer { panel.contentView = nil; panel.close() }
            var moveCount = 0
            // Unordered panels need not post didMove. Inject it synchronously
            // from each real frame change to exercise relayout's move guard.
            let observation = panel.observe(\.frame, options: [.new]) { [weak hud] _, _ in
                MainActor.assumeIsolated {
                    guard let panel = hud?.makePanelForTesting() else { return }
                    moveCount += 1
                    NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
                }
            }
            defer { observation.invalidate() }
            hud.setExpanded(true)
            hud.clearLatestLine()
            hud.setExpanded(false)
            hud.openExplicit(.latestLine)
            #expect(moveCount > 0, "The test delivered synchronous move notifications inside setFrame")
            #expect(screenFace(hud) == Self.initialFace)
            #expect(panel.frame == hud.layout.panelFrame)
            #expect(defaults.object(forKey: FirstMateHudPreferences.faceKey) == nil)
            let point = CGPoint(x: 160, y: 240)
            hud.adoptPanelFrame(frame(hud, placingFaceAt: point))
            expectPlacement(hud, defaults: defaults, at: point)
            hud.closeCard(.latestLine)
            hud.setExpanded(true)
            expectPlacement(hud, defaults: defaults, at: point)
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
