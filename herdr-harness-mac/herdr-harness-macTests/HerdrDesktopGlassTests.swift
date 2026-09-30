import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("First Mate desktop glass", .serialized)
@MainActor
struct HerdrDesktopGlassTests {
    @Test("A mounted First Mate window becomes translucent and restores its opaque fallback")
    func windowTransitions() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DesktopGlass.\(UUID().uuidString)"))
        defaults.set(true, forKey: HerdrAppearancePreferences.glassEnabledKey)
        let hosting = NSHostingView(rootView: scene(defaults: defaults, revealsDesktop: true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }

        await settle(hosting)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.alphaValue == 1, "Only the background may be translucent")
        #expect(hasDesktopMaterial(hosting))

        hosting.rootView = scene(defaults: defaults, revealsDesktop: false)
        await settle(hosting)
        #expect(window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 1)
        #expect(!hasDesktopMaterial(hosting))

        hosting.rootView = scene(defaults: defaults, revealsDesktop: true)
        await settle(hosting)
        #expect(!window.isOpaque)
        #expect(hasDesktopMaterial(hosting))

        defaults.set(false, forKey: HerdrAppearancePreferences.glassEnabledKey)
        hosting.rootView = scene(defaults: defaults, revealsDesktop: true)
        await settle(hosting)
        #expect(window.isOpaque)
        #expect(!hasDesktopMaterial(hosting))

        defaults.set(true, forKey: HerdrAppearancePreferences.glassEnabledKey)
        hosting.rootView = scene(defaults: defaults, revealsDesktop: false)
        await settle(hosting)
        #expect(window.isOpaque, "The main window keeps its existing background")
        #expect(!hasDesktopMaterial(hosting))

        hosting.rootView = scene(defaults: defaults, revealsDesktop: true, scheme: .light)
        await settle(hosting)
        #expect(window.isOpaque)
        #expect(!hasDesktopMaterial(hosting))
    }

    private func scene(
        defaults: UserDefaults,
        revealsDesktop: Bool,
        scheme: ColorScheme = .dark
    ) -> some View {
        Color.clear
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane) }
            .modifier(HerdrMainWindowChromeModifier(revealsDesktop: revealsDesktop))
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func hasDesktopMaterial(_ view: NSView) -> Bool {
        if let material = view as? NSVisualEffectView,
           material.blendingMode == .behindWindow,
           material.material == .underWindowBackground { return true }
        return view.subviews.contains(where: hasDesktopMaterial)
    }
}
