import SwiftUI

private struct HomeReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct HomeReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Home follows the system unless a render explicitly supplies a preference.
    /// The system accessibility properties themselves are read-only on macOS.
    var homeReduceMotion: Bool {
        get { self[HomeReduceMotionKey.self] ?? accessibilityReduceMotion }
        set { self[HomeReduceMotionKey.self] = newValue }
    }

    var homeReduceTransparency: Bool {
        get { self[HomeReduceTransparencyKey.self] ?? accessibilityReduceTransparency }
        set { self[HomeReduceTransparencyKey.self] = newValue }
    }
}
