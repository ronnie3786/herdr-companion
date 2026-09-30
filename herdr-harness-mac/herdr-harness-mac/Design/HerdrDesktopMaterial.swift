import AppKit
import SwiftUI

/// AppKit blurs the actual desktop and windows underneath this scene. One
/// material spans the whole window, below Herdr's purple background layers.
struct HerdrDesktopMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
