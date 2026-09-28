import AppKit
import Foundation
import Observation

/// Shows the First Mate count on the Dock icon: the conversations with an
/// unread dot, the same number as the chat window's sidebar and the main
/// window's First Mate badge.
///
/// While Settings ▸ General ▸ "Show First Mate count on the Dock icon" is on,
/// this owns the app icon badge and the alert-count writer
/// (`HerdrAppModel.updateBadgeIfNeeded`) yields. Turning it off clears the
/// First Mate count and hands the badge back, which re-applies the alert
/// count. Process-owned, so it keeps updating with every window closed. In
/// demo mode it counts the chat window's demo host. Inert under XCTest unless
/// a test asks otherwise.
@MainActor
final class FirstMateDockBadgeController {
    private let defaults: UserDefaults
    private let apply: @MainActor (String?) -> Void
    private let isInert: Bool

    private weak var model: HerdrAppModel?
    private weak var shell: HerdrShellState?
    private var defaultsObserver: (any NSObjectProtocol)?
    private var isStarted = false
    /// Whether this controller currently owns the badge.
    private(set) var ownsBadge = false
    /// The label last written, so an unchanged count writes nothing.
    private(set) var appliedLabel: String?
    private var hasAppliedLabel = false
    private var demoFleet: (fleet: [FirstMateFleetEntry], snapshots: [String: FirstMateSnapshot], now: Date)?

    init(
        defaults: UserDefaults = .standard,
        apply: @escaping @MainActor (String?) -> Void = { NSApp?.dockTile.badgeLabel = $0 },
        isInert: Bool = FirstMateFleetDriver.isHostedByTests
    ) {
        self.defaults = defaults
        self.apply = apply
        self.isInert = isInert
    }

    /// Nil hides the badge at zero.
    static func label(for count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    var isEnabled: Bool {
        defaults.object(forKey: FirstMateChatPreferences.dockBadgeEnabledKey) as? Bool
            ?? FirstMateChatPreferences.defaultDockBadgeEnabled
    }

    /// Idempotent: only the first call starts tracking.
    func start(model: HerdrAppModel, shell: HerdrShellState) {
        guard !isInert, !isStarted else { return }
        isStarted = true
        self.model = model
        self.shell = shell
        track()
        // Registered at once (not from a task), so a change made right after
        // starting is not missed.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// The hosts the chat window shows: the chat demo's host in demo mode,
    /// else every fleet host.
    func hosts(model: HerdrAppModel, shell: HerdrShellState) -> [FirstMateFleetHost] {
        guard model.isDemoMode else { return shell.firstMateFleet.hosts }
        let demo = demoFleet ?? {
            let now = Date()
            let snapshots = Dictionary(
                FirstMateDemo.chatWindowFeatures(now: now).map { ($0.feature.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return (FirstMateDemo.chatWindowFleet(now: now), snapshots, now)
        }()
        demoFleet = demo
        return [FirstMateChatWindowSession.demoHost(fleet: demo.fleet, snapshots: demo.snapshots, lastUpdated: demo.now)]
    }

    /// The Dock count for the current hosts and read markers.
    func count(model: HerdrAppModel, shell: HerdrShellState) -> Int {
        guard model.isDemoMode else { return shell.firstMateFleet.badgeCount }
        return FirstMateBadge.count(hosts: hosts(model: model, shell: shell), readState: shell.firstMateFleet.readState)
    }

    /// Re-reads the setting and the count and writes the badge when it changed.
    func update() {
        guard let model, let shell else { return }
        if isEnabled {
            if !ownsBadge {
                ownsBadge = true
                hasAppliedLabel = false
                model.isAlertBadgeSuspended = true
            }
            let label = Self.label(for: count(model: model, shell: shell))
            if !hasAppliedLabel || label != appliedLabel {
                hasAppliedLabel = true
                appliedLabel = label
                apply(label)
            }
        } else if ownsBadge {
            ownsBadge = false
            hasAppliedLabel = false
            appliedLabel = nil
            apply(nil)
            // Re-applies the unread alert count.
            model.isAlertBadgeSuspended = false
        }
    }

    /// The Dock menu's conversations, from the same hosts as the badge.
    func menuItems(model: HerdrAppModel, shell: HerdrShellState) -> [FirstMateDockMenuItem] {
        let conversations = FirstMateConversationList.build(
            hosts: hosts(model: model, shell: shell),
            readState: shell.firstMateFleet.readState
        )
        return FirstMateDockMenuItem.items(conversations: conversations)
    }

    /// Updates now and again whenever the fleet, the read markers, or demo
    /// mode change.
    private func track() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
    }
}

/// One entry in the Dock menu: a conversation with an unread dot.
struct FirstMateDockMenuItem: Equatable, Sendable {
    let id: FirstMateFleetFeatureID
    /// "🧾 Receipt export: Blocked".
    let title: String

    static let limit = 5

    /// Up to five conversations with a dot, newest activity first.
    static func items(conversations: [FirstMateConversation]) -> [FirstMateDockMenuItem] {
        conversations
            .filter(\.showsDot)
            .prefix(limit)
            .map { FirstMateDockMenuItem(id: $0.id, title: title(for: $0)) }
    }

    static func title(for conversation: FirstMateConversation) -> String {
        let name = conversation.label.isEmpty ? conversation.title : conversation.label
        return "\(conversation.emoji) \(name): \(FirstMateChatStatusStyle.label(for: conversation.hudStatus))"
    }
}
