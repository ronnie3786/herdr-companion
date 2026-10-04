import Foundation
import Observation

/// Stable root-owned Home presentation. Source stores retain all operational ownership.
@MainActor @Observable
final class HomeStore {
    private(set) var snapshot = HomeSnapshot()
    private(set) var selectedFocusID: String?
    private(set) var previousVisit: Date?
    private(set) var status: String?
    /// Changes with every status, so its presentation dismisses exactly the one it showed.
    private(set) var statusRevision = 0
    private(set) var canUndoSnooze = false
    var search = "" { didSet { if search != oldValue { rebuild(now: clock()) } } }
    var recapExpanded: Bool {
        didSet {
            guard recapExpanded != oldValue else { return }
            preferences.recapExpanded = recapExpanded
            persist()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var preferences: HomeLocalPreferences
    @ObservationIgnored private var source = HomeSnapshot()
    /// The card the person chose with Skip, a Then link or Undo. Until then the
    /// front card follows priority, so work that arrives later (a machine outage,
    /// a newly blocked First Mate) comes first.
    @ObservationIgnored private var pinnedFocusID: String?
    @ObservationIgnored private var undoSnooze: (id: String, choice: HomeEvidenceChoice)?
    @ObservationIgnored private var isVisiting = false
    private static let preferencesKey = "herdr.home.presentation.v1"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = now
        var stored = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(HomeLocalPreferences.self, from: $0) }
            .flatMap { $0.version == 1 ? $0 : nil } ?? HomeLocalPreferences()
        stored.prune(now: now())
        preferences = stored
        recapExpanded = stored.recapExpanded
        previousVisit = stored.lastVisit
    }

    var selectedFocus: HomeFocusItem? {
        snapshot.focus.first { $0.id == selectedFocusID }
    }

    var snoozedCount: Int {
        let now = clock()
        return source.focus.filter { isSnoozed($0, now: now) }.count
    }

    func beginVisit(now: Date? = nil) {
        guard !isVisiting else { return }
        isVisiting = true
        previousVisit = preferences.lastVisit
        preferences.lastVisit = now ?? clock()
        persist()
    }

    func endVisit() { isVisiting = false }

    func receive(_ snapshot: HomeSnapshot, now: Date? = nil) {
        let instant = now ?? clock()
        source = snapshot
        for id in snapshot.focus.map(\.id) + snapshot.radar.map(\.id) {
            if instant.timeIntervalSince(preferences.lastSeen[id] ?? .distantPast) >= 3_600 {
                preferences.lastSeen[id] = instant
            }
        }
        preferences.prune(now: instant)
        if let undo = undoSnooze, (undo.choice.expiresAt ?? .distantPast) <= instant {
            dismissStatus(revision: statusRevision)
        }
        rebuild(now: instant)
        persist()
    }

    func selectFocus(_ id: String) {
        guard snapshot.focus.contains(where: { $0.id == id }) else { return }
        pinnedFocusID = id
        selectedFocusID = id
    }

    /// Moves to the next card without resolving this one. The stack keeps its
    /// priority order, so the skipped card comes around again after the rest.
    func skip() {
        let ids = snapshot.focus.map(\.id)
        guard ids.count > 1, let id = selectedFocusID, let index = ids.firstIndex(of: id) else { return }
        selectFocus(ids[(index + 1) % ids.count])
    }

    func snooze(_ id: String, now: Date? = nil) {
        guard let item = source.focus.first(where: { $0.id == id }), !item.isIdea else { return }
        let instant = now ?? clock()
        let expires = instant.addingTimeInterval(60 * 60)
        let choice = HomeEvidenceChoice(fingerprint: item.fingerprint, expiresAt: expires)
        if pinnedFocusID == id {
            // The next card moves up, as it does when a card is answered.
            let ids = snapshot.focus.map(\.id)
            pinnedFocusID = ids.firstIndex(of: id).flatMap { ids.count > 1 ? ids[($0 + 1) % ids.count] : nil }
        }
        preferences.snoozes[id] = choice
        preferences.lastSeen[id] = instant
        setStatus("Snoozed until \(expires.formatted(date: .omitted, time: .shortened)).")
        undoSnooze = (id, choice)
        canUndoSnooze = true
        rebuild(now: instant)
        persist()
    }

    func undoLastSnooze() {
        guard let undo = undoSnooze else { return }
        if preferences.snoozes[undo.id] == undo.choice { preferences.snoozes[undo.id] = nil }
        undoSnooze = nil
        canUndoSnooze = false
        setStatus("Snooze undone.")
        rebuild(now: clock())
        selectFocus(undo.id)
        persist()
    }

    func dismissRadar(_ id: String, now: Date? = nil) {
        guard let item = source.radar.first(where: { $0.id == id }) else { return }
        let instant = now ?? clock()
        preferences.dismissals[id] = HomeEvidenceChoice(fingerprint: item.fingerprint)
        preferences.lastSeen[id] = instant
        rebuild(now: instant)
        persist()
    }

    /// Replaces any Undo offer: the new text no longer describes that snooze.
    func showStatus(_ text: String?) {
        undoSnooze = nil
        canUndoSnooze = false
        setStatus(text)
    }

    /// Clears the status shown at `revision` unless a newer one replaced it.
    func dismissStatus(revision: Int) {
        guard revision == statusRevision, status != nil else { return }
        status = nil
        undoSnooze = nil
        canUndoSnooze = false
    }

    private func setStatus(_ text: String?) {
        status = text
        statusRevision &+= 1
    }

    private func isSnoozed(_ item: HomeFocusItem, now: Date) -> Bool {
        guard let choice = preferences.snoozes[item.id] else { return false }
        return choice.fingerprint == item.fingerprint && (choice.expiresAt ?? .distantPast) > now
    }

    private func rebuild(now: Date) {
        let previousIDs = snapshot.focus.map(\.id)
        let previousIndex = selectedFocusID.flatMap { previousIDs.firstIndex(of: $0) } ?? 0
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
        var visible = source
        // The projection orders focus by priority, recency and scoped ID. Local
        // choices hide cards but never reorder them.
        visible.focus = source.focus.filter {
            !isSnoozed($0, now: now) && matches("\($0.title) \($0.reason) \($0.body.plainText)")
        }
        visible.radar = source.radar.filter { item in
            preferences.dismissals[item.id]?.fingerprint != item.fingerprint && matches(item.body.plainText)
        }
        visible.chats = source.chats.filter { matches("\($0.title) \($0.location) \($0.reason) \($0.quote)") }
        visible.recap = source.recap.filter { matches($0.body.plainText) }
        if !query.isEmpty { visible.summary = source.summary.filter { matches($0.plainText) } }
        let ids = visible.focus.map(\.id)
        let selection: String?
        if let pinned = pinnedFocusID, ids.contains(pinned) {
            selection = pinned
        } else if pinnedFocusID == nil || ids.isEmpty {
            selection = ids.first
        } else {
            // The chosen card is hidden or resolved, so the card that took its place is next.
            selection = ids[min(previousIndex, ids.count - 1)]
            if !source.focus.contains(where: { $0.id == pinnedFocusID }) { pinnedFocusID = selection }
        }
        // Observation publishes every write, so unchanged refreshes must not assign.
        if selection != selectedFocusID { selectedFocusID = selection }
        if visible != snapshot { snapshot = visible }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(preferences) else { return }
        // Avoid a preferences write on every identical polling response.
        if defaults.data(forKey: Self.preferencesKey) != data { defaults.set(data, forKey: Self.preferencesKey) }
    }
}
