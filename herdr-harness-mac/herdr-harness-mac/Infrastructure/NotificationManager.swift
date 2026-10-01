import UserNotifications

@MainActor
enum NotificationManager {
    /// Test seam: production code leaves this `nil` and falls through to
    /// the real `UNUserNotificationCenter` call below. Tests substitute a
    /// closure to observe (or stub) delivered-notification withdrawal
    /// without touching the real notification center. Always reset to
    /// `nil` when a test is done with it.
    static var removeDeliveredOverride: ((Set<String>) -> Void)?

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
        } catch {
            return false
        }
    }

    static func userInfo(for alert: HerdrAlert) -> [String: String] {
        [
            "workspace_id": alert.workspaceID,
            "pane_id": alert.paneID,
            "alert_id": alert.id,
            "machine_id": alert.machineID,
        ]
    }

    static func post(_ alert: HerdrAlert) async {
        let request = UNNotificationRequest(
            identifier: alert.id,
            content: content(for: alert),
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The delivered notification for one alert. Completion audio belongs to
    /// the process-owned companion cue; a Notification Center sound would make
    /// the same completion audible twice. Only done notifications are silent;
    /// blocked notifications retain their background attention sound. Title,
    /// body, interruption level, routing, and badge handling stay as before.
    static func content(for alert: HerdrAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = alert.status == .done ? nil : .default
        content.interruptionLevel = alert.status == .blocked ? .timeSensitive : .active
        content.userInfo = userInfo(for: alert)
        return content
    }

    static func postTest() async {
        await post(
            HerdrAlert(
                id: "herdr-test-alert",
                workspaceID: "",
                paneID: "",
                status: .done,
                title: "Herdr alerts are ready",
                message: "You’ll see a banner when an agent needs you or finishes in the background.",
                createdAt: "",
                isRead: false
            )
        )
    }

    /// Whether App Shots may post a notice without prompting. The capture path
    /// only ever observes the existing authorization.
    static func isAuthorizedForAppShots() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// App Shots never asks for permission itself: `requestAuthorization()` runs
    /// only from the settings toggle that the user turns on deliberately.
    static func postAppShot(title: String, body: String, identifier: String = "herdr-app-shot") async {
        guard await isAuthorizedForAppShots() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// A walkthrough settled on the companion. Like App Shots, this observes
    /// the existing authorization and never prompts.
    static func postPRReviewWalkthrough(_ event: PRReviewWalkthroughNotification.Event, route: URL?) async {
        guard await isAuthorizedForAppShots() else { return }
        let request = UNNotificationRequest(
            identifier: PRReviewWalkthroughNotification.identifier(guideID: event.guideID),
            content: PRReviewWalkthroughNotification.content(for: event, route: route),
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func removeDelivered(alertIDs: Set<String>) async {
        guard !alertIDs.isEmpty else { return }
        if let removeDeliveredOverride {
            removeDeliveredOverride(alertIDs)
            return
        }
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.deliveredNotifications().compactMap { notification -> String? in
            let content = notification.request.content
            let alertID = content.userInfo["alertId"] as? String
                ?? content.userInfo["alert_id"] as? String
            guard alertIDs.contains(notification.request.identifier) ||
                    alertID.map { alertIDs.contains($0) } == true
            else { return nil }
            return notification.request.identifier
        }
        if !identifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// The Mac app is co-located with the Herdr server and holds the `/api/v1/events`
    /// SSE stream open for as long as it runs, so alerts are delivered locally from
    /// `alert.created` instead of through APNs. Kept as a no-op so the shared
    /// `HerdrAppModel` smart-alert flow ports unchanged.
    static func registerForRemoteNotifications() {}

    static func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
