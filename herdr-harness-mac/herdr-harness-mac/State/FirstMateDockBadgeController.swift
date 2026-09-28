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
/// demo mode it counts the chat window's demo host
/// (`HerdrShellState.firstMateChatDemo`), so a demo send or read moves both.
/// Inert under XCTest unless a test asks otherwise.
///
/// Another writer can still land on the icon after this one: an alert-count
/// write already in flight when the setting took over, or the system applying
/// a notification's badge. So the label is written again, without the
/// unchanged-count shortcut, shortly after taking the badge over, whenever
/// Herdr becomes active, and after a notification is presented.
@MainActor
final class FirstMateDockBadgeController {
    private let defaults: UserDefaults
    private let apply: @MainActor (String?) -> Void
    private let isInert: Bool

    private weak var model: HerdrAppModel?
    private weak var shell: HerdrShellState?
    private var defaultsObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?
    private let reassertDelay: Duration?
    private var reassertTask: Task<Void, Never>?
    private var isStarted = false
    /// Whether this controller currently owns the badge.
    private(set) var ownsBadge = false
    /// The label last written, so an unchanged count writes nothing.
    private(set) var appliedLabel: String?
    private var hasAppliedLabel = false

    /// `reassertDelay` is how long after taking the badge over the label is
    /// written once more (nil never does; tests).
    init(
        defaults: UserDefaults = .standard,
        apply: @escaping @MainActor (String?) -> Void = { NSApp?.dockTile.badgeLabel = $0 },
        isInert: Bool = FirstMateFleetDriver.isHostedByTests,
        reassertDelay: Duration? = .seconds(1)
    ) {
        self.defaults = defaults
        self.apply = apply
        self.isInert = isInert
        self.reassertDelay = reassertDelay
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
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
        }
    }

    /// The hosts the chat window shows: the chat demo's host in demo mode,
    /// else every fleet host.
    func hosts(model: HerdrAppModel, shell: HerdrShellState) -> [FirstMateFleetHost] {
        model.isDemoMode ? [shell.firstMateChatDemo.host] : shell.firstMateFleet.hosts
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
                scheduleReassert()
            }
            let label = Self.label(for: count(model: model, shell: shell))
            if !hasAppliedLabel || label != appliedLabel {
                hasAppliedLabel = true
                appliedLabel = label
                apply(label)
            }
        } else if ownsBadge {
            reassertTask?.cancel()
            reassertTask = nil
            ownsBadge = false
            hasAppliedLabel = false
            appliedLabel = nil
            apply(nil)
            // Re-applies the unread alert count.
            model.isAlertBadgeSuspended = false
        }
    }

    /// Writes the current label again even when the count has not changed,
    /// over whatever another writer put on the icon since. Does nothing while
    /// the setting is off.
    func reassert() {
        guard ownsBadge else { return }
        hasAppliedLabel = false
        update()
    }

    /// Covers an alert-count write that was already in flight when this took
    /// the badge over.
    private func scheduleReassert() {
        guard let reassertDelay else { return }
        reassertTask?.cancel()
        reassertTask = Task { [weak self] in
            try? await Task.sleep(for: reassertDelay)
            guard !Task.isCancelled else { return }
            self?.reassert()
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
