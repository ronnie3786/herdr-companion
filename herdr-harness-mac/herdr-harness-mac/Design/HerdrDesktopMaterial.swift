import AppKit
import SwiftUI

/// Apple's material for peeking through a window's background. AppKit owns
/// the desktop blur; Herdr's purple tint is drawn above this native surface.
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
