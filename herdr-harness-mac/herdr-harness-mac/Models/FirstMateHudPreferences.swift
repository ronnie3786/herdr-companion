import Foundation

/// Settings for the First Mate HUD, a floating panel separate from the agent
/// HUD. Each has its own switch, place, and state.
enum FirstMateHudPreferences {
    /// Settings ▸ HUD ▸ "First Mate HUD", and View ▸ Show First Mate HUD. On
    /// by default; it still shows only once a machine has First Mate.
    static let enabledKey = "herdr.mac.firstMate.hud"
    static let defaultEnabled = true
    /// The face's center in screen coordinates, so it returns to the same
    /// display; a point on no screen falls back to the default place.
    static let faceKey = "herdr.mac.firstMate.hud.face"
    /// Whether the list is open.
    static let expandedKey = "herdr.mac.firstMate.hud.expanded"
    /// Demo mode only: `-HerdrFirstMateHudDemoCount 6|10|14` sizes the demo fleet.
    static let demoCountArgument = "-HerdrFirstMateHudDemoCount"

    /// `bool(forKey:)` also reads a launch argument such as
    /// `-herdr.mac.firstMate.hud YES`.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }

    /// The demo fleet size from the launch arguments, if one was given.
    static func demoCount(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        guard let index = arguments.firstIndex(of: demoCountArgument), arguments.indices.contains(index + 1) else { return nil }
        return Int(arguments[index + 1]).map { min(max($0, 1), 20) }
    }
}
