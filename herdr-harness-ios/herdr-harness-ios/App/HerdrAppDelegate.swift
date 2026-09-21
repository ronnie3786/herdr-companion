import UIKit
import UserNotifications

@MainActor
final class HerdrAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var pendingPaneID: String?
    private static var pendingCarMode = false

    static func takePendingPaneID() -> String? {
        defer { pendingPaneID = nil }
        return pendingPaneID
    }

    /// A Home Screen quick action can arrive before the root view is listening.
    static func takePendingCarMode() -> Bool {
        defer { pendingCarMode = false }
        return pendingCarMode
    }

    static func resolvedPaneID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let paneID = (userInfo["pane_id"] as? String) ?? (userInfo["paneId"] as? String) else {
            return nil
        }
        if let machineID = userInfo["machine_id"] as? String, !machineID.isEmpty {
            return MachineScopedID.compose(machineID: machineID, rawID: paneID)
        }
        return paneID
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        VoiceRecordingPolicy.removeStaleTemporaryRecordings()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .herdrPushToken, object: token)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The active app supplies semantic haptics from agent-state changes.
        // Keep the banner visible, but do not duplicate that feedback with a
        // generic notification sound while Herdr is in the foreground.
        [.banner, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let paneID = Self.resolvedPaneID(fromUserInfo: userInfo) else { return }
        Self.pendingPaneID = paneID
        NotificationCenter.default.post(name: .herdrOpenPane, object: paneID)
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        guard shortcutItem.type == Self.carModeShortcutType else { return false }
        Self.pendingCarMode = true
        NotificationCenter.default.post(name: .herdrOpenCarMode, object: nil)
        return true
    }

    static let carModeShortcutType = "herdr.car-mode"
}

extension Notification.Name {
    static let herdrOpenPane = Notification.Name("HerdrOpenPane")
    static let herdrPushToken = Notification.Name("HerdrPushToken")
    static let herdrOpenCarMode = Notification.Name("HerdrOpenCarMode")
}
