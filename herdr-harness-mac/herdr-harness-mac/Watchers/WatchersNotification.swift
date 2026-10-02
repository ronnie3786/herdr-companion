import Foundation
import UserNotifications

struct WatchersNotification: Sendable {
    static let routeKey = "watchers_url"
    var id: String
    var title: String
    var body: String
    init?(event: HerdrEvent, machineID: String, now: Date = .now) {
        guard case let .object(payload)? = event.data,
              case let .object(item)? = payload["item"],
              case let .string(id)? = item["id"], !id.isEmpty else { return nil }
        if case .string? = item["read_at"] { return nil }
        if case let .string(created)? = item["created_at"], let date = WatchersDate.parse(created), now.timeIntervalSince(date) > 1800 { return nil }
        self.id = machineID + ":" + id
        if case let .string(title)? = item["title"] { self.title = String(title.prefix(160)) } else { title = "A watcher needs you" }
        if case let .string(body)? = item["body_md"] ?? item["body"] { self.body = String(body.prefix(240)) } else { body = "Open your Watcher inbox to see the result." }
    }
    func post() async {
        guard await NotificationManager.isAuthorizedForAppShots() else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.threadIdentifier = "watchers"
        content.userInfo = [Self.routeKey: "herdr://watchers"]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watchers-" + id, content: content, trigger: nil))
    }
}
