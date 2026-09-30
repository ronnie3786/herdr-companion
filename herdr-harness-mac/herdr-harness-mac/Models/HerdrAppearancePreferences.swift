import Foundation

/// Herdr's purple glass, native desktop translucency, and the chat's Haze band.
/// All are on by default; Reduce Transparency always draws opaque surfaces.
enum HerdrAppearancePreferences {
    /// Herdr's dusk backdrop behind the sidebar and pane (80%) and the HUD (78%).
    static let glassEnabledKey = "herdr.mac.appearance.glass"
    static let defaultGlassEnabled = true
    /// Native blur behind the standalone First Mate window, while glass is on.
    static let desktopTransparencyEnabledKey = "herdr.mac.appearance.desktopTransparency"
    static let defaultDesktopTransparencyEnabled = true
    /// The soft dusk band at the top of the chat. Shown only with glass.
    static let hazeEnabledKey = "herdr.mac.appearance.haze"
    static let defaultHazeEnabled = true
}
