import AppKit
import UserNotifications

/// AppKit port of the iOS `HerdrAppDelegate`. The notification-center delegate
/// and the notification-tap → pane deep-link relay are carried over unchanged;
/// APNs device registration is deliberately absent — the Mac app is co-located
/// with the Herdr server and holds the `/api/v1/events` SSE stream open, so
/// alerts are always delivered locally.
@MainActor
final class HerdrMacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var pendingPaneID: String?
    private static var isIssueReportPending = false

    static func takePendingPaneID() -> String? {
        defer { pendingPaneID = nil }
        return pendingPaneID
    }

    /// Settings ▸ Feedback and the Help menu ask for the report sheet from
    /// outside the main window. The flag survives until a main window drains
    /// it in its first `.task`, so the request is not lost when the window
    /// had been closed and `openWindow` is still recreating it; the
    /// notification covers the window that is already open.
    static func requestIssueReport() {
        isIssueReportPending = true
        NotificationCenter.default.post(name: .herdrPresentIssueReport, object: nil)
    }

    static func takePendingIssueReport() -> Bool {
        defer { isIssueReportPending = false }
        return isIssueReportPending
    }

    nonisolated static func resolvedPaneID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let paneID = (userInfo["pane_id"] as? String) ?? (userInfo["paneId"] as? String) else {
            return nil
        }
        if let machineID = userInfo["machine_id"] as? String, !machineID.isEmpty {
            return MachineScopedID.compose(machineID: machineID, rawID: paneID)
        }
        return paneID
    }

    nonisolated static func notificationPaneURL(for paneID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "herdr"
        components.host = "pane"
        components.queryItems = [URLQueryItem(name: "pane_id", value: paneID)]
        return components.url
    }

    static func openPaneURLWithFallback(_ paneID: String) {
        guard let url = notificationPaneURL(for: paneID) else {
            pendingPaneID = paneID
            NotificationCenter.default.post(name: .herdrOpenPane, object: paneID)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            if let error {
                NSLog("Herdr could not open its pane URL: %@", error.localizedDescription)
                Task { @MainActor in
                    pendingPaneID = paneID
                    NotificationCenter.default.post(name: .herdrOpenPane, object: paneID)
                }
            }
        }
    }

    /// Routes a `herdr://` link through this app's own URL handler, which
    /// validates it before navigating.
    static func openOwnURL(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { NSLog("Herdr could not open its PR Review link: %@", error.localizedDescription) }
        }
    }

    // MARK: Dock menu

    /// The First Mate conversations the Dock menu lists, and what choosing one
    /// does. The delegate has no model or `openWindow`, so the windows inject
    /// these (see `FirstMateAppServicesModifier`).
    var firstMateDockMenuItems: (@MainActor () -> [FirstMateDockMenuItem])?
    var openFirstMateDockMenuItem: (@MainActor (FirstMateFleetFeatureID) -> Void)?
    /// The First Mate Dock count, which owns the icon badge while its setting
    /// is on. Notifications then present without touching the badge.
    weak var firstMateDockBadge: FirstMateDockBadgeController?
    private var dockMenuTargets: [FirstMateFleetFeatureID] = []

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let items = firstMateDockMenuItems?() ?? []
        dockMenuTargets = items.map(\.id)
        return Self.dockMenu(items: items, target: self, action: #selector(openDockMenuItem(_:)))
    }

    /// Up to five First Mate conversations with a dot, or nil when none has
    /// one, so the Dock shows only its standard items.
    static func dockMenu(items: [FirstMateDockMenuItem], target: AnyObject?, action: Selector?) -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, item) in items.prefix(FirstMateDockMenuItem.limit).enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
            menuItem.target = target
            menuItem.tag = index
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func openDockMenuItem(_ sender: NSMenuItem) {
        guard dockMenuTargets.indices.contains(sender.tag) else { return }
        openFirstMateDockMenuItem?(dockMenuTargets[sender.tag])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test host's stalls are test load, not app hangs; keep them out of the user's hang log.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            HerdrPerfDiagnostics.start()
        }
        VoiceRecordingPolicy.removeStaleTemporaryRecordings()
        IssueReportComposer.removeStaleTemporaryDirectories()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Herdr owns a process-level event stream and an optional menu-bar scene.
    /// Closing its document window should behave like other Mac apps: keep the
    /// process alive so a pane deep link can recreate the window immediately.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // `UNUserNotificationCenterDelegate` is not main-actor isolated on macOS
    // (it is on iOS), so under Swift 6 these two witnesses must be nonisolated
    // and hop back to the main actor themselves.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The active app supplies semantic feedback from agent-state changes.
        // Keep the banner visible, but do not duplicate that feedback with a
        // generic notification sound while Herdr is in the foreground.
        let ownsBadge = await MainActor.run { self.firstMateDockBadge?.ownsBadge ?? false }
        if ownsBadge {
            // Written back over anything the notification did to the icon.
            Task { @MainActor in self.firstMateDockBadge?.reassert() }
        }
        return Self.presentationOptions(firstMateOwnsBadge: ownsBadge)
    }

    /// The banner always; the badge only while the First Mate count does not
    /// own the icon.
    nonisolated static func presentationOptions(firstMateOwnsBadge: Bool) -> UNNotificationPresentationOptions {
        firstMateOwnsBadge ? [.banner] : [.banner, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let route = (userInfo[WatchersNotification.routeKey] as? String).flatMap(URL.init(string:)), route.scheme == "herdr", route.host == "watchers" {
            await MainActor.run { Self.openOwnURL(route) }
            return
        }
        if let route = (userInfo[PRReviewWalkthroughNotification.routeKey] as? String).flatMap(URL.init(string:)),
           route.scheme == "herdr", route.host == "pr-review" {
            await MainActor.run { Self.openOwnURL(route) }
            return
        }
        guard let paneID = Self.resolvedPaneID(fromUserInfo: userInfo) else { return }
        await MainActor.run {
            Self.openPaneURLWithFallback(paneID)
        }
    }
}

extension Notification.Name {
    static let herdrOpenPane = Notification.Name("HerdrOpenPane")

    /// Mac-only. Posted by the View menu's "Focus Chat" / "Focus Terminal"
    /// commands with a `PaneDetailMode` as the notification object, so the
    /// mounted pane session can switch modes from the menu bar without the
    /// shell owning the pane's mode state.
    static let herdrFocusPaneMode = Notification.Name("HerdrFocusPaneMode")

    /// Mac-only. Posted by Settings ▸ General ▸ Feedback so the main window's
    /// shell presents the "Report a Bug or Request a Feature" sheet without
    /// Settings holding a reference to it.
    static let herdrPresentIssueReport = Notification.Name("HerdrPresentIssueReport")
}
