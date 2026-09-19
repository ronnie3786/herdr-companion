import Foundation

/// Pure gate for the ten-minute background check, so the cadence can be
/// exercised without Sparkle, a network, or a running updater.
enum HerdrUpdateCheckPolicy {
    static func shouldRunBackgroundCheck(
        isConfigured: Bool,
        runtimeAllowed: Bool,
        isStarted: Bool,
        automaticallyChecksForUpdates: Bool,
        isSessionInProgress: Bool
    ) -> Bool {
        isConfigured && runtimeAllowed && isStarted && automaticallyChecksForUpdates && !isSessionInProgress
    }
}
