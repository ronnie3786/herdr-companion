import Foundation

/// Mono × Herdr's Legible glass and the Haze band behind the chat. Both are
/// on by default; Reduce Transparency always wins and draws opaque surfaces.
enum HerdrAppearancePreferences {
    /// Blurred desktop behind the sidebar (80%), pane (75%) and HUD (78%).
    static let glassEnabledKey = "herdr.mac.appearance.glass"
    static let defaultGlassEnabled = true
    /// The soft dusk band at the top of the chat. Shown only with glass.
    static let hazeEnabledKey = "herdr.mac.appearance.haze"
    static let defaultHazeEnabled = true
}
