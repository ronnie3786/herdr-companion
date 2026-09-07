import SwiftUI

/// Observe visible controls before any reserved layout or shadow padding. A
/// removed control releases its region even if AppKit sends no hover exit.
private struct HerdrHudHoverRegion: ViewModifier {
    let id: String
    let action: (Bool, String) -> Void

    func body(content: Content) -> some View {
        content
            .onHover { action($0, id) }
            .onDisappear { action(false, id) }
    }
}

extension View {
    func herdrHudHoverRegion(
        _ id: String,
        action: @escaping (Bool, String) -> Void
    ) -> some View {
        modifier(HerdrHudHoverRegion(id: id, action: action))
    }
}
